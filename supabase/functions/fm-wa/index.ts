// fm-wa (V226): sends the queued WhatsApp messages (table fm_wa_queue) through the WhatsApp Business Cloud API.
// No libraries (plain fetch), so the same file runs in Deno and Node like fm-push.
// Secrets: WA_TOKEN (a permanent system-user token of the WhatsApp Business account), WA_PHONE_ID (the sender's phone
// number id), WA_API_VERSION (optional, default v21.0), FM_WA_HOOK (the shared secret the database sends in x-fm-hook,
// made in «الإعدادات» ← السحابة ← «💬 واتساب التلقائي»). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
// Deploy with JWT verification OFF (the database calls it with x-fm-hook). Only pre-approved templates can be sent to people
// who did not write first; the template names are set in the platform.
/* eslint-disable */
export function waBody(q) {
  const params = Array.isArray(q.params) ? q.params : [];
  const tpl = { name: q.template, language: { code: q.lang || 'ar' } };
  if (params.length) tpl.components = [{ type: 'body', parameters: params.map((t) => ({ type: 'text', text: String(t ?? '—').slice(0, 1000) || '—' })) }];
  return { messaging_product: 'whatsapp', to: q.phone, type: 'template', template: tpl };
}
export async function sendOne(q, env, fetchFn = fetch) {
  const url = 'https://graph.facebook.com/' + (env.WA_API_VERSION || 'v21.0') + '/' + env.WA_PHONE_ID + '/messages';
  const r = await fetchFn(url, { method: 'POST', headers: { Authorization: 'Bearer ' + env.WA_TOKEN, 'Content-Type': 'application/json' }, body: JSON.stringify(waBody(q)) });
  const j = await r.json().catch(() => null);
  if (r.ok && j && j.messages && j.messages[0]) return { id: q.id, ok: true, wa_id: j.messages[0].id };
  const err = (j && j.error && (j.error.message + (j.error.code ? ' (' + j.error.code + ')' : ''))) || ('http ' + r.status);
  // 131026 / 131047 / 132000 and 4xx: the message cannot go out (bad number, template, 24-hour window) — do not retry
  return { id: q.id, ok: false, err: String(err).slice(0, 300), final: r.status >= 400 && r.status < 500 && r.status !== 429 };
}
export async function run(env, fetchFn = fetch) {
  if (!env.WA_TOKEN || !env.WA_PHONE_ID) throw new Error('WA_TOKEN / WA_PHONE_ID missing');
  const rest = (path, body) => fetchFn(env.SUPABASE_URL + '/rest/v1/' + path, { method: 'POST',
    headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: 'Bearer ' + env.SUPABASE_SERVICE_ROLE_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    .then(async (r) => { const t = await r.text(); if (!r.ok) throw new Error(path + ' ' + r.status + ' ' + t.slice(0, 200)); return t ? JSON.parse(t) : null; });
  let taken = 0, sent = 0;
  for (let round = 0; round < 5; round++) {
    const rows = await rest('rpc/fm_wa_claim', { n: 50 });
    if (!rows || !rows.length) break;
    const out = [];
    for (const q of rows) {   // one by one: the Cloud API rate limits per phone number
      try { out.push(await sendOne(q, env, fetchFn)); } catch (e) { out.push({ id: q.id, ok: false, err: String(e && e.message || e).slice(0, 300) }); }
    }
    await rest('rpc/fm_wa_result', { p: out });
    taken += rows.length; sent += out.filter((x) => x.ok).length;
  }
  return { taken, sent };
}
export async function handle(req, env, fetchFn = fetch) {
  if (!env.FM_WA_HOOK || req.headers.get('x-fm-hook') !== env.FM_WA_HOOK) return new Response('forbidden', { status: 403 });
  try { return Response.json(await run(env, fetchFn)); }
  catch (e) { return new Response(String(e && e.message || e), { status: 500 }); }
}
if (typeof Deno !== 'undefined') {
  Deno.serve((req) => handle(req, Deno.env.toObject()));
}
