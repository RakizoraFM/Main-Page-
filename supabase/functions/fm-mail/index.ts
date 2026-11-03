// fm-mail (V290): e-mails the approved work-order report (PDF, + the consultant's Excel for FCI orders) to the order's recipients.
// No libraries (plain fetch), so the same file runs in Deno and Node like fm-push / fm-ai.
// Secrets (Supabase → Edge Functions → fm-mail → Secrets):
//   RESEND_API_KEY  the key of the e-mail provider (resend.com; never in the repository or the browser)
//   MAIL_FROM       the sender address on a domain verified at the provider, e.g. reports@yourcompany.com
//   SUPABASE_URL / SUPABASE_ANON_KEY are provided by Supabase.
// Deploy with JWT verification ON. The browser sends only the order id and the files; the recipients come from the database:
// fm_mail_begin (called with the caller's token) checks that he may send for this order (creator side / approver / admin), that
// the order is approved, the daily limits, and returns the order's recipient e-mails; fm_mail_end records the result.
/* eslint-disable */
const API = 'https://api.resend.com/emails';
const MAX_B64 = 30 * 1024 * 1024; // attachments, base64 characters in total
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const dt = (v) => { if (!v) return ''; const d = new Date(v); if (isNaN(+d)) return ''; return d.toISOString().slice(0, 10); };
export function mailBody(info, test) {
  const cfg = (info && info.cfg) || {}, name = String(cfg.from_name || '').trim();
  if (test) return { subject: '✅ تجربة إرسال تقارير أوامر العمل', html: `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px">هذه رسالة تجربة من منصة إدارة المرافق${name ? ' — ' + esc(name) : ''}. إذا وصلتك فإرسال التقارير المعتمدة بالبريد يعمل.</div>` };
  const rows = [['رقم الأمر', info.code], ['العنوان', info.title], ['المدرسة', info.school], ['المنفّذ', info.assignee], ['اعتمده', info.approver], ['تاريخ الاعتماد', dt(info.closed_at)]]
    .filter(([, v]) => String(v ?? '').trim()).map(([k, v]) => `<tr><td style="padding:6px 10px;background:#f1f5f9;font-weight:bold">${esc(k)}</td><td style="padding:6px 10px">${esc(v)}</td></tr>`).join('');
  return {
    subject: `📄 تقرير أمر عمل معتمد — ${info.code || ''}${info.school ? ' — ' + info.school : ''}`,
    html: `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px;color:#0f172a"><p>السلام عليكم،</p><p>نرفق لكم تقرير أمر العمل بعد اعتماده.</p>
<table style="border-collapse:collapse;border:1px solid #e2e8f0;margin:10px 0">${rows}</table><p>الملفات مرفقة بهذه الرسالة.</p><p style="color:#64748b;font-size:13px">${esc(name || 'منصة إدارة المرافق')}</p></div>`,
  };
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
export async function run(b, jwt, env, fetchFn = fetch) {
  if (!env.RESEND_API_KEY || !env.MAIL_FROM) return { status: 500, body: { error: 'mail not configured' } };
  const test = !!(b && b.test);
  const fl = cleanFiles(b && b.files); if (fl.error) return { status: 413, body: { error: fl.error } };
  const rest = (fn, args) => fetchFn(env.SUPABASE_URL + '/rest/v1/rpc/' + fn, { method: 'POST',
    headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: 'Bearer ' + jwt, 'Content-Type': 'application/json' }, body: JSON.stringify(args) })
    .then(async (r) => { const t = await r.text(); if (!r.ok) { let m = t; try { m = JSON.parse(t).message || t; } catch (e) {} throw new Error(m.slice(0, 200)); } return t ? JSON.parse(t) : null; });
  let info;
  try { info = await rest('fm_mail_begin', { p_wo: test ? null : (b && b.wo_id) || null, p_test: test }); }
  catch (e) { return { status: 403, body: { error: String(e.message || e) } }; }
  const cfg = info.cfg || {}, from = /</.test(env.MAIL_FROM) || !cfg.from_name ? env.MAIL_FROM : `${String(cfg.from_name).replace(/[<>"]/g, '')} <${env.MAIL_FROM}>`;
  const m = mailBody(info, test), msg = { from, to: info.to, subject: m.subject, html: m.html };
  if (cfg.reply_to && /@/.test(cfg.reply_to)) msg.reply_to = String(cfg.reply_to);
  if (fl.files.length) msg.attachments = fl.files;
  let res, j = null;
  try { res = await fetchFn(API, { method: 'POST', headers: { Authorization: 'Bearer ' + env.RESEND_API_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(msg) }); j = await res.json().catch(() => null); }
  catch (e) { await rest('fm_mail_end', { p_id: info.id, p_ok: false, p_err: 'network', p_ref: null }).catch(() => {}); return { status: 502, body: { error: 'network' } }; }
  const err = res.ok ? null : ((j && (j.message || (j.error && j.error.message) || j.error)) || ('http ' + res.status));
  await rest('fm_mail_end', { p_id: info.id, p_ok: !err, p_err: err ? String(err) : null, p_ref: (j && j.id) || null }).catch(() => {});
  if (err) return { status: res.status === 429 || res.status >= 500 ? 503 : 422, body: { error: String(err) } };
  return { status: 200, body: { ok: true, to: info.to, id: j && j.id } };
}
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
export async function handle(req, env, fetchFn = fetch) {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return new Response(JSON.stringify({ error: 'sign in required' }), { status: 401, headers: { ...CORS, 'Content-Type': 'application/json' } });
  let b = {};
  try { b = await req.json(); } catch (e) {}
  const r = await run(b, jwt, env, fetchFn);
  return new Response(JSON.stringify(r.body), { status: r.status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
if (typeof Deno !== 'undefined') {
  Deno.serve((req) => handle(req, Deno.env.toObject()));
}
