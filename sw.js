/* RakizoraFM — service worker (V187): shows the push notifications sent by the Edge Function «fm-push» and opens the right
   page when one is tapped. It does not cache or intercept any request (no fetch handler), so the apps load as before.
   A message is JSON {title, body, url, tag, kind}; url is relative to the site (index.html#wo=… / field.html#wo=…). */
'use strict';
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: 'RakizoraFM', body: e.data ? e.data.text() : '' }; }
  const title = d.title || 'RakizoraFM';
  e.waitUntil(self.registration.showNotification(title, {
    body: d.body || '', tag: d.tag || undefined, renotify: !!d.tag, dir: 'rtl', lang: 'ar',
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
