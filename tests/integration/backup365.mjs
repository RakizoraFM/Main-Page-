// V365: the fm-backup Edge Function with a fake Supabase (RPC + Storage) and a fake Resend. No network.
// Run: node tests/integration/backup365.mjs   (optional FM365_PSQL="psql -h /tmp -p 5433 -U postgres -d <db>" runs the RPCs
// against a local database that has supabase_setup.sql, as the service role)
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
const here = dirname(fileURLToPath(import.meta.url));
const dir = mkdtempSync(join(tmpdir(), 'fm365-'));
writeFileSync(join(dir, 'f.mjs'), readFileSync(join(here, '../../supabase/functions/fm-backup/index.ts'), 'utf8'));
const F = await import(join(dir, 'f.mjs'));
const URL0 = 'https://p.supabase.co';
const env = { SUPABASE_URL: URL0, SUPABASE_ANON_KEY: 'anon', SUPABASE_SERVICE_ROLE_KEY: 'svc', RESEND_API_KEY: 're', MAIL_FROM: 'b@x.test' };

function fake(opts) {
  const files = new Map(Object.entries(opts.storage || {})), mails = [], calls = [];
  let copied = new Map(), state = { job: opts.job }, result = null;
  const tables = { profiles: [{ id: 1, name: 'أ' }, { id: 2, name: 'ب' }], tickets: Array.from({ length: 2500 }, (_, i) => ({ id: i })) };
  const R = {
    fm_backup_srv_secret: () => 'hook-123',
    fm_backup_srv_claim: () => { const j = state.job; state.job = null; return j || { job: null }; },
    fm_backup_srv_tables: () => Object.keys(tables).map((t) => ({ t, n: tables[t].length })),
    fm_backup_srv_page: (a) => tables[a.p_table].slice(a.p_offset, a.p_offset + a.p_limit),
    fm_backup_srv_objects: (a) => [...files.keys()].filter((k) => !k.startsWith('fm-backups/')).map((k) => ({ b: k.split('/')[0], n: k.split('/').slice(1).join('/'), s: files.get(k).length, u: '2026-01-01' }))
      .filter((o) => !copied.has(o.b + '/' + o.n)).filter((o) => (o.b + '\u0000' + o.n) > (a.p_bucket + '\u0000' + a.p_name)).slice(0, a.p_n),
    fm_backup_srv_copied: (a) => { a.p.forEach((o) => copied.set(o.b + '/' + o.n, 1)); return a.p.length; },
    fm_backup_srv_old: () => [...files.keys()].filter((k) => k.startsWith('fm-backups/db/')).sort().reverse().slice(1).map((k) => k.slice(11)),
    fm_backup_srv_result: (a) => { result = a.p; return null; },
    fm_backup_srv_can: () => opts.can !== false,
  };
  const j = (b, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } });
  const fetchFn = async (u, init = {}) => {
    calls.push(u);
    if (u === 'https://api.resend.com/emails') { mails.push(JSON.parse(init.body)); return j({ id: 'm1' }); }
    if (u.startsWith(URL0 + '/rest/v1/rpc/')) {
      const fn = u.split('/').pop(), a = JSON.parse(init.body || '{}');
      if (fn === 'fm_backup_srv_can' && init.headers.Authorization !== 'Bearer user-jwt') return j({ message: 'jwt' }, 401);
      if (opts.psql && fn !== 'fm_backup_srv_claim' && fn !== 'fm_backup_srv_result' && fn !== 'fm_backup_srv_can') return j(opts.psql(fn, a));
      return j(R[fn](a));
    }
    const p = decodeURIComponent(u.slice((URL0 + '/storage/v1/').length));
    if (p === 'object/copy') {
      const b = JSON.parse(init.body), src = files.get(b.bucketId + '/' + b.sourceKey);
      if (!src) return j({ message: 'not found' }, 404);
      files.set(b.destinationBucket + '/' + b.destinationKey, src); return j({ Key: b.destinationKey });
    }
    if (p.startsWith('object/sign/')) return j({ signedURL: '/object/sign/' + p.slice(12) + '?token=t' });
    if (p === 'object/fm-backups' && init.method === 'DELETE') { JSON.parse(init.body).prefixes.forEach((k) => files.delete('fm-backups/' + k)); return j([]); }
    if (p.startsWith('object/') && init.method === 'POST') { files.set(p.slice(7), new Uint8Array(init.body)); return j({ Key: p }); }
    return j({ message: 'unexpected ' + p }, 400);
  };
  return { fetchFn, files, mails, calls, get result() { return result; } };
}

let pass = 0;
const ok = (c, m) => { assert.ok(c, m); pass++; };

// 1) db job: file in the V351 format, old ones pruned, files mirrored, e-mail with a link
{
  const s = fake({ job: { job: 'db', pass: 'secretpass1', keep: 1, files: true, link_days: 7, to: ['a@x.test'], company: 'شركة', mail: { from_name: 'المنصة' } },
    storage: { 'wo-photos/a/1.jpg': new Uint8Array([1, 2, 3]), 'ticket-photos/b.jpg': new Uint8Array([4]), 'fm-backups/db/2020-01-01.fmbak': new Uint8Array([9]) } });
  const r = await F.handle(new Request('https://f/fm-backup', { method: 'POST', headers: { 'x-fm-hook': 'hook-123' } }), env, s.fetchFn);
  const b = await r.json();
  ok(r.status === 200 && b.ok === true, 'db job ok: ' + JSON.stringify(b));
  ok(/^db\/\d{4}-\d\d-\d\d-\d\d-\d\d-\d\d\.fmbak$/.test(b.path), 'path ' + b.path);
  const u8 = s.files.get('fm-backups/' + b.path);
  ok(u8 && u8[0] === 70 && u8[1] === 77 && u8[2] === 66 && u8[3] === 75 && u8[4] === 1, 'FMBK header');
  const plain = await F.decrypt(u8, 'secretpass1');
  ok(plain[0] === 0x1f && plain[1] === 0x8b, 'gzip inside');
  const js = JSON.parse(new TextDecoder().decode(new Uint8Array(await new Response(new Blob([plain]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer())));
  ok(js.fmbak === 1 && js.tables.tickets.n === 2500 && js.tables.tickets.rows.length === 2500 && js.tables.profiles.rows[1].name === 'ب', 'content');
  ok(b.tables === 2 && b.rows === 2502, 'counts');
  ok(!s.files.has('fm-backups/db/2020-01-01.fmbak'), 'old backup pruned');
  ok(s.files.has('fm-backups/files/wo-photos/a/1.jpg') && s.files.has('fm-backups/files/ticket-photos/b.jpg') && b.files_new === 2 && b.more === false, 'files mirrored');
  ok(s.mails.length === 1 && s.mails[0].to[0] === 'a@x.test' && /token=t/.test(s.mails[0].html) && /المنصة/.test(s.mails[0].from) && b.mailed === 1, 'mail sent with link');
  ok(s.result && s.result.job === 'db' && s.result.ok === true, 'result recorded');
  let bad = false; try { await F.decrypt(u8, 'wrongpass'); } catch (e) { bad = true; } ok(bad, 'wrong password fails');
}
// 2) bad hook / nothing due / no password
{
  const s = fake({ job: { job: 'db', pass: null, files: false } });
  const r0 = await F.handle(new Request('https://f', { method: 'POST', headers: { 'x-fm-hook': 'nope' } }), env, s.fetchFn);
  ok(r0.status === 403, 'bad hook refused');
  const r1 = await F.handle(new Request('https://f', { method: 'POST', headers: { 'x-fm-hook': 'hook-123' } }), env, s.fetchFn);
  const b1 = await r1.json();
  ok(b1.ok === false && /password/.test(b1.err) && s.result.ok === false, 'no password → failure recorded');
  const r2 = await F.handle(new Request('https://f', { method: 'POST', headers: { 'x-fm-hook': 'hook-123' } }), env, s.fetchFn);
  ok((await r2.json()).job === null, 'nothing due');
}
// 3) files job running out of time → more
{
  const st = {}; for (let i = 0; i < 30; i++) st['wo-photos/p' + String(i).padStart(2, '0') + '.jpg'] = new Uint8Array([i]);
  const s = fake({ job: { job: 'files' }, storage: st });
  let n = 0; const slow = async (u, i) => { if (/object\/copy/.test(u) && ++n > 5) await new Promise((r) => setTimeout(r, 30)); return s.fetchFn(u, i); };
  const r = await F.runJob(env, slow, 200);
  ok(r.body.ok && r.body.more === true && r.body.files_new > 0 && r.body.files_new < 30, 'partial mirror: ' + r.body.files_new);
  const s2 = fake({ job: { job: 'files' }, storage: st });
  const r2 = await F.runJob(env, s2.fetchFn, 20000);
  ok(r2.body.more === false && r2.body.files_new === 30, 'full mirror');
}
// 4) no mail secrets → backup kept, mail skipped
{
  const s = fake({ job: { job: 'db', pass: 'secretpass1', keep: 8, files: false, to: ['a@x.test'] } });
  const r = await F.runJob({ ...env, RESEND_API_KEY: '' }, s.fetchFn);
  ok(r.body.ok === true && r.body.mailed === 0 && /not configured/.test(r.body.mail_err), 'mail skipped');
}
// 5) platform sign
{
  const s = fake({});
  const mk = (jwt, body) => new Request('https://f', { method: 'POST', headers: { Authorization: 'Bearer ' + jwt, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const r = await F.handle(mk('user-jwt', { action: 'sign', path: 'db/2026-11-18-02-00-00.fmbak' }), env, s.fetchFn);
  const b = await r.json(); ok(r.status === 200 && b.url.startsWith(URL0 + '/storage/v1/object/sign/fm-backups/db/'), 'signed url ' + b.url);
  ok((await F.handle(mk('user-jwt', { action: 'sign', path: '../x' }), env, s.fetchFn)).status === 400, 'bad path');
  ok((await F.handle(mk('other', { action: 'sign', path: 'db/a.fmbak' }), env, s.fetchFn)).status === 403, 'not allowed');
  const s2 = fake({ can: false });
  ok((await F.handle(mk('user-jwt', { action: 'sign', path: 'db/a.fmbak' }), env, s2.fetchFn)).status === 403, 'not sysadmin');
}
// 6) optional: the table RPCs from a real local database
if (process.env.FM365_PSQL) {
  const [cmd, ...args] = process.env.FM365_PSQL.split(' ');
  const lit = (v) => typeof v === 'number' ? String(v) : typeof v === 'object' ? "'" + JSON.stringify(v).replace(/'/g, "''") + "'::jsonb" : "'" + String(v).replace(/'/g, "''") + "'";
  const psql = (fn, a) => {
    const sql = `set role service_role; select to_jsonb(public.${fn}(${Object.entries(a).map(([k, v]) => k + ' => ' + lit(v)).join(', ')}));`;
    const out = execFileSync(cmd, [...args, '-At', '-c', sql], { encoding: 'utf8' }).trim().split('\n').pop();
    return JSON.parse(out);
  };
  const s = fake({ job: { job: 'db', pass: 'secretpass1', keep: 8, files: true, to: [] }, psql });
  const r = await F.runJob(env, s.fetchFn);
  ok(r.body.ok === true && r.body.tables > 100, 'real tables: ' + r.body.tables + ' tables, ' + r.body.rows + ' rows, ' + r.body.size + ' bytes');
}
console.log('PASS: ' + pass + ' checks');
