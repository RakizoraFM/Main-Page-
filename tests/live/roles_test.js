// Live test of every job title (V266): makes sure a test account exists for each title, checks a permission matrix
// through the API (read-only calls), then signs in to the real pages with each account and clicks EVERY visible
// sidebar page (platform) or bottom tab / home card (field app), recording page errors and pages that do not open.
// Writes from the browser are blocked except the usual work-order / engagement / touch calls (same guard as ui_test.js).
// The owner's representative is NOT created: an active owner_rep makes real item / purchase approvals wait for him.
const path=require('path'),fs=require('fs');
const {chromium}=require(require.resolve('playwright',{paths:[process.cwd(),'/usr/lib/node_modules','/usr/local/lib/node_modules']}));
const {ROOT,C,req,msg,login,reporter}=require('./common');const {check,skip,done}=reporter();
const OUT=path.join(__dirname,'out');fs.mkdirSync(OUT,{recursive:true});
// title → [account key, Arabic name, regions]; the five base accounts already exist
const T={sysadmin:['admin'],area_engineer:['engineer'],supervisor:['supervisor'],contractor:['contractor'],viewer:['viewer'],
 dept_manager:['dept','مدير إدارة اختبار',[]],project_manager:['pm','مدير مشروع اختبار',[]],ops_manager:['ops','مدير عمليات اختبار',[]],
 area_manager:['am','مدير منطقة اختبار',['test']],hse_manager:['hse','مدير سلامة اختبار',[]],qa_manager:['qa','مدير جودة اختبار',[]],
 accountant:['acc','محاسب اختبار',['test']],storekeeper:['storekeeper','أمين مستودع اختبار',['test']]};
for(const [t,[k,n]] of Object.entries(T))if(!C[k])C[k]={email:`fm.test.${k}@rakizora.test`,password:process.env.FM_TEST_PASS||'',name:n};
const TOK={},ID={};
const rpc=(who,fn,b)=>req(TOK[who],'POST','/rest/v1/rpc/'+fn,b||{});
const okR=r=>r.ok,deny=r=>!r.ok&&/not allowed|permission|denied|forbidden/i.test(msg(r));
// read-only permission matrix: fn → {title: expect true (allowed) | false (refused)}
const M=[
 ['fm_red_flags',{p_days:30},{sysadmin:1,project_manager:1,qa_manager:1,accountant:1,supervisor:0,contractor:0,area_engineer:0}],
 ['fm_fa_list',{},{sysadmin:1,ops_manager:1,storekeeper:1,accountant:1,supervisor:0,contractor:0}],
 ['fm_wh_abnormal',{p_days:30},{sysadmin:1,storekeeper:1,area_engineer:1,contractor:0,supervisor:0}],
 ['fm_supplier_links_list',{},{sysadmin:1,storekeeper:1,accountant:1}],
 ['fm_gov_report',{p_days:30},{sysadmin:1,project_manager:1,qa_manager:1,accountant:1,supervisor:0,contractor:0}],
 ['fm_tk_audit_list',{p_region:'riyadh',p_month:'2026-10'},{sysadmin:1,qa_manager:1}],
 ['fm_ot_list',{p_month:'2026-10'},{sysadmin:1,supervisor:1,contractor:1,accountant:1}],
 ['fm_custody_recon_list',{p_month:'2026-10'},{sysadmin:1,storekeeper:1,supervisor:1}],
 ['fm_badge_list',{p_year:2026},{sysadmin:1,supervisor:1,contractor:1,viewer:1}],
 ['fm_idea_list',{p_year:2026},{sysadmin:1,supervisor:1,contractor:1}],
 ['fm_weekly_data',{p_week:'2026-10-25'},{sysadmin:1,area_manager:1,accountant:1,supervisor:0,contractor:0}],
 ['fm_usage_report',{p_from:'2026-10-01',p_to:'2026-10-30'},{sysadmin:1,project_manager:1,supervisor:0,contractor:0}],
];
// write-side checks on the server that must be refused (they change nothing)
const W=[
 ['fm_tk_audit_sample',{p_region:'test',p_month:'2026-10',p_rows:[{id:'TEST-X'}],p_pct:5},['supervisor','contractor','area_engineer','accountant'],'only QA / system admin draws audit samples'],
 ['fm_fa_save',{p:{supplier_id:'00000000-0000-0000-0000-000000000000',title:'x'}},['supervisor','contractor','storekeeper','area_engineer'],'only managers / accountant create agreements'],
 ['fm_supplier_inv_act',{p_id:'00000000-0000-0000-0000-000000000000',p_action:'paid'},['contractor','supervisor'],'invoice decisions are staff only'],
 ['fm_ot_act',{p_id:'00000000-0000-0000-0000-000000000000',p_action:'approve'},['contractor'],'unknown overtime row'],
];
(async()=>{const admin=await login('admin');TOK.admin=admin.token;ID.admin=admin.id;
 /* 1) accounts */
 for(const [t,[k,n,regs]] of Object.entries(T)){let x=await login(k).catch(()=>null);
  if(!x&&regs){const c=await rpc('admin','fm_admin_create_user',{p_email:C[k].email,p_password:C[k].password,p_full_name:n,p_role:'staff',p_regions:regs,p_names:[],p_active:true});
   if(!c.ok&&!/already|exists|duplicate/i.test(msg(c))){check('الحسابات','إنشاء حساب '+t,false,msg(c));continue}x=await login(k).catch(e=>({err:e.message}))}
  if(!x||x.err){check('الحسابات','دخول '+t,false,x&&x.err);continue}
  TOK[k]=x.token;ID[k]=x.id;
  if(regs){const r=await req(TOK.admin,'PATCH','/rest/v1/profiles?id=eq.'+x.id,{job_title:t,regions:regs,active:true,must_change_pw:false},{Prefer:'return=minimal'});if(!r.ok)check('الحسابات','تعيين مسمى '+t,false,msg(r))}
  const me=await rpc(k,'fm_my_pos');const pos=typeof me.j==='string'?me.j:'';
  check('الحسابات','حساب '+t+' يدخل ومسماه صحيح',me.ok&&(pos===t||(t==='sysadmin'&&/sysadmin|admin/.test(pos))||(!regs&&pos)),pos||msg(me))}
 /* 2) permission matrix */
 for(const [fn,body,exp] of M)for(const [t,want] of Object.entries(exp)){const k=T[t][0];if(!TOK[k]){skip('الصلاحيات',fn+' — '+t,'لا حساب');continue}
  const r=await rpc(k,fn,body);const missing=/Could not find|does not exist|schema cache/.test(msg(r));if(missing){skip('الصلاحيات',fn,'غير مثبت');break}
  check('الصلاحيات',fn+(want?' متاح لـ ':' ممنوع على ')+t,want?r.ok:!r.ok,r.ok?'':msg(r).slice(0,70))}
 for(const [fn,body,who,why] of W)for(const t of who){const k=T[t][0];if(!TOK[k])continue;const r=await rpc(k,fn,body);
  check('الصلاحيات',fn+' مرفوض لـ '+t,!r.ok,(r.ok?'⚠️ قُبل! ':'')+msg(r).slice(0,60)+' — '+why)}
 /* 3) every page with every account */
 const BLOCK=[];const RPC_OK=/\/rest\/v1\/rpc\/(fm_touch|fm_role|fm_my_pos|fm_[a-z0-9_]*(list|get|me|people|info|data|feed|cfg|can|sees|checks|report|mods_on|names|regions|scores|assignable|candidates|status|waiting|reserved|stagnant|remaining|plan|counts|parts|alts|abnormal|flags|closed|kinds|lead|leaves|my|inbox|watch_list|usage|my_schools|my_school_db|db)[a-z0-9_]*)$/;
 async function route(rt,who){const q=rt.request(),u=q.url(),m=q.method();
  if(/supabase\.co/.test(u)&&!['GET','HEAD','OPTIONS'].includes(m)&&!RPC_OK.test(u.split('?')[0])&&!/\/auth\/v1\/(token|logout|user)/.test(u)){BLOCK.push(who+': '+m+' '+u.replace(/^https:\/\/[^/]+/,'').split('?')[0]);return rt.fulfill({status:403,contentType:'application/json',body:'{"message":"blocked by test guard"}'})}
  try{const h=Object.assign({},q.headers());delete h.host;const r=await fetch(u,{method:m,headers:h,body:['GET','HEAD'].includes(m)?undefined:q.postDataBuffer()});
   const hd={};r.headers.forEach((v,k)=>{if(!/content-encoding|content-length|transfer-encoding/.test(k))hd[k]=v});await rt.fulfill({status:r.status,headers:hd,body:Buffer.from(await r.arrayBuffer())})}catch(e){await rt.abort().catch(()=>{})}}
 const b=await chromium.launch();const SUM={};
 for(const [t,[k]] of Object.entries(T)){if(!TOK[k]){skip('الصفحات',t,'لا حساب');continue}
  const ERR=[];const ctx=await b.newContext({viewport:{width:1400,height:950},acceptDownloads:true});await ctx.route(/^https:\/\//,rt=>route(rt,t));
  const p=await ctx.newPage();p.on('pageerror',e=>ERR.push(e.message.slice(0,140)));p.on('dialog',d=>d.dismiss().catch(()=>{}));
  await p.goto('file://'+path.join(ROOT,'start.html'));await p.waitForTimeout(2500);await p.fill('#l-e',C[k].email);await p.fill('#l-p',C[k].password);await p.click('#l-go');
  await p.waitForTimeout(4000);const pick=await p.$('text=فتح المنصة');if(pick)await pick.click().catch(()=>{});
  await p.waitForURL(/index\.html|field\.html/,{timeout:30000}).catch(()=>{});const field=/field\.html/.test(p.url());await p.waitForTimeout(field?7000:14000);
  const S={app:field?'field':/index/.test(p.url())?'platform':'?',pages:0,fail:[],errs:0};
  if(S.app==='platform'){
   await p.evaluate(()=>{document.querySelectorAll('.fm122-dlg-wrap,#fm183-wiz,.fm183-wrap').forEach(x=>x.remove());document.querySelectorAll('dialog[open]').forEach(d=>d.close())});
   const ids=await p.evaluate(()=>[...document.querySelectorAll('nav.v2-nav .v2-nav-btn[id^="v2-nav-"]')].filter(x=>getComputedStyle(x).display!=='none'&&!x.closest('[hidden]')).map(x=>x.id));
   for(const id of ids){if(/fm168-novaro|logout|clear-all|fm228-lang/.test(id))continue;const e0=ERR.length;
    await p.evaluate(i=>{try{window.fmV103ClosePages?.()}catch(e){}document.querySelectorAll('.fm122-dlg-wrap').forEach(x=>x.remove());document.querySelectorAll('dialog[open]').forEach(d=>{try{d.close()}catch(e){}});document.getElementById(i)?.click()},id);
    await p.waitForTimeout(1600);
    const opened=await p.evaluate(()=>{const vis=el=>{if(!el)return false;const r=el.getBoundingClientRect();return r.width>40&&r.height>40&&getComputedStyle(el).display!=='none'&&getComputedStyle(el).visibility!=='hidden'};
     return [...document.querySelectorAll('.fm103-page,#eng-page,#fm158-qa,.fm122-dlg-wrap,dialog[open],#v2-overlay,.v2-modal,#fm122-settings,.fm92-page,section.open')].some(vis)||!!document.querySelector('#fm237-tabs')||location.hash.length>1});
    S.pages++;if(!opened)S.fail.push('لم تفتح: '+id);if(ERR.length>e0)S.fail.push(id+' ⇒ '+ERR.slice(e0).join(' | '))}
   await p.screenshot({path:path.join(OUT,'roles_'+t+'.png')})}
  else if(S.app==='field'){await p.setViewportSize({width:390,height:820});await p.waitForTimeout(800);
   const tabs=await p.evaluate(()=>[...document.querySelectorAll('.bnav button[data-v]')].filter(x=>getComputedStyle(x).display!=='none').map(x=>x.dataset.v));
   for(const v of tabs){const e0=ERR.length;await p.evaluate(x=>document.querySelector(`.bnav button[data-v="${x}"]`)?.click(),v);await p.waitForTimeout(1800);S.pages++;if(ERR.length>e0)S.fail.push('tab '+v+' ⇒ '+ERR.slice(e0).join(' | '))}
   await p.evaluate(()=>document.querySelector('.bnav button[data-v=home]')?.click());await p.waitForTimeout(1500);
   const cards=await p.evaluate(()=>[...document.querySelectorAll('#app .card.hello ~ button[id], #app button[id$="-h"]')].map(x=>x.id).filter((x,i,a)=>a.indexOf(x)===i));
   for(const id of cards){const e0=ERR.length;await p.evaluate(i=>document.getElementById(i)?.click(),id);await p.waitForTimeout(1500);S.pages++;
    const sh=await p.evaluate(()=>!!document.querySelector('.sheet.open,dialog[open],[id^=f][class*=sheet].open'));if(!sh)S.fail.push('لم تفتح بطاقة: '+id);if(ERR.length>e0)S.fail.push(id+' ⇒ '+ERR.slice(e0).join(' | '));
    await p.evaluate(()=>{document.querySelectorAll('.sheet.open [data-x],.sheet.open .hd button').forEach(b=>b.click());document.querySelectorAll('.sheet.open').forEach(s=>s.classList.remove('open'));document.querySelectorAll('dialog[open]').forEach(d=>d.close())});await p.waitForTimeout(300)}
   await p.screenshot({path:path.join(OUT,'roles_'+t+'.png')})}
  S.errs=ERR.length;SUM[t]=S;
  check('الصفحات',`${t} (${S.app}): فُتحت ${S.pages} صفحة/بطاقة`,S.app!=='?'&&!S.fail.length,S.fail.slice(0,6).join(' ؛ '));await ctx.close()}
 await b.close();
 fs.writeFileSync(path.join(__dirname,'roles_summary.json'),JSON.stringify({SUM,BLOCK:[...new Set(BLOCK)]},null,1));
 console.log('\nكتابات منعها حارس الاختبار:',[...new Set(BLOCK.map(x=>x.split(': ')[1]))].slice(0,30).join('\n'));
 done('roles_results.json')})().catch(e=>{console.error(e);process.exitCode=1});
