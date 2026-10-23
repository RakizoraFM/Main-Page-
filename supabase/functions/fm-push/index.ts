// RakizoraFM — Edge Function «fm-push» (V187): sends the queued notifications (table fm_push_queue) with Web Push.
// No libraries: VAPID (RFC 8292) and the payload encryption aes128gcm (RFC 8291) use WebCrypto only.
// Secrets of the function (Supabase → Edge Functions → fm-push → Secrets):
//   FM_PUSH_HOOK   the shared secret the database sends in the header x-fm-hook (made in «الإعدادات» ← السحابة ← «🔔 الإشعارات»)
//   VAPID_PRIVATE  the private VAPID key (made there too; it is shown once and never stored in the database)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are given to every function by Supabase. The public key and the contact
// (subject) are read from fm_settings.push. Deploy with JWT verification off: the hook secret protects the function.

const enc = new TextEncoder();
const b64u = (buf) => {
  let s = ''; const b = new Uint8Array(buf);
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const unb64u = (s) => {
  const t = atob(String(s).replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((String(s).length + 3) % 4));
  const b = new Uint8Array(t.length); for (let i = 0; i < t.length; i++) b[i] = t.charCodeAt(i); return b;
};
const cat = (...a) => { const n = a.reduce((s, x) => s + x.length, 0), o = new Uint8Array(n); let p = 0; for (const x of a) { o.set(x, p); p += x.length; } return o; };

async function hkdf(salt, ikm, info, len) {
  const k = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, k, len * 8));
}

// the VAPID signing key from the public (65 bytes, base64url) and private (32 bytes, base64url) keys
export async function vapidKey(pub, priv) {
  const p = unb64u(pub);
  if (p.length !== 65 || p[0] !== 4) throw new Error('bad VAPID public key');
  return crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: b64u(p.slice(1, 33)), y: b64u(p.slice(33, 65)), d: priv, ext: true },
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
}
export async function vapidHeader(endpoint, key, pub, subject, now = Date.now()) {
  const aud = new URL(endpoint).origin;
  const h = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const c = b64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(now / 1000) + 12 * 3600, sub: subject })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(h + '.' + c));
  return `vapid t=${h}.${c}.${b64u(sig)}, k=${pub}`;
}
// RFC 8291: one record, aes128gcm
export async function encrypt(payload, p256dh, auth) {
  const ua = unb64u(p256dh), secret = unb64u(auth);
  const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const as = new Uint8Array(await crypto.subtle.exportKey('raw', eph.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', ua, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, eph.privateKey, 256));
  const ikm = await hkdf(secret, shared, cat(enc.encode('WebPush: info\0'), ua, as), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, cat(enc.encode(payload), new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]);   // record size 4096
  return cat(salt, rs, new Uint8Array([as.length]), as, ct);
}
// send one message to one device: {status, gone}
export async function sendOne(sub, payload, v, fetchFn = fetch) {
  const body = await encrypt(payload, sub.p256dh, sub.auth);
  const r = await fetchFn(sub.endpoint, { method: 'POST', body, headers: {
    'Content-Type': 'application/octet-stream', 'Content-Encoding': 'aes128gcm', TTL: '86400', Urgency: 'high',
    Authorization: await vapidHeader(sub.endpoint, v.key, v.pub, v.subject) } });
  return { status: r.status, gone: r.status === 404 || r.status === 410, ok: r.status >= 200 && r.status < 300, text: r.ok ? '' : (await r.text()).slice(0, 200) };
}

// one call: take what is waiting, send it, report back (up to 5 rounds of 100)
export async function run(env, fetchFn = fetch) {
  const url = env.SUPABASE_URL, sk = env.SUPABASE_SERVICE_ROLE_KEY;
  const rest = (path, body) => fetchFn(url + '/rest/v1/' + path, { method: body === undefined ? 'GET' : 'POST',
    headers: { apikey: sk, Authorization: 'Bearer ' + sk, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) })
    .then(async (r) => { const t = await r.text(); if (!r.ok) throw new Error(path + ' ' + r.status + ' ' + t.slice(0, 200)); return t ? JSON.parse(t) : null; });
  const set = ((await rest('fm_settings?select=value&key=eq.push')) || [])[0];
  const s = (set && set.value) || {};
  if (!s.vapid_public || !env.VAPID_PRIVATE) throw new Error('VAPID keys missing');
  const v = { pub: s.vapid_public, subject: s.subject || 'mailto:admin@rakizora.com', key: await vapidKey(s.vapid_public, env.VAPID_PRIVATE) };
  let total = 0, sent = 0;
  for (let round = 0; round < 5; round++) {
    const rows = await rest('rpc/fm_push_claim', { n: 100 });
    if (!rows || !rows.length) break;
    const out = await Promise.all(rows.map(async (q) => {
      const payload = JSON.stringify({ title: q.title, body: q.body || '', url: q.url || '', tag: q.tag || '', kind: q.kind });
      const res = { id: q.id, ok: false, err: '', sent: [], gone: [], failed: [] };
      if (!q.subs.length) { res.ok = true; return res; }
      for (const sub of q.subs) {
        try {
          const r = await sendOne(sub, payload, v, fetchFn);
          if (r.ok) res.sent.push(sub.endpoint); else if (r.gone) res.gone.push(sub.endpoint); else { res.failed.push(sub.endpoint); res.err = r.status + ' ' + r.text; }
        } catch (e) { res.failed.push(sub.endpoint); res.err = String(e && e.message || e).slice(0, 200); }
      }
      res.ok = res.sent.length > 0 || (res.failed.length === 0);
      return res;
    }));
    await rest('rpc/fm_push_result', { p: out });
    total += rows.length; sent += out.filter((x) => x.sent.length).length;
  }
  return { taken: total, delivered: sent };
}

export async function handle(req, env, fetchFn = fetch) {
  if (!env.FM_PUSH_HOOK || req.headers.get('x-fm-hook') !== env.FM_PUSH_HOOK) return new Response('forbidden', { status: 403 });
  try { return Response.json(await run(env, fetchFn)); }
  catch (e) { return new Response(String(e && e.message || e), { status: 500 }); }
}

if (typeof Deno !== 'undefined') {
  Deno.serve((req) => handle(req, Deno.env.toObject()));
}
