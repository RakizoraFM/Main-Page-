// fm-report (V350): sends the scheduled reports by e-mail. No libraries (plain fetch), so the same file runs in Deno and Node.
// Two ways in:
//   * server mode — pg_cron (fm_report_due → fm_report_kick) POSTs with the header x-fm-hook. The function checks the hook
//     (secret FM_REPORT_HOOK, else the value fm_report_secret() returns to the service role), takes the queued runs with
//     fm_report_claim (each carries its data, built in SQL, and its recipients), writes the e-mail (summary table + the
//     first rows) with one CSV per sheet attached, sends it and records the result with fm_report_result.
//   * platform mode — the platform of the schedule's owner sends {run_id, files:[{filename, content base64}], summary?}
//     with the signed-in person's token; fm_report_client_begin (run with that token) checks the person and returns the
//     recipients, fm_report_client_end records the result.
// Secrets (Supabase → Edge Functions → fm-report → Secrets): RESEND_API_KEY and MAIL_FROM (the same as fm-mail).
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
// Deploy with JWT verification OFF (pg_net calls it with the hook, not a user token); platform calls are checked by the
// database through the person's own token.
/* eslint-disable */
const API = 'https://api.resend.com/emails';
const MAX_B64 = 30 * 1024 * 1024;
const MAX_ROWS = 20000;
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const num = (v) => (typeof v === 'number' ? v.toLocaleString('en-US') : String(v ?? ''));

// UTF-8 → base64 without Buffer (Deno and Node 18+ both have btoa)
export function b64(text) {
  const u8 = new TextEncoder().encode(text);
  let s = '';
  for (let i = 0; i < u8.length; i += 8192) s += String.fromCharCode.apply(null, Array.from(u8.subarray(i, i + 8192)));
  return btoa(s);
}
// one CSV cell: quoted, and a leading = + - @ is neutralised so a spreadsheet does not run it as a formula
export function cell(v) {
  if (v === null || v === undefined) return '';
  let s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  if (/^[=+\-@\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = "'" + s;
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}
export function csv(sheet) {
  const cols = Array.isArray(sheet && sheet.cols) ? sheet.cols : [];
  const rows = (Array.isArray(sheet && sheet.rows) ? sheet.rows : []).slice(0, MAX_ROWS);
  return '﻿' + [cols.map(cell).join(','), ...rows.map((r) => (Array.isArray(r) ? r : [r]).map(cell).join(','))].join('\r\n');
}
const safeName = (s) => String(s || 'report').replace(/[\\/:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || 'report';
const today = () => new Date(Date.now() + 3 * 3600e3).toISOString().slice(0, 10); // Riyadh date

export function mailBody(run, data, cfg) {
  const from = String((cfg && cfg.from_name) || '').trim();
  const title = (data && data.title) || run.name || 'تقرير';
  const kp = (Array.isArray(data && data.kpis) ? data.kpis : []).map(([l, v]) =>
    `<td style="border:1px solid #e2e8f0;border-radius:10px;padding:10px 14px;text-align:center"><div style="font-size:12px;color:#475569;font-weight:bold">${esc(l)}</div><div style="font-size:22px;font-weight:900;color:#0f172a">${esc(num(v))}</div></td>`).join('');
  const sheets = Array.isArray(data && data.sheets) ? data.sheets : [];
  const first = sheets[0];
  let tbl = '';
  if (first && Array.isArray(first.rows) && first.rows.length) {
    const head = (first.cols || []).map((c) => `<th style="background:#f1f5f9;border:1px solid #e2e8f0;padding:5px 8px">${esc(c)}</th>`).join('');
    const body = first.rows.slice(0, 25).map((r) => `<tr>${(Array.isArray(r) ? r : [r]).map((v) => `<td style="border:1px solid #e2e8f0;padding:5px 8px">${esc(num(v))}</td>`).join('')}</tr>`).join('');
    tbl = `<p style="margin:16px 0 6px;font-weight:bold">${esc(first.name || '')}${first.rows.length > 25 ? ` — أول 25 من ${first.rows.length} (الكل في الملف المرفق)` : ''}</p>
<table style="border-collapse:collapse;font-size:13px">${head ? `<thead><tr>${head}</tr></thead>` : ''}<tbody>${body}</tbody></table>`;
  } else if (first) {
    tbl = '<p style="color:#15803d;font-weight:bold">لا توجد بنود في هذا التقرير الآن ✅</p>';
  }
  const err = data && data.error ? `<p style="color:#b91c1c">تعذّر تجهيز بيانات التقرير: ${esc(data.error)}</p>` : '';
  return {
    subject: `📊 ${title} — ${today()}`,
    html: `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px;color:#0f172a">
<p style="font-size:18px;font-weight:900;margin:0 0 4px">${esc(title)}</p>
<p style="color:#64748b;font-size:13px;margin:0 0 12px">تقرير مجدول: ${esc(run.name || '')} — ${today()}</p>
${kp ? `<table style="border-collapse:separate;border-spacing:8px 0"><tr>${kp}</tr></table>` : ''}${err}${tbl}
${data && data.note ? `<p style="color:#64748b;font-size:12.5px">${esc(data.note)}</p>` : ''}
<p style="color:#94a3b8;font-size:12px;margin-top:18px">${esc(from || 'منصة إدارة المرافق')} — وصلتك هذه الرسالة لأنك ضمن مستلمي هذا التقرير المجدول.</p></div>`,
  };
}
export function attachments(run, data) {
  const out = [];
  for (const s of (Array.isArray(data && data.sheets) ? data.sheets : []).slice(0, 5)) {
    if (!s || !Array.isArray(s.rows) || !s.rows.length) continue;
    out.push({ filename: `${safeName(run.name)} - ${safeName(s.name)} - ${today()}.csv`, content: b64(csv(s)) });
  }
  return out;
}
export function cleanFiles(list) {
  const out = []; let total = 0;
  for (const f of Array.isArray(list) ? list : []) {
    const filename = String(f && f.filename || '').replace(/[\\/:*?"<>|]+/g, ' ').trim().slice(0, 120), content = String(f && f.content || '');
    if (!filename || !/^[A-Za-z0-9+/=]+$/.test(content)) continue;
    total += content.length; if (total > MAX_B64) return { error: 'files too large' };
    out.push({ filename, content });
  }
  return { files: out.slice(0, 5) };
}
const fromOf = (env, cfg) => (/</.test(env.MAIL_FROM) || !(cfg && cfg.from_name) ? env.MAIL_FROM : `${String(cfg.from_name).replace(/[<>"]/g, '')} <${env.MAIL_FROM}>`);

async function send(env, fetchFn, msg) {
  let res, j = null;
  try { res = await fetchFn(API, { method: 'POST', headers: { Authorization: 'Bearer ' + env.RESEND_API_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(msg) }); j = await res.json().catch(() => null); }
  catch (e) { return { ok: false, err: 'network', retry: true }; }
  if (res.ok) return { ok: true, ref: (j && j.id) || null };
  const err = (j && (j.message || (j.error && j.error.message) || j.error)) || ('http ' + res.status);
  return { ok: false, err: String(err), retry: res.status === 429 || res.status >= 500 };
}
const rpc = (env, fetchFn, key, bearer) => (fn, args) => fetchFn(env.SUPABASE_URL + '/rest/v1/rpc/' + fn, {
  method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + bearer, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}),
}).then(async (r) => { const t = await r.text(); if (!r.ok) { let m = t; try { m = JSON.parse(t).message || t; } catch (e) {} throw new Error(String(m).slice(0, 200)); } return t ? JSON.parse(t) : null; });

export async function hookOf(env, fetchFn = fetch) {
  if (env.FM_REPORT_HOOK) return env.FM_REPORT_HOOK;
  if (!env.SUPABASE_SERVICE_ROLE_KEY) return '';
  try { return (await rpc(env, fetchFn, env.SUPABASE_SERVICE_ROLE_KEY, env.SUPABASE_SERVICE_ROLE_KEY)('fm_report_secret', {})) || ''; } catch (e) { return ''; }
}

// server mode: send every queued run (several rounds, ≤ 25 s)
export async function runServer(env, fetchFn = fetch) {
  if (!env.RESEND_API_KEY || !env.MAIL_FROM) return { status: 500, body: { error: 'mail not configured' } };
  const svc = rpc(env, fetchFn, env.SUPABASE_SERVICE_ROLE_KEY, env.SUPABASE_SERVICE_ROLE_KEY);
  const t0 = Date.now(); let sent = 0, failed = 0;
  while (Date.now() - t0 < 25000) {
    const c = await svc('fm_report_claim', { n: 5 });
    const runs = (c && c.runs) || [], cfg = (c && c.cfg) || {};
    if (!runs.length) break;
    for (const r of runs) {
      const m = mailBody(r, r.data || {}, cfg), msg = { from: fromOf(env, cfg), to: r.to, subject: m.subject, html: m.html };
      if (cfg.reply_to && /@/.test(cfg.reply_to)) msg.reply_to = String(cfg.reply_to);
      const att = attachments(r, r.data || {}); if (att.length) msg.attachments = att;
      const x = await send(env, fetchFn, msg);
      if (x.ok) sent++; else failed++;
      await svc('fm_report_result', { p: { id: r.id, ok: x.ok, err: x.err || null, ref: x.ref || null, retry: !!x.retry } }).catch(() => {});
    }
  }
  return { status: 200, body: { ok: true, sent, failed } };
}

// platform mode: files built by the platform, sent with the person's token
export async function runClient(b, jwt, env, fetchFn = fetch) {
  if (!env.RESEND_API_KEY || !env.MAIL_FROM) return { status: 500, body: { error: 'mail not configured' } };
  const fl = cleanFiles(b && b.files); if (fl.error) return { status: 413, body: { error: fl.error } };
  const me = rpc(env, fetchFn, env.SUPABASE_ANON_KEY, jwt);
  let info;
  try { info = await me('fm_report_client_begin', { p_run: (b && b.run_id) || null }); }
  catch (e) { return { status: 403, body: { error: String(e.message || e) } }; }
  const cfg = info.cfg || {}, sm = b && b.summary ? String(b.summary).slice(0, 4000) : '';
  const m = mailBody({ name: info.name }, { title: (b && b.title) || info.name, note: sm }, cfg);
  m.html = m.html.replace('</div>', `<p>${fl.files.length ? 'التقرير مرفق بهذه الرسالة.' : ''}</p></div>`);
  const msg = { from: fromOf(env, cfg), to: info.to, subject: m.subject, html: m.html };
  if (cfg.reply_to && /@/.test(cfg.reply_to)) msg.reply_to = String(cfg.reply_to);
  if (fl.files.length) msg.attachments = fl.files;
  const x = await send(env, fetchFn, msg);
  await me('fm_report_client_end', { p_run: info.id, p_ok: x.ok, p_err: x.err || null, p_ref: x.ref || null }).catch(() => {});
  if (!x.ok) return { status: x.retry ? 503 : 422, body: { error: x.err } };
  return { status: 200, body: { ok: true, to: info.to, id: x.ref } };
}

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-fm-hook', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const out = (r) => new Response(JSON.stringify(r.body), { status: r.status, headers: { ...CORS, 'Content-Type': 'application/json' } });
export async function handle(req, env, fetchFn = fetch) {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const hook = req.headers.get('x-fm-hook');
  if (hook !== null) {
    const want = await hookOf(env, fetchFn);
    if (!want || hook !== want) return out({ status: 403, body: { error: 'bad hook' } });
    try { return out(await runServer(env, fetchFn)); } catch (e) { return out({ status: 500, body: { error: String(e && e.message || e) } }); }
  }
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return out({ status: 401, body: { error: 'sign in required' } });
  let b = {};
  try { b = await req.json(); } catch (e) {}
  return out(await runClient(b, jwt, env, fetchFn));
}
if (typeof Deno !== 'undefined') {
  Deno.serve((req) => handle(req, Deno.env.toObject()));
}
