/* RakizoraFM — service worker.
   V187: shows the push notifications sent by the Edge Function «fm-push» and opens the right page when one is tapped.
   V188: the installed app works offline —
     • pages (start / index / field …): network first (always the newest version when online), the saved copy when offline;
     • libraries and fonts (cdnjs, jsdelivr, Google Fonts): saved and refreshed in the background;
     • map tiles (OpenStreetMap): saved as they are seen, at most TILE_MAX;
     • everything else (Supabase, the version check «?fmc=», uploads) goes to the network untouched.
   A page posts {fmCache:{page, libs}} after registering, so what it loaded before the worker existed is saved too. */
'use strict';
const SHELL = 'fm-shell-v188', PAGES = 'fm-pages', LIBS = 'fm-libs', TILES = 'fm-tiles', TILE_MAX = 3000;
const SHELL_FILES = ['start.html', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/icon-maskable-512.png', 'icons/apple-touch-icon.png'];
const APP_PAGES = new Set(['start.html', 'index.html', 'field.html', 'school.html', 'rate.html', 'try.html', 'saas.html']);
const LIB_HOST = /^(cdnjs\.cloudflare\.com|cdn\.jsdelivr\.net|fonts\.googleapis\.com|fonts\.gstatic\.com)$/;
const TILE_HOST = /(^|\.)tile\.openstreetmap\.org$/;
const at = (p) => new URL(p, self.registration.scope).href;

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(SHELL);
    await Promise.all(SHELL_FILES.map((f) => c.add(new Request(at(f), { cache: 'reload' })).catch(() => null)));
    const p = await caches.open(PAGES);
    if (!(await p.match(at('start.html')))) { const r = await c.match(at('start.html')); if (r) await p.put(at('start.html'), r); }
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k.startsWith('fm-shell-') && k !== SHELL) await caches.delete(k);
    await self.clients.claim();
  })());
});

// the page name of a same-origin URL inside our scope ('' → index.html), or null
function pageOf(url) {
  const scope = new URL(self.registration.scope);
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) return null;
  const name = url.pathname.slice(scope.pathname.length) || 'index.html';
  return APP_PAGES.has(name) ? name : null;
}
const offlinePage = () => new Response(`<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>لا يوجد اتصال</title></head><body style="font-family:Cairo,Tahoma,sans-serif;display:flex;min-height:90vh;align-items:center;justify-content:center;text-align:center;background:#f8fafc;color:#0f172a">
<div><div style="font-size:48px">📴</div><h2>لا يوجد اتصال بالإنترنت</h2><p>هذه الصفحة لم تُفتح من قبل على هذا الجهاز، فلا توجد منها نسخة محفوظة.<br>اتصل بالإنترنت وافتحها مرة واحدة لتعمل بعدها دون اتصال.</p>
<button onclick="location.reload()" style="font:800 15px Cairo,Tahoma;padding:10px 22px;border-radius:12px;border:0;background:#0f766e;color:#fff">إعادة المحاولة</button></div></body></html>`,
  { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });

async function pageFirstNetwork(req, name) {
  const key = at(name), c = await caches.open(PAGES);
  const net = fetch(req).then((r) => { if (r && r.ok && r.type === 'basic') c.put(key, r.clone()).catch(() => {}); return r; });
  try {
    // a very slow network with a saved copy: show the saved copy after 8 s (the network still refreshes it)
    const saved = await c.match(key);
    if (!saved) return await net;
    return await Promise.race([net, new Promise((ok) => setTimeout(() => ok(saved), 8000))]);
  } catch (err) {
    return (await c.match(key)) || (await caches.match(key)) || offlinePage();
  }
}
async function libStaleWhileRevalidate(req) {
  const c = await caches.open(LIBS), hit = await c.match(req);
  const net = fetch(req).then((r) => { if (r && (r.ok || r.type === 'opaque')) c.put(req, r.clone()).catch(() => {}); return r; }).catch(() => null);
  return hit || (await net) || new Response('', { status: 504 });
}
let tileCount = -1;
async function tileCacheFirst(req) {
  const c = await caches.open(TILES), hit = await c.match(req);
  if (hit) return hit;
  try {
    const r = await fetch(req);
    if (r && (r.ok || r.type === 'opaque')) {
      await c.put(req, r.clone());
      if (tileCount < 0) tileCount = (await c.keys()).length; else tileCount++;
      if (tileCount > TILE_MAX) { const ks = await c.keys(); for (const k of ks.slice(0, ks.length - TILE_MAX + 200)) await c.delete(k); tileCount = TILE_MAX - 200; }
    }
    return r;
  } catch (err) { return new Response('', { status: 504 }); }
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (req.mode === 'navigate') { const name = pageOf(url); if (name) e.respondWith(pageFirstNetwork(req, name)); return; }
  if (url.origin === self.location.origin) {
    if (/\/(icons\/[^/]+\.png|manifest\.webmanifest)$/.test(url.pathname)) e.respondWith(caches.match(req).then((h) => h || fetch(req)));
    return;   // other same-origin requests (the «?fmc=» version check, data) go to the network
  }
  if (LIB_HOST.test(url.hostname)) { e.respondWith(libStaleWhileRevalidate(req)); return; }
  if (TILE_HOST.test(url.hostname)) { e.respondWith(tileCacheFirst(req)); return; }
});

// a page asks to save itself and the libraries it already loaded
self.addEventListener('message', (e) => {
  const d = e.data && e.data.fmCache;
  if (!d) return;
  e.waitUntil((async () => {
    if (d.page && APP_PAGES.has(d.page)) {
      const c = await caches.open(PAGES), key = at(d.page);
      if (!(await c.match(key))) { try { const r = await fetch(key, { cache: 'no-cache' }); if (r.ok) await c.put(key, r); } catch (err) {} }
    }
    const L = await caches.open(LIBS);
    for (const u of (d.libs || []).slice(0, 80)) {
      try {
        const host = new URL(u).hostname;
        if (!LIB_HOST.test(host) || await L.match(u)) continue;
        const cors = host === 'fonts.gstatic.com' || host === 'fonts.googleapis.com';   // fonts are always fetched with CORS
        const r = await fetch(u, { mode: cors ? 'cors' : 'no-cors' });
        if (r && (r.ok || r.type === 'opaque')) await L.put(u, r);
      } catch (err) {}
    }
  })());
});

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: 'RakizoraFM', body: e.data ? e.data.text() : '' }; }
  const title = d.title || 'RakizoraFM';
  e.waitUntil(self.registration.showNotification(title, {
    body: d.body || '', tag: d.tag || undefined, renotify: !!d.tag, dir: 'rtl', lang: 'ar', icon: at('icons/icon-192.png'),
    data: { url: d.url || '', kind: d.kind || '' }, requireInteraction: d.kind === 'wo_esc' || d.kind === 'wo_stop'
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const rel = (e.notification.data && e.notification.data.url) || 'start.html';
  const target = new URL(rel, self.registration.scope);
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // an open window of the same app: focus it and let it open the item
    for (const w of wins) {
      const u = new URL(w.url);
      if (u.origin === target.origin && u.pathname === target.pathname) {
        await w.focus();
        w.postMessage({ fmPush: true, hash: target.hash.replace(/^#/, '') });
        return;
      }
    }
    await self.clients.openWindow(target.href);
  })());
});
