// Live UI test: the repo's pages against the real Supabase project, signed in as each test account.
// Every browser request is fetched by Node (proxy + certificate checks stay on). Writes are allowed only to work
// orders, their photos and the school-engagement tables; any other write is blocked and listed in the result.
// Run after api_test.js (it uses the orders that test created). Screenshots go to tests/live/out/.
const path=require('path'),fs=require('fs');
const {chromium}=require(require.resolve('playwright',{paths:[process.cwd(),'/usr/lib/node_modules','/usr/local/lib/node_modules']}));
const {ROOT,C,reporter}=require('./common');const {check,skip,done}=reporter();
const OUT=path.join(__dirname,'out');fs.mkdirSync(OUT,{recursive:true});const BLOCK=[],ERR=[];
const RPC_OK=/\/rest\/v1\/rpc\/(fm_wo_create|fm_wo_create_many|fm_wo_act|fm_wo_repair|fm_wo_assignable|fm_eng_submit|fm_eng_lead|fm_wo_cron_on|fm_role|fm_names)$/;
const W_OK=/\/rest\/v1\/(wo_photos|fm_eng_observations|wo_events)(\?|$)|\/storage\/v1\/object\/(wo-photos|school-engagement)\/|\/storage\/v1\/object\/sign\/|\/auth\/v1\/(token|logout|user)/;
async function route(rt,who){const q=rt.request(),u=q.url(),m=q.method();
 if(/supabase\.co/.test(u)&&!['GET','HEAD','OPTIONS'].includes(m)&&!RPC_OK.test(u.split('?')[0])&&!W_OK.test(u)){BLOCK.push(who+': '+m+' '+u.replace(/^https:\/\/[^/]+/,'').split('?')[0]);return rt.fulfill({status:403,contentType:'application/json',body:'{"message":"blocked by test guard"}'})}
 try{const h=Object.assign({},q.headers());delete h.host;const r=await fetch(u,{method:m,headers:h,body:['GET','HEAD'].includes(m)?undefined:q.postDataBuffer()});
  const hd={};r.headers.forEach((v,k)=>{if(!/content-encoding|content-length|transfer-encoding/.test(k))hd[k]=v});await rt.fulfill({status:r.status,headers:hd,body:Buffer.from(await r.arrayBuffer())})}catch(e){await rt.abort().catch(()=>{})}}
async function session(b,who,vp){const ctx=await b.newContext({viewport:vp||{width:1400,height:950},acceptDownloads:true});await ctx.route(/^https:\/\//,rt=>route(rt,who));
 const p=await ctx.newPage();p.on('pageerror',e=>ERR.push(who+': '+e.message));p.on('dialog',d=>d.accept());
 await p.goto('file://'+path.join(ROOT,'start.html'));await p.waitForTimeout(2500);await p.fill('#l-e',C[who].email);await p.fill('#l-p',C[who].password);await p.click('#l-go');
 await p.waitForTimeout(4000);const pick=await p.$('text=فتح المنصة');if(pick)await pick.click();   /* admin / engineer may get a chooser */
 await p.waitForURL(/index\.html|field\.html/,{timeout:30000}).catch(()=>{});await p.waitForTimeout(/field/.test(p.url())?6000:12000);
 /* V157: the platform shows «بورتالي» once per session as a full-screen overlay; check it, then close it so the clicks below reach the page */
 if(/index\.html/.test(p.url())){const pt=await p.evaluate(()=>{const r=document.getElementById('fm157-portal');return r&&!r.hidden?r.innerText:''});
  check('البورتال','«بورتالي» يظهر عند الدخول ('+who+')',/بورتالي|صلاحيات|نطاق/.test(pt));
  if(pt)await p.click('#fm157-portal [data-x]',{timeout:5000}).catch(()=>p.evaluate(()=>{document.getElementById('fm157-portal').hidden=true}));await p.waitForTimeout(300)}
 return {ctx,p}}
const txt=(p,sel)=>p.evaluate(s=>document.querySelector(s)?.innerText||'',sel);
let b;(async()=>{b=await chromium.launch();let s;
 /* supervisor — field app */
 s=await session(b,'supervisor',{width:390,height:820});check('الدخول','المشرف يُوجَّه لتطبيق الميدان',/field\.html/.test(s.p.url()));
 check('الميدان','تبويب «التواصل» ظاهر للمشرف',!!await s.p.$('.bnav button[data-v=eng]'));
 await s.p.click('.bnav button[data-v=wo]').catch(()=>{});await s.p.waitForTimeout(2000);
 const all=async()=>{for(const t of ['الكل','مغلقة']){const x=await s.p.$(`button:has-text("${t}")`);if(x){await x.click();await s.p.waitForTimeout(1200);return}}};
 await all();check('الميدان','المشرف يرى الأمر المسند إليه',/مهندس→مشرف/.test(await txt(s.p,'body')));
 const mine=await s.p.$('button:has-text("أسندتها")');if(mine){await mine.click();await s.p.waitForTimeout(1200);await all()}
 check('الميدان','المشرف يرى الأمر الذي أسنده («أسندتها»)',/مشرف→مقاول/.test(await txt(s.p,'body')));await s.p.screenshot({path:path.join(OUT,'supervisor_wo.png')});
 await s.p.click('.bnav button[data-v=eng]').catch(()=>{});await s.p.waitForTimeout(4000);
 check('التواصل','المشرف يفتح صفحة التواصل ويرى مدرسة الاختبار',/مدرسة اختبار RakizoraFM/.test(await txt(s.p,'#eng-page')));await s.p.screenshot({path:path.join(OUT,'supervisor_eng.png')});await s.ctx.close();
 /* contractor — field app */
 s=await session(b,'contractor',{width:390,height:820});check('الدخول','المقاول يُوجَّه لتطبيق الميدان',/field\.html/.test(s.p.url()));
 check('الميدان','لا يظهر تبويب «التواصل» للمقاول',!await s.p.$('.bnav button[data-v=eng]'));
 await s.p.click('.bnav button[data-v=wo]').catch(()=>{});await s.p.waitForTimeout(2000);await all();const cw=await txt(s.p,'body');
 check('الميدان','المقاول يرى أوامره فقط',/إصلاح/.test(cw)&&!/مهندس→مشرف/.test(cw));await s.p.screenshot({path:path.join(OUT,'contractor_wo.png')});await s.ctx.close();
 /* engineer — platform */
 s=await session(b,'engineer');check('الدخول','المهندس يُوجَّه للمنصة',/index\.html/.test(s.p.url()));
 await s.p.evaluate(()=>window.fmV145OpenWorkOrders&&fmV145OpenWorkOrders());await s.p.waitForTimeout(3000);await s.p.evaluate(()=>{fmV145X.F.k='all';fmV145X.render()});await s.p.waitForTimeout(800);
 const ew=await txt(s.p,'#fm145-page');check('أوامر العمل','المهندس يرى أوامره وأوامر فريقه',/مهندس→مشرف/.test(ew)&&/مشرف→مقاول/.test(ew));await s.p.screenshot({path:path.join(OUT,'engineer_wo.png')});
 const row=await s.p.$('#fm145-page tr[data-id]:has-text("مهندس→مشرف")');
 if(row){await row.click();await s.p.waitForTimeout(4000);const dt=await txt(s.p,'.fm122-dlg');check('أوامر العمل','تفاصيل الأمر: البنود والمواد',/فحص الإنارة/.test(dt)&&/لمبة LED/.test(dt));
  check('أوامر العمل','صور الأمر تُحمَّل من التخزين',await s.p.$$eval('.fm122-dlg img',x=>x.length>0&&x.every(i=>i.naturalWidth>0)));await s.p.screenshot({path:path.join(OUT,'engineer_detail.png')});
  const [dl]=await Promise.all([s.p.waitForEvent('download',{timeout:20000}).catch(()=>null),s.p.click('.fm122-dlg .row button:text-is("⬇️ Excel")').catch(()=>{})]);
  let sheets='';if(dl){try{const XL=require(require.resolve('xlsx',{paths:[process.cwd(),'/usr/lib/node_modules','/usr/local/lib/node_modules']}));sheets=XL.readFile(await dl.path()).SheetNames.join('، ')}catch(e){sheets='(xlsx غير مثبتة — تحقق من التنزيل فقط)'}}
  check('التصدير','Excel الأمر: ملف واحد بأوراق',!!dl&&(!sheets.includes('،')||/بنود الفحص/.test(sheets)),dl?dl.suggestedFilename()+' '+sheets:'لم يُنزَّل');
  const [pop]=await Promise.all([s.p.waitForEvent('popup',{timeout:20000}).catch(()=>null),s.p.click('.fm122-dlg .row button:has-text("PDF")').catch(()=>{})]);
  if(pop){await pop.waitForTimeout(6000);const srcs=await pop.$$eval('img',x=>x.map(i=>i.src).filter(u=>/^https/.test(u)));const st=await Promise.all(srcs.map(u=>fetch(u).then(r=>r.status).catch(()=>0)));
   /* the report window is about:blank, outside the test's network route: its photo links are checked from Node */
   check('التصدير','تقرير PDF: الصفحة وروابط الصور',(await pop.$$eval('.pg',x=>x.length))>=1&&st.length>0&&st.every(x=>x===200),st.length+' صورة');await pop.close()}else check('التصدير','تقرير PDF',false,'لم تُفتح نافذة');
  await s.p.evaluate(()=>document.querySelectorAll('.fm122-dlg-wrap').forEach(d=>d.remove()))}else check('أوامر العمل','تفاصيل الأمر',false,'الصف غير موجود');
 await s.p.evaluate(()=>window.fmEngOpen&&fmEngOpen());await s.p.waitForTimeout(5000);
 check('التواصل','المهندس يرى «أنا وفريقي» ومشرفه',/أنا وفريقي/.test(await txt(s.p,'#eng-page'))&&/مشرف اختبار/.test(await txt(s.p,'#eng-page')));
 await s.p.click('#eng-page [data-tab=logs]').catch(()=>{});await s.p.waitForTimeout(800);check('التواصل','سجل التواصل يعرض سجلات المشرف',/واتساب/.test(await txt(s.p,'#eg-content')));
 await s.p.screenshot({path:path.join(OUT,'engineer_eng.png')});await s.ctx.close();
 /* viewer — platform */
 s=await session(b,'viewer');check('الدخول','المشاهد يُوجَّه للمنصة',/index\.html/.test(s.p.url()));
 await s.p.evaluate(()=>window.fmEngOpen&&fmEngOpen());await s.p.waitForTimeout(4000);/* since V157 a read-only title opens «متابعة التواصل» (read only; RLS decides what it sees), older builds refuse it */
 const ve=await txt(s.p,'#eng-page'),vw=await s.p.$$('#eng-page [data-log],#eng-page #eg-targets,#eng-page #eg-assign,#eng-page #eg-sync');
 check('التواصل','المشاهد: قراءة فقط بلا تسجيل أو إسناد',/متاح لمدير النظام/.test(ve)||(/متابعة التواصل مع المدارس/.test(ve)&&!vw.length),vw.length?vw.length+' زر كتابة':'');await s.ctx.close();
 /* admin — optional */
 if(!C.admin.password){skip('الدخول','المدير','لا توجد كلمة مرور')}else{s=await session(b,'admin');
  if(!/index\.html/.test(s.p.url()))skip('الدخول','المدير','حساب المدير التجريبي غير موجود أو لم يدخل');
  else{const g=await s.p.evaluate(()=>{const x=document.getElementById('v2-nav-eng')?.closest('.fm123-grp');return x?x.querySelector('.fm123-gh').innerText:''});check('القائمة','زر «التواصل مع المدارس» في مجموعة الكادر',/الكادر/.test(g));
   await s.p.evaluate(()=>window.fmEngOpen&&fmEngOpen());await s.p.waitForTimeout(5000);const ae=await txt(s.p,'#eng-page');check('التواصل','المدير يرى «إدارة التواصل» والإعدادات',/إدارة التواصل مع المدارس/.test(ae)&&/الإعدادات والإسناد/.test(ae))}
  await s.ctx.close()}
 await b.close();
 const bad=BLOCK.filter(x=>!/rpc\/fm_wo_run_due$/.test(x));   /* the platform runs due campaigns on open: blocked on purpose */
 check('الأمان','المنصة لم تحاول كتابة بيانات مشتركة أو بلاغات',!bad.length,bad.join(' | '));check('الجودة','لا أخطاء في الصفحات',!ERR.length,ERR.slice(0,5).join(' | '));
 done('ui_results.json')})().catch(async e=>{console.log('FATAL',e.stack);process.exitCode=2;await b?.close().catch(()=>{});process.exit(2)});
