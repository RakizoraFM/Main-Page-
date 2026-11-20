// V402 — Onaizah trial in the browser (no cloud, no network writes): 140 schools × 4 tickets uploaded as a real Excel file
// through the platform's own upload («⬆️ رفع ملف» → the hidden file input) into region qassim, then:
//  - every ticket's limit is 24 / 48 / 72 h by priority and «breached» matches the closing time,
//  - the monthly report numbers (fmV178T) count exactly the breaches made on purpose,
//  - the near-breach list (fmV223SlaRows, the source of the alert) has due = created + limit,
//  - the tickets register at phone width (390 px) shows each ticket as a card with its SLA.
// usage: node tests/integration/onaizah402_browser.cjs   (Playwright + Chromium; XLSX from cdnjs is loaded by the page)
const {chromium}=require('playwright');const path=require('path');const fs=require('fs');
const ROOT=path.join(__dirname,'..','..');const OUT=path.join(ROOT,'tests','results');fs.mkdirSync(OUT,{recursive:true});
const R=[];const check=(a,n,p,d)=>{R.push({area:a,name:n,pass:!!p,detail:d||''});console.log(p?'PASS':'FAIL',a,'—',n,d?'— '+d:'')};
(async()=>{const b=await chromium.launch();const ctx=await b.newContext({viewport:{width:1300,height:900}});const p=await ctx.newPage();const errs=[];
 p.on('pageerror',e=>errs.push(e.message));p.on('dialog',d=>d.accept());
 await ctx.route(/supabase\.co/,r=>r.abort());
 await p.goto('file://'+path.join(ROOT,'index.html'));await p.waitForTimeout(3000);
 // the file: per school — طارئ closed after 20 / 30 h, عالي after 40 / 60 h, متوسط after 70 / 80 h (odd school ok, even school late),
 // and one open طارئ created 23 h ago (due in 1 h). Created dates in the current month.
 const now=Date.now(),mon=new Date(new Date().getFullYear(),new Date().getMonth(),1,8,0,0).getTime();
 const iso=t=>{const d=new Date(t),z=n=>String(n).padStart(2,'0');return `${d.getFullYear()}-${z(d.getMonth()+1)}-${z(d.getDate())} ${z(d.getHours())}:${z(d.getMinutes())}`};
 const H=['رقم البلاغ','اسم المدرسة','الرقم الوزاري / رقم المبنى','الحالة','الأولوية','تاريخ البلاغ','تاريخ الإغلاق','التصنيف الرئيسي','التصنيف الفرعي','وصف البلاغ','المشرف','المهندس','المقاول','المدينة'];
 const A=[H],E={};const span=Math.max(3600e3,(now-mon-90*3600e3)/140);
 for(let g=1;g<=140;g++){const sup='مشرف عنيزة '+(1+Math.floor((g-1)/35)),c0=mon+(g-1)*span;
  [['طارئ',20,30],['عالي',40,60],['متوسط',70,80]].forEach(([pr,ok,late],k)=>{const h=g%2?ok:late,id=`ONZ-${g}-${k+1}`;E[id]={pr,lim:{'طارئ':24,'عالي':48,'متوسط':72}[pr],br:h>{'طارئ':24,'عالي':48,'متوسط':72}[pr]};
   A.push([id,'مدرسة عنيزة '+g,'ONZ'+(1000+g),'مغلق',pr,iso(c0),iso(c0+h*3600e3),'تكييف','المكيف لا يبرد','المكيف لا يبرد',sup,'م. مهندس عنيزة','مقاول عنيزة','عنيزة'])});
  const id=`ONZ-${g}-4`;E[id]={pr:'طارئ',lim:24,br:false,open:true};A.push([id,'مدرسة عنيزة '+g,'ONZ'+(1000+g),'جديد','طارئ',iso(now-23*3600e3),'','كهرباء','انقطاع كهرباء','انقطاع كهرباء',sup,'م. مهندس عنيزة','مقاول عنيزة','عنيزة'])}
 const bytes=await p.evaluate(async A=>{if(!window.XLSX)await new Promise((ok,no)=>{const s=document.createElement('script');s.src='https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js';s.onload=ok;s.onerror=no;document.head.appendChild(s)});
  const wb=XLSX.utils.book_new();XLSX.utils.book_append_sheet(wb,XLSX.utils.aoa_to_sheet(A),'البلاغات');return Array.from(new Uint8Array(XLSX.write(wb,{type:'array',bookType:'xlsx'})))},A);
 const [fc]=await Promise.all([p.waitForEvent('filechooser',{timeout:15000}),p.evaluate(()=>window.fm45UploadTickets('qassim'))]);
 await fc.setFiles({name:'بلاغات عنيزة.xlsx',mimeType:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',buffer:Buffer.from(bytes)});
 await p.waitForFunction(()=>window.FM41&&FM41.datasets&&FM41.datasets.qassim&&(FM41.datasets.qassim.rows||[]).length>=560,null,{timeout:60000}).catch(()=>{});
 const got=await p.evaluate(()=>({n:(FM41.datasets.qassim.rows||[]).length,active:FM41.active,raw:(state.rawTickets||[]).length,cm:state.columnsMap}));
 check('الاستيراد','رفع ملف عنيزة إلى منطقة القصيم',got.n===560&&got.active==='qassim',got.n+' بلاغ، المنطقة '+got.active+'، المفتاح resolvedDate='+(got.cm&&got.cm.resolvedDate||'—'));
 // 1) limit and breach per ticket
 const S=await p.evaluate(()=>{const m=state.columnsMap;return state.rawTickets.map(r=>{const i=getTicketSLAInfo(r);return {id:String(r[m.ticketId]),lim:+i.limitHours,br:!!i.isBreached,pri:i.priority}})});
 let wrongLim=0,wrongBr=0,ex=[];for(const x of S){const e=E[x.id];if(!e)continue;if(x.lim!==e.lim)wrongLim++;if(!e.open&&x.br!==e.br){wrongBr++;if(ex.length<3)ex.push(x.id)}}
 check('المهل','المهلة لكل بلاغ: طارئ 24، عالي 48، متوسط 72 ساعة',wrongLim===0,wrongLim+' مخالفة من '+S.length);
 check('المهل','حالة التجاوز تطابق وقت الإغلاق (ضمن المهلة / متأخر)',wrongBr===0,wrongBr+' مخالفة '+ex.join(' '));
 // 2) the monthly report numbers
 const T=await p.evaluate(()=>{const n=new Date(),a=new Date(n.getFullYear(),n.getMonth(),1),b=new Date(n.getFullYear(),n.getMonth()+1,1);const t=fmV178T('qassim',a,b);
  return {rec:t.rec,closed:t.closed,br:t.br,openEnd:t.openEnd,priBr:Object.fromEntries(t.priBr||[])}});
 check('التقرير','التقرير الشهري: 560 بلاغاً واردة و420 مغلقة',T.rec===560&&T.closed===420,JSON.stringify({rec:T.rec,closed:T.closed}));
 check('التقرير','التقرير الشهري: 210 تجاوزات (70 لكل أولوية)',T.br===210&&T.priBr['طارئ']===70&&T.priBr['عالي']===70&&T.priBr['متوسط']===70,JSON.stringify(T.priBr));
 // 3) the alert source (near-breach list)
 const W=await p.evaluate(()=>{const m=state.columnsMap,L=fmV223SlaRows();const by=new Map(state.rawTickets.map(r=>[String(r[m.ticketId]),r]));
  return L.map(x=>{const r=by.get(x.t);const c=parseDateTime(r[m.date]).getTime();return {t:x.t,h:(x.due-c)/36e5,sup:x.sup,p:x.p}})});
 const open=W.filter(x=>/-4$/.test(x.t));
 check('التنبيه','قائمة «قبل تجاوز المهلة» فيها البلاغات المفتوحة الـ140 بمهلة 24 ساعة',open.length===140&&open.every(x=>Math.abs(x.h-24)<0.01),open.length+' بلاغ');
 // without the school DB the V75 regional guard drops every supervisor name (by design): the alert would reach nobody
 check('التنبيه','بدون قاعدة المدارس: لا اسم مشرف في القائمة (حارس المنطقة V75) — شرط قبل التشغيل',open.every(x=>!x.sup),'أسماء ظاهرة: '+open.filter(x=>x.sup).length);
 // with the school DB of Onaizah (140 schools, their supervisor / engineer) every ticket carries its supervisor
 await p.evaluate(()=>{const D=[];for(let g=1;g<=140;g++)D.push({school:'مدرسة عنيزة '+g,buildingId:'ONZ'+(1000+g),region:'qassim',office:'مكتب تعليم عنيزة',supervisor:'مشرف عنيزة '+(1+Math.floor((g-1)/35)),engineer:'م. مهندس عنيزة',contractor:'مقاول عنيزة'});
  localStorage.setItem('fm_school_master_db_v1',JSON.stringify(D));try{window.dispatchEvent(new Event('fm-school-db-changed'))}catch(e){}});
 await p.waitForTimeout(1200);
 const ST=await p.evaluate(()=>{const m=state.columnsMap,r=state.rawTickets.find(x=>String(x[m.ticketId])==='ONZ-40-4');return getTicketStaff(r)});
 console.log('   getTicketStaff(ONZ-40-4) =',JSON.stringify(ST));
 // fmV223SlaRows keeps its list for the current minute: wait for the next minute so it is rebuilt with the school DB
 await p.waitForTimeout(61000-(Date.now()%60000)+500);
 const W2=await p.evaluate(()=>{const L=fmV223SlaRows();return L.filter(x=>/-4$/.test(x.t)).map(x=>({t:x.t,sup:x.sup,eng:x.eng}))});
 const okSup=W2.every(x=>x.sup==='مشرف عنيزة '+(1+Math.floor((+x.t.split('-')[1]-1)/35))&&x.eng==='م. مهندس عنيزة');
 check('التنبيه','مع قاعدة مدارس عنيزة: كل بلاغ يحمل مشرفه الصحيح ومهندسه (يصل التنبيه لحسابه)',W2.length===140&&okSup,W2.length+' بلاغ — '+[...new Set(W2.map(x=>x.sup))].join('، '));
 // 4) the register at phone width
 await p.setViewportSize({width:390,height:820});await p.evaluate(()=>window.fmV244Register&&window.fmV244Register());await p.waitForTimeout(2500);
 const M=await p.evaluate(()=>{const t=document.querySelector('#fm244-t');const rows=t?[...t.querySelectorAll('tbody tr')]:[];const card=!!(t&&t.classList.contains('fm243-c'));
  const sla=rows.slice(0,50).map(r=>{const td=[...r.children].find(c=>/المهلة|SLA/.test(c.getAttribute('data-l')||''));return td?td.innerText.trim():''});
  return {rows:rows.length,card,withSla:sla.filter(Boolean).length,sample:sla.slice(0,2),scroll:document.documentElement.scrollWidth}});
 check('الجوال','سجل البلاغات على عرض 390: بطاقات وكل بطاقة تعرض المهلة',M.card&&M.rows>0&&M.withSla===M.rows,`${M.rows} بطاقة، ${M.withSla} بمهلة — ${M.sample.join(' | ')}`);
 check('الجوال','لا تمرير أفقي للصفحة على الجوال',M.scroll<=392,M.scroll+'px');
 await p.screenshot({path:path.join(OUT,'onaizah402_phone.png')});
 const bad=errs.filter(e=>!/values is not iterable|Failed to fetch|ERR_FAILED|NetworkError/.test(e));check('الجودة','لا أخطاء في الصفحة',bad.length===0,bad.slice(0,3).join(' | '));
 fs.writeFileSync(path.join(OUT,'onaizah402_browser.json'),JSON.stringify(R,null,1));
 console.log(R.filter(x=>x.pass).length+' / '+R.length+' passed');await b.close();if(R.some(x=>!x.pass))process.exitCode=1})();
