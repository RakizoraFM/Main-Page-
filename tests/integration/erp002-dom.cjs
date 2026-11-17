// DOM behavior checks; no live backend. Browser layout remains a separate check.
const {JSDOM}=require('jsdom');const fs=require('node:fs');const assert=require('node:assert/strict');
(async()=>{
 const dom=new JSDOM('<nav class="v2-nav"></nav>',{runScripts:'outside-only'}),w=dom.window,d=w.document;
 const browserTest=fs.readFileSync('tests/integration/erp002-browser.cjs','utf8');
 const fixture=browserTest.split('await page.evaluate(()=>{')[1].split('\n });')[0];w.eval(fixture);
 w.eval(fs.readFileSync('erp-projects.js','utf8'));
 const q=s=>d.querySelector(s),change=(s,v)=>{q(s).value=v;q(s).dispatchEvent(new w.Event('change'))},search=v=>{q('[data-search]').value=v;q('[data-search]').dispatchEvent(new w.Event('input'))};
 const wait=async fn=>{for(let i=0;i<100;i++){if(fn())return;await new Promise(r=>setTimeout(r,5))}throw Error('timeout')};
 const submit=async selector=>{q(selector).dispatchEvent(new w.Event('submit',{cancelable:true}));await wait(()=>!q('[data-reload]').disabled)};
 await w.fmERPProjects();assert.match(q('[data-count]').textContent,/505/);assert.equal(d.querySelectorAll('[data-orders] tbody tr').length,50);assert.equal(q('[data-orders] img'),null);
 change('[data-project]','p1');search('WO504');assert.equal(d.querySelectorAll('[data-orders] tbody tr').length,1);q('[data-orders] button').click();q('[data-bind] input').value='اختبار الربط';await submit('[data-bind]');assert.equal(w.calls.at(-1).args.p_expected_revision,0);
 assert.equal(d.querySelectorAll('[data-orders] tbody tr').length,0);change('[data-filter]','project');q('[data-orders] button').click();w.stale=true;await submit('[data-bind]');assert.match(q('[data-status]').textContent,/مستخدم آخر/);assert(q('[data-bind] button').disabled);
 q('[data-member] input').value='إضافة للاختبار';await submit('[data-member]');assert.match(q('[data-members]').textContent,/مستخدم تجريبي/);change('[data-member] select[name=enabled]','false');await submit('[data-member]');assert.equal(q('[data-members]').textContent,'لا يوجد أعضاء');
 change('[data-project]','p2');change('[data-filter]','all');q('[data-orders] button').click();assert(q('[data-bind] button').disabled);
 q('[data-create] input[name=code]').value='P3';q('[data-create] input[name=name]').value='ثالث';q('[data-create] input[name=region]').value='qassim';await submit('[data-create]');assert.equal(q('[data-project]').options.length,4);
 w.missing=true;q('[data-reload]').click();await wait(()=>q('[data-status]').textContent.includes('ERP001'));assert(q('[data-content]').hidden);
 w.FMCloud.state.profile.role='engineer';await w.fmERPProjects();assert(q('[data-content]').hidden);assert.match(q('[data-status]').textContent,/مدير النظام/);
 console.log('PASS ERP002 DOM: 505-row paging, search, safe rendering, assignment, revision conflict, membership add/remove, region mismatch, create, missing migration, role gate');dom.window.close();
})().catch(e=>{console.error(e);process.exit(1)});
