// Live permissions / flow test through the Supabase API, as the fm.test.* accounts.
// Writes only rows on the test school (TEST-RKZ-001) with titles starting «[اختبار]»; reset.sql removes them.
// Run: NODE_USE_ENV_PROXY=1 FM_TEST_PASS=… node tests/live/api_test.js
const crypto=require('crypto');const {C,ROLES,SCHOOL,CODE,req,msg,login,reporter}=require('./common');
const {check,skip,done}=reporter();const T={},ID={};
const PNG=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64');
const rpc=(k,fn,a)=>req(T[k],'POST','/rest/v1/rpc/'+fn,a||{});
const get=(k,q)=>req(T[k],'GET','/rest/v1/'+q);
const sign=(k,bucket,p)=>req(k?T[k]:null,'POST',`/storage/v1/object/sign/${bucket}/${p}`,{expiresIn:60});
async function upPhoto(k,wo,kind,extra){const pid=crypto.randomUUID(),p=`${wo}/${pid}.jpg`;
 const u=await req(T[k],'POST','/storage/v1/object/wo-photos/'+p,PNG,{'Content-Type':'image/jpeg'});if(!u.ok)return u;
 return req(T[k],'POST','/rest/v1/wo_photos',Object.assign({id:pid,wo_id:wo,kind,path:p,by_name:C[k].name},extra||{}),{Prefer:'return=minimal'})}
(async()=>{
 for(const k of ROLES){try{const x=await login(k);T[k]=x.token;ID[k]=x.id;check('الدخول','تسجيل دخول '+k,true)}
  catch(e){k==='admin'?skip('الدخول','تسجيل دخول admin','حساب المدير التجريبي غير موجود — فحوص المدير تُتخطّى'):check('الدخول','تسجيل دخول '+k,false,e.message)}}
 if(['engineer','supervisor','contractor','viewer'].some(k=>!T[k]))return done('api_results.json');
 const hasAdmin=!!T.admin;
 /* profiles & hierarchy */
 for(const k of ['engineer','supervisor','contractor','viewer']){const r=await get(k,'profiles?select=id');check('الملفات الشخصية',k+' يرى ملفه فقط',r.ok&&r.j.length===1&&r.j[0].id===ID[k],r.ok?r.j.length+' ملف':msg(r))}
 if(hasAdmin){const r=await get('admin','profiles?select=id');check('الملفات الشخصية','المدير يرى كل المستخدمين',r.ok&&r.j.length>=5,r.j.length+' مستخدم')}
 const as={};for(const k of ['engineer','supervisor','contractor','viewer']){const r=await rpc(k,'fm_wo_assignable');as[k]=r.ok?r.j:[]}
 check('التسلسل','المهندس يُسند فقط للمشرف والمقاول تحته',as.engineer.some(x=>x.id===ID.supervisor)&&as.engineer.some(x=>x.id===ID.contractor)&&as.engineer.every(x=>[ID.supervisor,ID.contractor].includes(x.id)),as.engineer.map(x=>x.full_name).join('، '));
 check('التسلسل','المشرف يُسند فقط للمقاول',as.supervisor.length===1&&as.supervisor[0].id===ID.contractor,as.supervisor.map(x=>x.full_name).join('، '));
 check('التسلسل','المقاول والمشاهد لا يُسندان لأحد',!as.contractor.length&&!as.viewer.length);
 /* work order: engineer → supervisor, full documentation rules */
 const base={type:'inspection',school:SCHOOL,building_id:CODE,region:'riyadh',priority:'متوسط',due_at:new Date(Date.now()+864e5).toISOString(),ticket_refs:[]};
 const CL=[{t:'فحص الطفايات',done:false},{t:'فحص الإنارة',done:false}];
 const fixFixed=(price)=>[{t:'فحص الطفايات',res:'fix',note:'منتهية',done:true},{t:'فحص الإنارة',res:'fixed',materials:[{n:'لمبة LED',q:'2',u:'حبة',src:'buy',price}],done:true}];
 let r=await rpc('engineer','fm_wo_create',{p:Object.assign({},base,{title:'[اختبار] معاينة مهندس→مشرف',assignee:ID.supervisor,checklist:CL})});const w1=r.j;
 check('أوامر العمل','المهندس ينشئ أمراً للمشرف',r.ok&&typeof w1==='string',r.ok?'':msg(r));
 r=await rpc('contractor','fm_wo_create',{p:Object.assign({},base,{title:'[اختبار] مقاول→مشرف',assignee:ID.supervisor})});check('أوامر العمل','المقاول لا ينشئ أوامر لأعلى',!r.ok,msg(r));
 r=await rpc('viewer','fm_wo_create',{p:Object.assign({},base,{title:'[اختبار] مشاهد',assignee:ID.contractor})});check('أوامر العمل','المشاهد لا ينشئ أوامر',!r.ok,msg(r));
 if(hasAdmin){r=await rpc('engineer','fm_wo_create',{p:Object.assign({},base,{title:'[اختبار] إسناد للأعلى',assignee:ID.admin})});check('أوامر العمل','المهندس لا يُسند لمن فوقه',!r.ok,msg(r))}
 r=await get('contractor','work_orders?select=id&id=eq.'+w1);check('أوامر العمل','المقاول لا يرى أمر المشرف',r.ok&&r.j.length===0);
 r=await get('viewer','work_orders?select=id&id=eq.'+w1);check('أوامر العمل','المشاهد لا يرى أوامر غيره',r.ok&&r.j.length===0);
 r=await rpc('supervisor','fm_wo_act',{p_id:w1,p_action:'close'});check('أوامر العمل','المنفّذ لا يعتمد أمره بنفسه',!r.ok,msg(r));
 r=await rpc('supervisor','fm_wo_act',{p_id:w1,p_action:'accept'});check('أوامر العمل','المشرف يقبل الأمر',r.j==='accepted',msg(r));
 r=await rpc('supervisor','fm_wo_act',{p_id:w1,p_action:'start'});check('أوامر العمل','بدء التنفيذ',r.j==='in_progress',msg(r));
 const done1=d=>rpc('supervisor','fm_wo_act',{p_id:w1,p_action:'done',p_data:d});
 r=await done1(CL.map(x=>Object.assign({},x,{res:'ok',done:true})));check('توثيق الإنجاز','رفض بدون صورة «بعد»',/after photo/.test(msg(r)),msg(r));
 r=await upPhoto('supervisor',w1,'after');check('الصور','رفع صورة إلى التخزين',r.ok,r.ok?'':msg(r));
 r=await done1(CL.map(x=>Object.assign({},x,{res:'ok',done:true})));check('توثيق الإنجاز','رفض بدون صور الوصول الثلاث',/arrival/.test(msg(r)),msg(r));
 for(const tag of ['sign','entrance','fence'])await upPhoto('supervisor',w1,'arrival',{tag});
 r=await done1(fixFixed(''));check('توثيق الإنجاز','رفض «يحتاج إصلاح» بدون صورة قبل',/required: 1/.test(msg(r)),msg(r));
 await upPhoto('supervisor',w1,'before',{item:0});
 r=await done1(fixFixed(''));check('توثيق الإنجاز','رفض «تم الإصلاح» بدون صور قبل/بعد',/documentation required: 2/.test(msg(r)),msg(r));
 await upPhoto('supervisor',w1,'before',{item:1});await upPhoto('supervisor',w1,'after',{item:1});
 r=await done1(fixFixed(''));check('توثيق الإنجاز','رفض مادة «شراء» بدون سعر وفاتورة',/invoice required: 2/.test(msg(r)),msg(r));
 await upPhoto('supervisor',w1,'invoice',{item:1});
 r=await done1(fixFixed('15'));check('توثيق الإنجاز','قبول الإبلاغ بعد اكتمال التوثيق',r.j==='done',msg(r));
 r=await rpc('engineer','fm_wo_act',{p_id:w1,p_action:'return'});check('الاعتماد','الإعادة تتطلب سبباً',!r.ok,msg(r));
 r=await rpc('engineer','fm_wo_act',{p_id:w1,p_action:'return',p_note:'أضف صورة أوضح'});check('الاعتماد','المهندس يعيد الأمر للتصحيح',r.j==='returned',msg(r));
 await done1(fixFixed('15'));r=await rpc('engineer','fm_wo_act',{p_id:w1,p_action:'close'});check('الاعتماد','المهندس يعتمد ويغلق',r.j==='closed',msg(r));
 /* supervisor → contractor, then a repair order */
 r=await rpc('supervisor','fm_wo_create',{p:Object.assign({},base,{title:'[اختبار] مشرف→مقاول',assignee:ID.contractor,checklist:[{t:'باب الطوارئ',done:false}]})});const w2=r.j;check('أوامر العمل','المشرف ينشئ أمراً للمقاول',r.ok,msg(r));
 r=await get('engineer','work_orders?select=id&id=eq.'+w2);check('أوامر العمل','المهندس يرى أوامر فريقه',r.ok&&r.j.length===1);
 await rpc('contractor','fm_wo_act',{p_id:w2,p_action:'accept'});
 r=await rpc('contractor','fm_wo_act',{p_id:w2,p_action:'reassign',p_data:{assignee:ID.supervisor}});check('أوامر العمل','المقاول لا يعيد الإسناد',!r.ok,msg(r));
 await upPhoto('contractor',w2,'before',{item:0});for(const tag of ['sign','entrance','fence'])await upPhoto('contractor',w2,'arrival',{tag});await upPhoto('contractor',w2,'after');
 r=await rpc('contractor','fm_wo_act',{p_id:w2,p_action:'done',p_data:[{t:'باب الطوارئ',res:'fix',note:'المفصلة مكسورة',done:true}]});check('أوامر العمل','المقاول يُبلغ بالإنجاز',r.j==='done',msg(r));
 r=await rpc('supervisor','fm_wo_repair',{p_src:w2,p:{assignee:ID.contractor,due_at:new Date(Date.now()+3*864e5).toISOString()}});check('أمر الإصلاح','إنشاء أمر إصلاح من بنود «يحتاج إصلاح»',r.ok&&r.j&&r.j.count===1,r.ok?r.j.code:msg(r));
 if(r.ok){const x=await get('contractor',`work_orders?select=id,type,source_wo&code=eq.${r.j.code}`);check('أمر الإصلاح','المقاول يرى أمر الإصلاح ومصدره',x.ok&&x.j[0]&&x.j[0].type==='repair'&&x.j[0].source_wo===w2);
  const ph=x.j[0]?await get('contractor',`wo_photos?select=kind&wo_id=eq.${x.j[0].id}`):{ok:false,j:[]};check('أمر الإصلاح','صورة «قبل» نُسخت لأمر الإصلاح',ph.ok&&ph.j.some(p=>p.kind==='before'))}
 r=await rpc('supervisor','fm_wo_act',{p_id:w2,p_action:'close'});check('الاعتماد','المشرف يغلق أمر المقاول',r.j==='closed',msg(r));
 /* storage privacy */
 const ph=(await get('supervisor',`wo_photos?select=path&wo_id=eq.${w1}&limit=1`)).j[0];
 if(ph){check('الخصوصية','المقاول لا يفتح صور أمر لا يراه',!(await sign('contractor','wo-photos',ph.path)).ok);check('الخصوصية','المهندس يفتح صور أوامر فريقه',(await sign('engineer','wo-photos',ph.path)).ok)}
 r=await req(null,'GET','/rest/v1/work_orders?select=id&limit=1');check('الخصوصية','الزائر غير المسجّل لا يرى الأوامر',!r.ok||r.j.length===0);
 /* school engagement */
 r=await rpc('engineer','fm_eng_lead',{p_user:ID.supervisor});check('التواصل','قاعدة البيانات محدّثة (fm_eng_lead)',r.ok,r.ok?'':msg(r));
 if(hasAdmin){r=await req(T.admin,'POST','/rest/v1/fm_eng_assignments?on_conflict=school_code,user_id',[ID.supervisor,ID.engineer].map(u=>({school_code:CODE,school_name:SCHOOL,region:'riyadh',user_id:u,principal:'مدير اختبار',phone:'0500000000'})),{Prefer:'resolution=merge-duplicates,return=minimal'});check('التواصل','المدير يُسند مدرسة الاختبار',r.ok,r.ok?'':msg(r))}
 const As=(await get('supervisor',`fm_eng_assignments?select=id,user_id&school_code=eq.${CODE}`)).j||[],Ae=(await get('engineer',`fm_eng_assignments?select=id,user_id&school_code=eq.${CODE}&user_id=eq.${ID.engineer}`)).j||[];
 const A={s:(As.find(a=>a.user_id===ID.supervisor)||{}).id,e:(Ae[0]||{}).id};
 if(!A.s){skip('التواصل','بقية فحوص التواصل','مدرسة الاختبار غير مسندة للمشرف التجريبي — يُسندها المدير مرة واحدة');return done('api_results.json')}
 check('التواصل','المشرف يرى إسناده فقط',As.length===1);
 r=await req(T.supervisor,'POST','/rest/v1/fm_eng_assignments',{school_code:'TEST-RKZ-002',school_name:SCHOOL,user_id:ID.supervisor,principal:'',phone:''});check('التواصل','المشرف لا يُسند لنفسه',!r.ok,msg(r));
 r=await rpc('supervisor','fm_eng_submit',{p:{assignment_id:A.s,channel:'phone',outcome:'observation',confirmed:true,summary:'[اختبار] تسريب في دورات المياه'}});const lid=r.j;check('التواصل','المشرف يسجّل تواصلاً بملاحظة',r.ok,r.ok?'':msg(r));
 r=await req(T.supervisor,'POST','/rest/v1/fm_eng_logs',{assignment_id:A.s,channel:'phone',outcome:'clear',confirmed:true,summary:'[اختبار] بأثر رجعي',at:'2026-01-05T08:00:00Z'});check('التواصل','منع الإضافة المباشرة بتاريخ قديم',!r.ok,r.s+'');
 r=await rpc('supervisor','fm_eng_submit',{p:{assignment_id:A.s,channel:'whatsapp',outcome:'clear',confirmed:true,summary:'[اختبار] واتساب'}});check('التواصل','رفض واتساب مؤكد بدون إثبات',!r.ok,msg(r));
 const ep=ID.supervisor+'/'+crypto.randomUUID();r=await req(T.supervisor,'POST','/storage/v1/object/school-engagement/'+ep,PNG,{'Content-Type':'image/png'});check('التواصل','رفع إثبات',r.ok,r.ok?'':msg(r));
 r=await rpc('supervisor','fm_eng_submit',{p:{assignment_id:A.s,channel:'whatsapp',outcome:'clear',confirmed:true,summary:'[اختبار] واتساب مؤكد',evidence_path:ep}});check('التواصل','قبول واتساب مؤكد مع إثبات',r.ok,r.ok?'':msg(r));
 if(A.e){r=await rpc('supervisor','fm_eng_submit',{p:{assignment_id:A.e,channel:'phone',outcome:'clear',confirmed:true,summary:'x'}});check('التواصل','المشرف لا يسجّل على إسناد غيره',!r.ok,msg(r))}
 r=await rpc('contractor','fm_eng_submit',{p:{assignment_id:A.s,channel:'phone',outcome:'clear',confirmed:true,summary:'x'}});check('التواصل','المقاول لا يسجّل تواصلاً',!r.ok,msg(r));
 r=await req(null,'POST','/rest/v1/rpc/fm_eng_submit',{p:{assignment_id:A.s,channel:'phone',outcome:'clear',confirmed:true,summary:'x'}});check('التواصل','الزائر غير المسجّل لا يسجّل',!r.ok,msg(r));
 const ob=(await get('supervisor',`fm_eng_observations?select=id,due_at&log_id=eq.${lid}`)).j||[],oid=ob[0]&&ob[0].id;
 check('التواصل','فُتحت ملاحظة بمهلة 48 ساعة',ob[0]&&Math.round((Date.parse(ob[0].due_at)-Date.now())/36e5)===48);
 if(oid){r=await req(T.supervisor,'PATCH','/rest/v1/fm_eng_observations?id=eq.'+oid,{due_at:new Date(Date.now()+30*864e5).toISOString()});check('التواصل','المشرف لا يؤجل موعد الملاحظة',!r.ok,r.s+'');
  r=await req(T.supervisor,'PATCH','/rest/v1/fm_eng_observations?id=eq.'+oid,{status:'closed'});check('التواصل','الإغلاق يتطلب إجراء',!r.ok,msg(r));
  r=await req(T.engineer,'PATCH','/rest/v1/fm_eng_observations?id=eq.'+oid,{status:'closed',action:'[اختبار] تم الإصلاح'},{Prefer:'return=representation'});check('التواصل','المهندس يغلق ملاحظة فريقه بإجراء',r.ok&&r.j.length===1,r.ok?'':msg(r));
  r=await get('supervisor','fm_eng_audit?select=actor&observation_id=eq.'+oid);check('التواصل','سجل التعديلات باسم المهندس',r.ok&&r.j.some(a=>a.actor===ID.engineer))}
 r=await get('engineer',`fm_eng_logs?select=id&id=eq.${lid}`);check('التواصل','المهندس يرى سجلات مشرفه',r.ok&&r.j.length===1);
 const ev=[['supervisor',true],['engineer',true],['contractor',false],['viewer',false],[null,false]].concat(hasAdmin?[['admin',true]]:[]);
 for(const [k,should] of ev){r=await sign(k,'school-engagement',ep);check('التواصل',`إثبات التواصل: ${k||'زائر'} ${should?'يفتحه':'ممنوع'}`,should?r.ok:!r.ok,r.s+'')}
 for(const k of ['viewer','contractor']){r=await get(k,'fm_eng_logs?select=id');check('التواصل',k+' لا يرى السجلات',r.ok?r.j.length===0:true)}
 r=await req(T.supervisor,'PATCH','/rest/v1/fm_eng_targets?role=eq.supervisor',{visits:0},{Prefer:'return=representation'});check('التواصل','المشرف لا يغيّر المستهدفات',!r.ok||r.j.length===0);
 done('api_results.json')})().catch(e=>{console.log('FATAL',e.stack);process.exitCode=2});
