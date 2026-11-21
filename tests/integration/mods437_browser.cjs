// V437 — the eight new subscription parts in the browser (no cloud, no network writes).
//  - every part cached on → finance / workforce / energy pages visible,
//  - a company without erp and hr → their sidebar pages hidden (the field app's attendance / leave cards too), others stay,
//  - an old company (parts list without «_v») → fixOn keeps the new parts open; a SA11 list without them closes them,
//  - the saas.html helpers: upMods / planMods / readPicker marker.
// usage: NODE_PATH=$(npm root -g) node tests/integration/mods437_browser.cjs
const {chromium}=require('playwright');const path=require('path');
const ROOT=path.join(__dirname,'..','..');const R=[];
const check=(n,p,d)=>{R.push({n,p:!!p});console.log(p?'PASS':'FAIL','—',n,d?'— '+d:'')};
const OLD=['tickets','wo','wh','eng','portal','costs','bill','cc'],NEW=['erp','hr','assets','energy','ai','reports','cpen','integ'];
const ERP=['fm353-cost','fm355-rev','fm360-budget','fm361-cash','fm354-ap','fm359-acct','fm370-pay','fm362-ret'],HR=['workforce','fm224-att','fm375-leave','fm264-ot','fm372-score'];
async function plat(b,on){const ctx=await b.newContext({viewport:{width:1300,height:900}});await ctx.route(/supabase\.co/,r=>r.abort());
 await ctx.addInitScript(on=>{try{localStorage.setItem('fm437_mods',JSON.stringify(on))}catch(e){}},on);const p=await ctx.newPage();const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('dialog',d=>d.accept());
 await p.goto('file://'+path.join(ROOT,'index.html'));await p.waitForTimeout(6000);
 const IDS=[...ERP,...HR,'fm224-meters','fm145-wo','fm173-stock','fm184-bills'];
 await p.evaluate(ids=>{const nv=document.querySelector('nav.v2-nav')||document.body;for(const id of ids)if(!document.getElementById('v2-nav-'+id)){const e=document.createElement('button');e.id='v2-nav-'+id;e.className='v2-nav-btn';nv.appendChild(e)}},IDS);await p.waitForTimeout(3500);
 const vis=await p.evaluate(ids=>Object.fromEntries(ids.map(id=>{const e=document.getElementById('v2-nav-'+id);return [id,e?getComputedStyle(e).display!=='none':null]})),[...ERP,...HR,'fm224-meters','fm145-wo','fm173-stock','fm184-bills']);
 const mods=await p.evaluate(()=>({keys:Object.keys(window.FM_MODS||{}),wo:(window.FM_MODS.wo||{}).ids,fix:window.fmV181FixOn}));
 return {p,ctx,vis,mods,errs}}
(async()=>{const b=await chromium.launch();
 let x=await plat(b,[...OLD,...NEW]);
 check('FM_MODS يضم الأجزاء الثمانية',NEW.every(k=>x.mods.keys.includes(k)),x.mods.keys.join(','));
 check('صفحات المالية خرجت من «أوامر العمل»',!x.mods.wo.includes('v2-nav-fm353-cost')&&!x.mods.wo.includes('v2-nav-fm360-budget'));
 check('شركة بكل الأجزاء: صفحات المالية والقوى العاملة ظاهرة',[...ERP,...HR].every(id=>x.vis[id]===true),JSON.stringify(x.vis));
 const fx=await x.p.evaluate(({OLD,NEW})=>{const f=window.fmV181FixOn;return {
   legacy:f(['tickets','wo'],{tickets:null,wo:null}),
   sa11:f(['tickets','wo'],{tickets:null,wo:null,_v:437}),
   oldsrv:f(['tickets'],{tickets:null,erp:null,ai:'2000-01-01',_v:437})}},{OLD,NEW});
 check('شركة قديمة بلا «_v»: الأجزاء الجديدة مفتوحة',NEW.every(k=>fx.legacy.includes(k)),fx.legacy.join(','));
 check('قائمة SA11 بدون الأجزاء الجديدة: مغلقة',!NEW.some(k=>fx.sa11.includes(k)),fx.sa11.join(','));
 check('خادم قبل القسم 151: جزء مذكور في القائمة يظهر، وتجربة منتهية لا',fx.oldsrv.includes('erp')&&!fx.oldsrv.includes('ai'),fx.oldsrv.join(','));
 // the subscription card lists the new parts
 const card=await x.p.evaluate(()=>{const M=window.FM_MODS;return Object.values(M).map(m=>m.n).join(' | ')});
 check('بطاقة الأجزاء تعرض الأسماء الجديدة',/المالية والمحاسبة/.test(card)&&/القوى العاملة/.test(card)&&/غرامات العميل/.test(card));
 check('بلا أخطاء صفحة (كل الأجزاء)',!x.errs.length,x.errs.slice(0,2).join(' | '));await x.ctx.close();
 x=await plat(b,[...OLD,...NEW.filter(k=>k!=='erp'&&k!=='hr')]);
 check('بدون erp: صفحات المالية مخفية',ERP.every(id=>x.vis[id]===false),JSON.stringify(ERP.map(id=>x.vis[id])));
 check('بدون hr: صفحات القوى العاملة مخفية',HR.every(id=>x.vis[id]===false),JSON.stringify(HR.map(id=>x.vis[id])));
 check('بدون erp وhr: الطاقة وأوامر العمل ظاهرة',['fm224-meters','fm145-wo'].every(id=>x.vis[id]===true),JSON.stringify(x.vis));
 check('بلا أخطاء صفحة (بدون erp وhr)',!x.errs.length,x.errs.slice(0,2).join(' | '));await x.ctx.close();
 // field app: hr off hides the attendance / leave / overtime cards (CSS classes)
 {const ctx=await b.newContext({viewport:{width:390,height:820}});await ctx.route(/supabase\.co/,r=>r.abort());
  await ctx.addInitScript(on=>{try{localStorage.setItem('fmf_mods437',JSON.stringify(on))}catch(e){}},[...OLD,'energy']);
  const p=await ctx.newPage();await p.goto('file://'+path.join(ROOT,'field.html'));await p.waitForTimeout(4000);
  const r=await p.evaluate(()=>{const mk=id=>{const e=document.createElement('button');e.id=id;document.body.appendChild(e);return getComputedStyle(e).display};
   const t=document.createElement('div');t.dataset.for='f74-h';document.body.appendChild(t);
   return {hr:document.body.classList.contains('fmm-no-hr'),en:document.body.classList.contains('fmm-no-energy'),att:mk('f49-att'),lv:mk('f134-lv'),mt:mk('f49-mt'),tile:getComputedStyle(t).display,
    legacy:window.fmfFixOn(['tickets'],{tickets:null}).includes('hr')}});
  check('الميدان بدون hr: بطاقات الدوام والإجازة والعمل الإضافي مخفية',r.hr&&r.att==='none'&&r.lv==='none'&&r.tile==='none',JSON.stringify(r));
  check('الميدان: الطاقة مفعّلة فبطاقة العدادات ظاهرة',!r.en&&r.mt!=='none');
  check('الميدان: شركة قديمة تبقى القوى العاملة مفتوحة',r.legacy);await ctx.close()}
 // saas.html helpers
 {const ctx=await b.newContext();await ctx.route(/supabase\.co/,r=>r.abort());const p=await ctx.newPage();const errs=[];p.on('pageerror',e=>errs.push(e.message));
  await p.goto('file://'+path.join(ROOT,'saas.html'));await p.waitForTimeout(1500);
  const r=await p.evaluate(()=>{const {MODS,upMods,planMods,readPicker,modPicker,modsTxt,tMods,setSET}=window.fmSaasMods;setSET({plans:[{k:'full',modules:['tickets','wo','wh','eng','portal','costs','bill','cc']},{k:'basic',modules:['tickets']},{k:'nw',modules:['tickets','erp'],mv:437}]});
   const up=tMods({modules:{tickets:null,wo:'2030-01-01'}});const d=document.createElement('div');d.innerHTML=modPicker('basic',up,0,1);const rp=readPicker(d,'basic');
   return {up,full:planMods('full'),basic:planMods('basic'),nw:planMods('nw'),rp,cnt:MODS.length,txt:modsTxt(up)}});
  check('saas: 17 جزءاً في القائمة',r.cnt===17,String(r.cnt));
  check('saas: شركة قديمة تظهر بالأجزاء الجديدة مفعّلة وعلامة _v',r.up._v===437&&['erp','hr','integ'].every(k=>k in r.up)&&r.up.wo==='2030-01-01');
  check('saas: الكود يحمل _v والأجزاء المعلّمة',r.rp._v===437&&'erp' in r.rp&&'tickets' in r.rp&&!('wh' in r.rp),JSON.stringify(r.rp));
  check('saas: الباقة الشاملة القديمة تضم الأجزاء الجديدة، والأساسية لا',r.full.includes('erp')&&r.full.includes('hr')&&!r.basic.includes('erp'));
  check('saas: باقة محفوظة بعد SA11 كما هي',JSON.stringify(r.nw)==='["tickets","erp"]');
  check('saas: نص الأجزاء لا يعرض _v',!/_v/.test(r.txt));
  check('saas: بلا أخطاء صفحة',!errs.length,errs.join(' | '));await ctx.close()}
 await b.close();const ok=R.filter(r=>r.p).length;console.log(`\n${ok} / ${R.length} passed`);process.exit(ok===R.length?0:1)})();
