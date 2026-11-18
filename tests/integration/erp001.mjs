import assert from 'node:assert/strict';
import fs from 'node:fs';
import {db,users,rpc,asUser} from './pg_adapter.mjs';
// V352: ERP001 is section 96 of supabase_setup.sql (already loaded by pg_adapter); re-applied below for the rerun check.
const full=fs.readFileSync(new URL('../../supabase_setup.sql',import.meta.url),'utf8');
const sql=full.slice(full.indexOf('-- ---------- 96)'));
let count=0;
async function test(name,fn){await fn();console.log('PASS',name);count++;}
try {
 await db.exec(sql);
 const create=(code,region='riyadh')=>rpc('admin','fm_erp_project_create',{p_code:code,p_name:'مشروع اختبار',p_region:region});
 const member=(p,u,on=true)=>rpc('admin','fm_erp_project_member_set',{p_project:p,p_user:users[u].id,p_enabled:on,p_reason:'اختبار صلاحية المشروع'});
 const bind=(wo,p,rev=0)=>rpc('admin','fm_erp_work_order_project_set',{p_wo:wo,p_project:p,p_expected_revision:rev,p_reason:'مراجعة ربط أمر العمل'});
 const a=await create('erp-a'), b=await create('ERP-B'), q=await create('ERP-Q','qassim');
 const wo=(await db.query(`insert into work_orders(code,title,region,created_by,assignee) values('ERP-TEST','اختبار ERP','riyadh',$1,$2) returning id`,[users.admin.id,users.supervisor.id])).rows[0].id;
 const hidden=(await db.query(`insert into work_orders(code,title,region,created_by,assignee) values('ERP-HIDDEN','أمر غير متاح','riyadh',$1,$1) returning id`,[users.admin.id])).rows[0].id;
 await test('only active admin can create projects; anonymous denied',async()=>{
  for(const who of ['engineer','supervisor','viewer',null]) await assert.rejects(()=>rpc(who,'fm_erp_project_create',{p_code:'NO-'+(who||'ANON'),p_name:'test',p_region:'riyadh'}));
 });
 await test('normalized codes remain unique; invalid identifiers rejected',async()=>{
  await assert.rejects(()=>create(' erp-a '));await assert.rejects(()=>create('bad code'));
 });
 await test('project metadata hidden until membership is granted',async()=>{
  assert.equal((await asUser('supervisor',tx=>tx.query('select id from fm_erp_projects'))).rows.length,0);
  await member(a,'supervisor');
  assert.deepEqual((await asUser('supervisor',tx=>tx.query('select id from fm_erp_projects'))).rows.map(x=>x.id),[a]);
 });
 await test('initial assignment and same-target retry preserve one audited link',async()=>{
  assert.equal(await bind(wo,a),1);assert.equal(await bind(wo,a,1),1);
  assert.equal((await db.query("select count(*)::int n from fm_erp_project_events where entity_id=$1 and action='work_order_project'",[wo])).rows[0].n,1);
 });
 await test('project membership does not grant access to hidden work orders',async()=>{
  await bind(hidden,a);
  const ids=(await asUser('supervisor',tx=>tx.query('select wo_id from fm_erp_work_order_projects'))).rows.map(x=>x.wo_id);
  assert(ids.includes(wo));assert(!ids.includes(hidden));
 });
 await test('non-admin cannot bind, change membership, or bypass RPC via table writes',async()=>{
  await assert.rejects(()=>rpc('supervisor','fm_erp_work_order_project_set',{p_wo:wo,p_project:b,p_expected_revision:1,p_reason:'unauthorized'}));
  await assert.rejects(()=>rpc('supervisor','fm_erp_project_member_set',{p_project:b,p_user:users.supervisor.id,p_enabled:true,p_reason:'unauthorized'}));
  for(const query of ["update fm_erp_work_order_projects set revision=99","delete from fm_erp_project_events","insert into fm_erp_project_members(project_id,user_id) values('"+b+"','"+users.supervisor.id+"')"])
   await assert.rejects(()=>asUser('supervisor',tx=>tx.exec(query)));
 });
 await test('wrong region and stale corrections rejected without partial changes',async()=>{
  await assert.rejects(()=>bind(wo,q,1),/region mismatch/);
  await assert.rejects(()=>bind(wo,b,0),/stale/);
  assert.equal((await db.query('select project_id from fm_erp_work_order_projects where wo_id=$1',[wo])).rows[0].project_id,a);
 });
 await test('later work-order region edits cannot invalidate a project link',async()=>{
  await assert.rejects(()=>db.query("update work_orders set region='qassim' where id=$1",[wo]),/region mismatch/);
  assert.equal((await db.query('select region from work_orders where id=$1',[wo])).rows[0].region,'riyadh');
 });
 await test('correction records previous project and increments revision',async()=>{
  assert.equal(await bind(wo,b,1),2);
  const event=(await db.query("select old_value,new_value from fm_erp_project_events where entity_id=$1 order by id desc limit 1",[wo])).rows[0];
  assert.equal(event.old_value.project_id,a);assert.equal(event.new_value.project_id,b);
  assert.equal((await asUser('supervisor',tx=>tx.query('select wo_id from fm_erp_work_order_projects where wo_id=$1',[wo]))).rows.length,0);
 });
 await test('membership revocation immediately hides project metadata',async()=>{
  await member(a,'supervisor',false);
  assert.equal((await asUser('supervisor',tx=>tx.query('select id from fm_erp_projects'))).rows.length,0);
 });
 await test('inactive users and inactive projects are rejected',async()=>{
  await db.query('update profiles set active=false where id=$1',[users.viewer.id]);
  await assert.rejects(()=>member(a,'viewer'),/active user/);
  await db.query('update fm_erp_projects set active=false where id=$1',[q]);
  await assert.rejects(()=>bind(wo,q,2),/active project/);
  await db.query('update profiles set active=false where id=$1',[users.admin.id]);
  await assert.rejects(()=>create('BLOCKED'),/not allowed/);
  await db.query('update profiles set active=true where id=$1',[users.admin.id]);
 });
 await test('reapplying migration preserves assignments and audit history',async()=>{
  const before=(await db.query('select count(*)::int n from fm_erp_project_events')).rows[0].n;
  await db.exec(sql);
  assert.equal((await db.query('select count(*)::int n from fm_erp_project_events')).rows[0].n,before);
  assert.equal((await db.query('select revision from fm_erp_work_order_projects where wo_id=$1',[wo])).rows[0].revision,2);
 });
 console.log(`ERP001: ${count} scenarios passed against full setup in isolated PostgreSQL/PGlite`);
} finally {await db.close();}
