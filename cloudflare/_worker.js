// Cloudflare Pages (advanced mode) — runs only for the paths listed in _routes.json (the app pages).
// Cloudflare's asset server redirects «/start.html» to «/start» (308). The service worker, the saved
// offline copies, push links («index.html#wo=…») and the install manifest all use «*.html», so the
// page is served at its own address instead: the body of «/start» with status 200, no redirect.
// Optional: env variable CANONICAL_HOST (e.g. app.example.com) sends visitors of any other host
// (the *.pages.dev address) to it, keeping the path, query and hash.
const PAGES = new Set(['index', 'field', 'start', 'rate', 'school', 'supplier', 'saas', 'try']);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const host = (env.CANONICAL_HOST || '').trim().toLowerCase();
    if (host && url.hostname !== host && /\.pages\.dev$/.test(url.hostname)) {
      url.hostname = host;
      return Response.redirect(url.toString(), 301);
    }
    const m = url.pathname.match(/^\/([a-z]+)\.html$/);
    if (request.method === 'GET' && m && PAGES.has(m[1])) {
      const a = new URL(url);
      a.pathname = m[1] === 'index' ? '/' : '/' + m[1];
      const r = await env.ASSETS.fetch(new Request(a.toString(), { headers: request.headers }));
      if (r.status === 200 || r.status === 304) {
        const h = new Headers(r.headers);
        h.set('Cache-Control', 'no-cache');
        return new Response(r.status === 304 ? null : r.body, { status: r.status, headers: h });
      }
      return r;
    }
    return env.ASSETS.fetch(request);
  }
};
