// fm-backup (V365): the full data backup made on the server, without anyone opening the platform. No libraries (plain fetch,
// CompressionStream, WebCrypto), so the same file runs in Deno and Node 20+.
// Two ways in:
//   * server mode — pg_cron (fm_backup_srv_tick → fm_backup_srv_kick) POSTs with the header x-fm-hook. The function checks
//     the hook (secret FM_BACKUP_HOOK, else the value fm_backup_srv_secret() returns to the service role) and asks
//     fm_backup_srv_claim for work:
//       'db'    — read every table (fm_backup_srv_tables / fm_backup_srv_page), write one .fmbak file in the V351 format
//                 (JSON → gzip → AES-GCM with the backup password: 'FMBK' 1 salt(16) iv(12) iterations(4, BE) + ciphertext)
//                 into the private bucket fm-backups/db/, delete all but the newest `keep`, e-mail a download link (signed
//                 URL, link_days) through Resend, then mirror Storage files while time remains;
//       'files' — continue mirroring new / changed Storage files into fm-backups/files/<bucket>/<path>.
//     The result goes back with fm_backup_srv_result (more = true when the files did not finish in time).
//   * platform mode — the system admin's platform sends {action:'sign', path:'db/…'} with his own token; the database
//     (fm_backup_srv_can, run with that token) checks him, then the function returns a 10-minute download link.
// Secrets (Supabase → Edge Functions → fm-backup → Secrets): optional RESEND_API_KEY and MAIL_FROM (the same as fm-mail /
// fm-report; without them the backup is made and kept, only the e-mail is skipped). SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase. Deploy with JWT verification OFF.
/* eslint-disable */
const BUCKET = 'fm-backups';
const HEAVY = ['fm_doc_files', 'wo_material_photos', 'wo_issue_signs', 'wo_supplier_invoices', 'fm_school_requests', 'wo_grn'];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const MB = (n) => (n / 1048576).toFixed(n > 10485760 ? 0 : 1) + ' MB';
const riyadh = (d = new Date()) => new Date(d.getTime() + 3 * 3600e3).toISOString();

const rpc = (env, fetchFn, key, bearer) => (fn, args) => fetchFn(env.SUPABASE_URL + '/rest/v1/rpc/' + fn, {
  method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + bearer, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}),
}).then(async (r) => { const t = await r.text(); if (!r.ok) { let m = t; try { m = JSON.parse(t).message || t; } catch (e) {} throw new Error(String(m).slice(0, 200)); } return t ? JSON.parse(t) : null; });
const storage = (env, fetchFn) => (path, init) => fetchFn(env.SUPABASE_URL + '/storage/v1/' + path, {
  ...init, headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: 'Bearer ' + env.SUPABASE_SERVICE_ROLE_KEY, ...(init && init.headers || {}) },
});
const encPath = (p) => String(p).split('/').map(encodeURIComponent).join('/');

// ---- the file (same format as the V351 page, so its «♻️ استرجاع» opens it) ----
async function gzip(parts) {
  return new Uint8Array(await new Response(new Blob(parts, { type: 'application/json' }).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
}
async function keyOf(pass, salt, it) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(pass), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey({ name: 'PBKDF2', salt, iterations: it, hash: 'SHA-256' }, k, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
export async function encrypt(u8, pass) {
  const salt = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12)), it = 200000;
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await keyOf(pass, salt, it), u8));
  const h = new Uint8Array(37); h.set([70, 77, 66, 75, 1]); h.set(salt, 5); h.set(iv, 21); new DataView(h.buffer).setUint32(33, it);
  const o = new Uint8Array(37 + ct.length); o.set(h); o.set(ct, 37); return o;
}
export async function decrypt(u8, pass) {
  const salt = u8.slice(5, 21), iv = u8.slice(21, 33), it = new DataView(u8.buffer, u8.byteOffset).getUint32(33);
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, await keyOf(pass, salt, it), u8.slice(37)));
}
export async function buildFile(svc, job, project) {
  const tabs = (await svc('fm_backup_srv_tables', {})) || [];
  const head = { fmbak: 1, app: 'server', at: new Date().toISOString(), project, company: job.company || '', lite: false };
  const parts = [JSON.stringify(head).slice(0, -1) + ',"tables":{'];
  let first = true, rows = 0, nt = 0;
  for (const t of tabs) {
    const lim = HEAVY.includes(t.t) ? 50 : 1000; let n = 0; const chunk = [];
    for (let off = 0; ; off += lim) {
      const pg = (await svc('fm_backup_srv_page', { p_table: t.t, p_offset: off, p_limit: lim })) || [];
      for (const r of pg) chunk.push((n++ ? ',' : '') + JSON.stringify(r));
      if (pg.length < lim) break;
    }
    parts.push((first ? '' : ',') + JSON.stringify(t.t) + ':{"n":' + n + ',"rows":[', ...chunk, ']}');
    first = false; nt++; rows += n;
  }
  parts.push('}}');
  const u8 = await encrypt(await gzip(parts), job.pass);
  return { u8, tables: nt, rows };
}

// ---- Storage ----
export async function upload(st, path, u8) {
  const r = await st('object/' + BUCKET + '/' + encPath(path), { method: 'POST', headers: { 'Content-Type': 'application/octet-stream', 'x-upsert': 'true' }, body: u8 });
  if (!r.ok) throw new Error('upload ' + r.status + ': ' + (await r.text()).slice(0, 160));
}
export async function sign(st, path, seconds) {
  const r = await st('object/sign/' + BUCKET + '/' + encPath(path), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn: seconds }) });
  const j = await r.json().catch(() => null);
  const u = j && (j.signedURL || j.signedUrl);
  if (!r.ok || !u) throw new Error('sign ' + r.status);
  return /^https?:/.test(u) ? u : (st.base || '') + '/storage/v1' + (u.startsWith('/') ? u : '/' + u);
}
async function copyOne(st, b, n) {
  const body = JSON.stringify({ bucketId: b, sourceKey: n, destinationBucket: BUCKET, destinationKey: 'files/' + b + '/' + n });
  let r = await st('object/copy', { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-upsert': 'true' }, body });
  if (r.ok) return true;
  const t = await r.text();
  if (/exist|duplicate/i.test(t)) {
    await st('object/' + BUCKET, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ prefixes: ['files/' + b + '/' + n] }) });
    r = await st('object/copy', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });
    if (r.ok) return true;
  }
  throw new Error('copy ' + r.status + ': ' + t.slice(0, 120));
}
// mirror until the deadline; returns {n, bytes, more, err}
export async function mirror(svc, st, deadline) {
  let cb = '', cn = '', n = 0, bytes = 0, err = null;
  while (Date.now() < deadline) {
    const L = (await svc('fm_backup_srv_objects', { p_bucket: cb, p_name: cn, p_n: 100 })) || [];
    if (!L.length) return { n, bytes, more: false, err };
    const done = [];
    for (const o of L) {
      if (Date.now() >= deadline) break;
      try { await copyOne(st, o.b, o.n); done.push(o); n++; bytes += +o.s || 0; } catch (e) { err = String(e.message || e); }
      cb = o.b; cn = o.n;
    }
    if (done.length) await svc('fm_backup_srv_copied', { p: done });
    if (Date.now() >= deadline) return { n, bytes, more: true, err };
  }
  return { n, bytes, more: true, err };
}

// ---- e-mail ----
export function mailBody(o) {
  const from = String((o.mail && o.mail.from_name) || '').trim();
  return {
    subject: `💾 نسخة احتياطية من بيانات المنصة — ${riyadh().slice(0, 10)}`,
    html: `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px;color:#0f172a">
<p style="font-size:18px;font-weight:900;margin:0 0 6px">💾 نسخة احتياطية جديدة${o.company ? ' — ' + esc(o.company) : ''}</p>
<p>${o.tables} جدول • ${Number(o.rows).toLocaleString('en-US')} صف • ${MB(o.size)} • مشفّرة بكلمة سر النسخ الاحتياطي.</p>
<p><a href="${esc(o.url)}" style="background:#1d4ed8;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:bold">⬇️ تنزيل النسخة</a></p>
<p style="color:#64748b;font-size:13px">الرابط صالح ${o.days} يوم. احفظ الملف خارج المنصة (جهازك أو قرص خارجي). للاسترجاع: صفحة «💾 النسخ الاحتياطي» ← «♻️ استرجاع من نسخة» مع كلمة السر.<br>
لا تتضمن حسابات الدخول. ملفات الصور والمرفقات تُنسخ داخل التخزين في المشروع نفسه (مجلد files في fm-backups)${o.filesNew ? ` — نُسخ هذه المرة ${o.filesNew} ملف` : ''}.</p>
<p style="color:#94a3b8;font-size:12px;margin-top:18px">${esc(from || 'منصة إدارة المرافق')} — وصلتك هذه الرسالة لأنك ضمن مستلمي النسخ الاحتياطي التلقائي.</p></div>`,
  };
}
async function mail(env, fetchFn, to, m, cfg) {
  if (!env.RESEND_API_KEY || !env.MAIL_FROM) return { ok: false, err: 'mail not configured' };
  if (!to || !to.length) return { ok: false, err: 'no recipients' };
  const from = /</.test(env.MAIL_FROM) || !(cfg && cfg.from_name) ? env.MAIL_FROM : `${String(cfg.from_name).replace(/[<>"]/g, '')} <${env.MAIL_FROM}>`;
  try {
    const r = await fetchFn('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: 'Bearer ' + env.RESEND_API_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ from, to, subject: m.subject, html: m.html }) });
    if (r.ok) return { ok: true };
    const j = await r.json().catch(() => null);
    return { ok: false, err: String((j && (j.message || j.error)) || 'http ' + r.status) };
  } catch (e) { return { ok: false, err: 'network' }; }
}

export async function hookOf(env, fetchFn = fetch) {
  if (env.FM_BACKUP_HOOK) return env.FM_BACKUP_HOOK;
  if (!env.SUPABASE_SERVICE_ROLE_KEY) return '';
  try { return (await rpc(env, fetchFn, env.SUPABASE_SERVICE_ROLE_KEY, env.SUPABASE_SERVICE_ROLE_KEY)('fm_backup_srv_secret', {})) || ''; } catch (e) { return ''; }
}

// server mode: one job (budget ≈ 130 s, the function's own limit is 150 s)
export async function runJob(env, fetchFn = fetch, budget = 130000) {
  const t0 = Date.now(), deadline = t0 + budget;
  const svc = rpc(env, fetchFn, env.SUPABASE_SERVICE_ROLE_KEY, env.SUPABASE_SERVICE_ROLE_KEY);
  const st = storage(env, fetchFn); st.base = env.SUPABASE_URL;
  const job = await svc('fm_backup_srv_claim', {});
  if (!job || !job.job) return { status: 200, body: { ok: true, job: null, why: job && job.why || 'nothing due' } };
  const res = { job: job.job };
  try {
    if (job.job === 'db') {
      if (!job.pass) throw new Error('backup password not set');
      const f = await buildFile(svc, job, String(env.SUPABASE_URL || '').replace(/^https?:\/\//, ''));
      const path = 'db/' + riyadh().slice(0, 19).replace(/[:T]/g, '-') + '.fmbak';
      await upload(st, path, f.u8);
      Object.assign(res, { ok: true, path, size: f.u8.length, tables: f.tables, rows: f.rows });
      try {
        const old = (await svc('fm_backup_srv_old', { p_keep: job.keep || 8 })) || [];
        if (old.length) await st('object/' + BUCKET, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ prefixes: old }) });
      } catch (e) {}
      // files first (so the e-mail can say how many), but leave ~15 s for the link and the e-mail
      if (job.files) {
        const m = await mirror(svc, st, deadline - 15000);
        Object.assign(res, { files_new: m.n, files_bytes: m.bytes, more: m.more, files_err: m.err });
      }
      try {
        const days = Math.min(30, Math.max(1, +job.link_days || 7));
        const url = await sign(st, path, days * 86400);
        const x = await mail(env, fetchFn, job.to, mailBody({ ...res, url, days, company: job.company, mail: job.mail, filesNew: res.files_new }), job.mail);
        res.mailed = x.ok ? (job.to || []).length : 0; if (!x.ok) res.mail_err = x.err;
      } catch (e) { res.mailed = 0; res.mail_err = String(e.message || e); }
    } else {
      const m = await mirror(svc, st, deadline);
      Object.assign(res, { ok: true, files_new: m.n, files_bytes: m.bytes, more: m.more, files_err: m.err });
    }
  } catch (e) { res.ok = false; res.err = String(e && e.message || e).slice(0, 300); res.more = false; }
  await svc('fm_backup_srv_result', { p: res }).catch(() => {});
  return { status: 200, body: res };
}

// platform mode: a short download link for one backup, for the system admin only
export async function runSign(b, jwt, env, fetchFn = fetch) {
  const path = String(b && b.path || '');
  if (!/^db\/[A-Za-z0-9._-]+\.fmbak$/.test(path)) return { status: 400, body: { error: 'bad path' } };
  try { const ok = await rpc(env, fetchFn, env.SUPABASE_ANON_KEY, jwt)('fm_backup_srv_can', {}); if (ok !== true) return { status: 403, body: { error: 'not allowed' } }; }
  catch (e) { return { status: 403, body: { error: String(e.message || e) } }; }
  const st = storage(env, fetchFn); st.base = env.SUPABASE_URL;
  try { return { status: 200, body: { url: await sign(st, path, 600) } }; } catch (e) { return { status: 502, body: { error: String(e.message || e) } }; }
}

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-fm-hook', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const out = (r) => new Response(JSON.stringify(r.body), { status: r.status, headers: { ...CORS, 'Content-Type': 'application/json' } });
export async function handle(req, env, fetchFn = fetch) {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const hook = req.headers.get('x-fm-hook');
  if (hook !== null) {
    const want = await hookOf(env, fetchFn);
    if (!want || hook !== want) return out({ status: 403, body: { error: 'bad hook' } });
    try { return out(await runJob(env, fetchFn)); } catch (e) { return out({ status: 500, body: { error: String(e && e.message || e) } }); }
  }
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return out({ status: 401, body: { error: 'sign in required' } });
  let b = {};
  try { b = await req.json(); } catch (e) {}
  if (b && b.action === 'sign') return out(await runSign(b, jwt, env, fetchFn));
  return out({ status: 400, body: { error: 'unknown action' } });
}
if (typeof Deno !== 'undefined') {
  Deno.serve((req) => handle(req, Deno.env.toObject()));
}
