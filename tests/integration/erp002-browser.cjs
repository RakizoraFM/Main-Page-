const {chromium}=require('playwright');
const fs=require('node:fs');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.FM_BROWSER_PATH||'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try {
 const page=await browser.newPage(); const errors=[]; page.on('pageerror',e=>errors.push(e.message));
 await page.setContent('<nav class="v2-nav"></nav><style>.fm103-page{display:none}.fm103-page.open{display:block}</style>');
 await page.addStyleTag({path:'erp-projects.css'});
 await page.evaluate(()=>{
  window.fixture={fm_erp_projects:[{id:'p1',code:'P1',name:'القصيم',region:'qassim',active:true},{id:'p2',code:'P2',name:'الرياض',region:'riyadh',active:true}],profiles:[{id:'u1',full_name:'مستخدم تجريبي',role:'engineer',active:true}],work_orders:Array.from({length:505},(_,i)=>({id:'w'+i,code:'WO'+i,title:i===0?'<img src=x onerror=alert(1)>':'أمر اختبار',region:'qassim'})),fm_erp_work_order_projects:[],fm_erp_project_members:[]};
  window.calls=[]; window.stale=false; window.missing=false;
  const db={from(t){let query={select(){return query},order(){return query},range(a,b){return Promise.resolve(window.missing?{error:{message:'relation does not exist'}}:{data:window.fixture[t].slice(a,b+1)})}};return query},async rpc(fn,args){window.calls.push({fn,args});if(window.stale){window.stale=false;return {error:{message:'stale project assignment'}}}if(fn==='fm_erp_work_order_project_set')window.fixture.fm_erp_work_order_projects.push({wo_id:args.p_wo,project_id:args.p_project,revision:1});if(fn==='fm_erp_project_member_set')window.fixture.fm_erp_project_members=args.p_enabled?[{project_id:args.p_project,user_id:args.p_user}]:[];if(fn==='fm_erp_project_create')window.fixture.fm_erp_projects.push({id:'p3',code:args.p_code,name:args.p_name,region:args.p_region,active:true});return {data:1}}};
  window.FMCloud={state:{on:true,profile:{role:'admin',active:true}},engClient:async()=>db};window.fmV103ClosePages=()=>document.querySelectorAll('.fm103-page').forEach(p=>p.classList.remove('open'));
 });
 await page.addScriptTag({path:'erp-projects.js'});await page.evaluate(()=>window.fmERPProjects());
 await page.waitForSelector('[data-content]:not([hidden])');
 assert.match(await page.locator('[data-count]').innerText(),/505/);
 assert.equal(await page.locator('[data-orders] tbody tr').count(),50);
 assert.equal(await page.locator('[data-orders] img').count(),0);
 await page.locator('[data-project]').selectOption('p1');
 await page.locator('[data-search]').fill('WO504');assert.equal(await page.locator('[data-orders] tbody tr').count(),1);
 await page.locator('[data-orders] button').click();await page.locator('[data-bind] input').fill('اختبار الربط');await page.locator('[data-bind] button').click();
 await page.waitForFunction(()=>document.querySelector('[data-status]').textContent.includes('تم الحفظ'));
 assert.equal(await page.evaluate(()=>calls.at(-1).args.p_expected_revision),0);
 await page.locator('[data-search]').fill('WO504');assert.equal(await page.locator('[data-orders] tbody tr').count(),0);
 await page.locator('[data-filter]').selectOption('project');assert.equal(await page.locator('[data-orders] tbody tr').count(),1);
 await page.locator('[data-orders] button').click();await page.evaluate(()=>window.stale=true);await page.locator('[data-bind] button').click();
 await page.waitForFunction(()=>document.querySelector('[data-status]').textContent.includes('مستخدم آخر'));
 assert(await page.locator('[data-bind] button').isDisabled());
 await page.locator('[data-member] input').fill('إضافة للاختبار');await page.locator('[data-member] button').click();await page.waitForFunction(()=>document.querySelector('[data-members]').textContent.includes('مستخدم تجريبي'));
 await page.locator('[data-member] select[name=enabled]').selectOption('false');await page.locator('[data-member] button').click();await page.waitForFunction(()=>document.querySelector('[data-members]').textContent==='لا يوجد أعضاء');
 await page.locator('[data-project]').selectOption('p2');await page.locator('[data-filter]').selectOption('all');await page.locator('[data-orders] button').first().click();assert(await page.locator('[data-bind] button').isDisabled());
 await page.locator('[data-create] input[name=code]').fill('P3');await page.locator('[data-create] input[name=name]').fill('مشروع ثالث');await page.locator('[data-create] input[name=region]').fill('qassim');await page.locator('[data-create] button').click();await page.waitForFunction(()=>document.querySelector('[data-project]').options.length===4);
 await page.setViewportSize({width:390,height:844});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 await page.evaluate(()=>window.missing=true);await page.locator('[data-reload]').click();await page.waitForFunction(()=>document.querySelector('[data-status]').textContent.includes('ERP001'));assert(await page.locator('[data-content]').isHidden());
 await page.evaluate(()=>{FMCloud.state.profile.role='engineer'});await page.evaluate(()=>window.fmERPProjects());assert(await page.locator('[data-content]').isHidden());
 assert.deepEqual(errors,[]);console.log('PASS ERP002: pagination, search, safe text, assignment/revision, conflict recovery, membership add/remove, region guard, create, mobile, migration missing, access gate');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
