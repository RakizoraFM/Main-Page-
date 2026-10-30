// Live test of V179–V187 on the real Supabase project: parts / subscription, warehouse and custody, contractor bills,
// cost centers, usage. Uses the fm.test.* accounts plus fm.test.storekeeper (created by the test admin when missing,
// limited to the region «test» so it can act only on the test store). Every row it makes is named «[اختبار]…» or has
// the code TEST-CC; reset.sql removes them. Nothing here approves or pays a bill, so the cost-center numbers are untouched.
// Run: NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node tests/live/v180_test.js
const L=process.env.FM_LOCAL_ADAPTER?require(process.env.FM_LOCAL_ADAPTER):require('./common');
const {C,req,msg,login,reporter}=L;
const {check,skip,done}=reporter();const T={},ID={};
const rpc=(k,fn,a)=>req(T[k],'POST','/rest/v1/rpc/'+fn,a||{});
const get=(k,q)=>req(T[k],'GET','/rest/v1/'+q);
const SK=C.storekeeper;
const month=new Date().toISOString().slice(0,7),year=+month.slice(0,4);
const no=(r,re)=>!r.ok&&(!re||re.test(msg(r)));
(async()=>{
 for(const k of ['admin','engineer','supervisor','contractor','viewer']){try{const x=await login(k);T[k]=x.token;ID[k]=x.id}catch(e){check('الدخول','تسجيل دخول '+k,false,e.message)}}
 if(!T.admin){skip('الدخول','كل الفحوص','حساب المدير التجريبي مطلوب لهذا الفحص');return done('v180_results.json')}
 /* what is installed */
 const need=[['V179','fm_plan_info'],['V180','fm_wh_people'],['V181','fm_mods_on'],['V184','fm_bill_contractors'],['V185','fm_plan_usage']];
 const miss=[];for(const [v,f] of need){const r=await rpc('admin',f);if(r.s===404)miss.push(v+' ('+f+')')}
 {const r=await rpc('admin','fm_cc_data',{p_year:year});if(r.s===404)miss.push('V186 (fm_cc_data)')}
 if(miss.length){skip('التثبيت','كل الفحوص','لم يُشغَّل supabase_setup.sql الجديد بعد — ناقص: '+miss.join('، '));return done('v180_results.json')}
 check('التثبيت','أقسام V179–V186 موجودة على السيرفر',true);

 /* V179 / V181: subscription and parts */
 let r=await rpc('admin','fm_plan_info');const plan=r.j||{};
 check('الاشتراك','fm_plan_info يعمل',r.ok&&plan.state,plan.state);
 r=await rpc('admin','fm_mods_on');const mods=r.ok?r.j:[];
 if(plan.state==='none')check('الأجزاء','بدون اشتراك كل الأجزاء مفعّلة',['tickets','wo','wh','eng','portal','costs','bill','cc'].every(k=>mods.includes(k)),mods.join('، '));
 else check('الأجزاء','قائمة الأجزاء المفعّلة',r.ok,mods.join('، '));
 r=await req(null,'POST','/rest/v1/rpc/fm_plan_activate',{p_code:'x.y'});check('الاشتراك','الزائر لا يفعّل كوداً',!r.ok,msg(r));
 r=await rpc('engineer','fm_plan_activate',{p_code:'x.y'});check('الاشتراك','غير المدير لا يفعّل كوداً',!r.ok,msg(r));
 r=await rpc('admin','fm_plan_usage');check('الاستخدام','fm_plan_usage: لا يُرسل شيء بدون اشتراك، وموقَّع معه',r.ok&&(plan.state==='none'?r.j===null:!!(r.j&&r.j.p&&r.j.s)),plan.state==='none'?'لا اشتراك':'');
 if(r.ok&&r.j&&r.j.p){const p=JSON.parse(r.j.p);check('الاستخدام','الإرسال أرقام فقط بدون أسماء',!/@|full_name|school/.test(r.j.p)&&typeof p.users==='number')}
 r=await req(null,'POST','/rest/v1/rpc/fm_plan_usage',{});check('الاستخدام','الزائر لا يقرأ أرقام الاستخدام',!r.ok||r.j===null,r.s+'');

 /* V187: push notifications (a fake device on push.invalid, removed at the end of this block) */
 r=await rpc('admin','fm_push_me');
 if(r.s===404)skip('الإشعارات','فحوص الإشعارات','القسم 29 (V187) غير مشغّل بعد');
 else{const ep='https://push.invalid/fm-test-'+ID.supervisor;
  r=await rpc('supervisor','fm_push_subscribe',{p:{endpoint:'http://x',p256dh:'a',auth:'b'}});check('الإشعارات','رفض اشتراك غير صالح',no(r,/invalid subscription/),msg(r));
  r=await rpc('supervisor','fm_push_subscribe',{p:{endpoint:ep,p256dh:'B'+'x'.repeat(86),auth:'a'.repeat(22),app:'test'}});check('الإشعارات','المشرف يفعّل جهازاً',r.j===true,msg(r));
  r=await rpc('supervisor','fm_push_me');check('الإشعارات','fm_push_me يعدّ أجهزته',r.ok&&r.j.devices>=1&&r.j.endpoints.includes(ep),r.ok?String(r.j.devices):msg(r));
  r=await rpc('supervisor','fm_push_prefs_set',{p_off:['wo_closed']});check('الإشعارات','حفظ اختياراته',r.j===true,msg(r));
  r=await rpc('supervisor','fm_push_status');check('الإشعارات','المشرف لا يرى حالة الإرسال',no(r,/not allowed/),msg(r));
  r=await rpc('supervisor','fm_push_config',{p:{fn_url:'https://evil.example'}});check('الإشعارات','المشرف لا يغيّر الربط',no(r,/not allowed/),msg(r));
  r=await rpc('supervisor','fm_push_claim',{n:1});check('الإشعارات','المستخدم لا يسحب طابور الإرسال',!r.ok,r.s+'');
  r=await get('supervisor','fm_push_subs?select=endpoint');check('الإشعارات','جدول الأجهزة مغلق أمام القراءة المباشرة',!r.ok||r.j.length===0,r.s+'');
  r=await req(null,'POST','/rest/v1/rpc/fm_push_subscribe',{p:{endpoint:ep}});check('الإشعارات','الزائر لا يفعّل جهازاً',!r.ok,r.s+'');
  r=await rpc('admin','fm_push_status');check('الإشعارات','مدير النظام يرى حالة الإرسال',r.ok&&typeof r.j.devices==='number',r.ok?`${r.j.devices} جهاز • pg_net ${r.j.pg_net} • الدالة ${r.j.fn_url?'مربوطة':'غير مربوطة'}`:msg(r));
  await rpc('supervisor','fm_push_prefs_set',{p_off:[]});
  r=await rpc('supervisor','fm_push_unsubscribe',{p_endpoint:ep});check('الإشعارات','إيقاف الجهاز التجريبي',r.j===true,msg(r))}

 /* V180: the test storekeeper */
 try{const x=await login('storekeeper').catch(async()=>{
   const c=await rpc('admin','fm_admin_create_user',{p_email:SK.email,p_password:SK.password,p_full_name:SK.name,p_role:'staff',p_regions:['test'],p_names:[],p_active:true});
   if(!c.ok)throw Error(msg(c));return login('storekeeper')});T.sk=x.token;ID.sk=x.id}
 catch(e){check('المستودع','حساب أمين المستودع التجريبي',false,e.message)}
 if(T.sk){r=await req(T.admin,'PATCH','/rest/v1/profiles?id=eq.'+ID.sk,{job_title:'storekeeper',regions:['test'],active:true,must_change_pw:false},{Prefer:'return=minimal'});
  check('المستودع','أمين المستودع التجريبي (منطقة test فقط)',r.ok,r.ok?'':msg(r))}
 /* item with approval */
 r=await rpc('engineer','fm_mat_save',{p:{name:'[اختبار] قاطع 20A',unit:'عدد',price:10,category:'كهرباء'}});
 let mat=r.ok?r.j:null;
 if(!mat&&/duplicate name/.test(msg(r))){const x=await get('admin','wo_materials?select=id&name=eq.'+encodeURIComponent('[اختبار] قاطع 20A'));mat=x.j[0]&&x.j[0].id}
 check('الأصناف','المهندس يضيف صنفاً (بانتظار الاعتماد)',!!mat,r.ok?'':msg(r));
 r=await rpc('contractor','fm_mat_save',{p:{name:'[اختبار] مقاول',price:1}});check('الأصناف','المقاول لا يضيف أصنافاً',no(r,/not allowed/),msg(r));
 r=await req(T.engineer,'POST','/rest/v1/wo_materials',{name:'[اختبار] مباشر'});check('الأصناف','الإضافة المباشرة للجدول ممنوعة',!r.ok,r.s+'');
 r=await rpc('engineer','fm_mat_approve',{p_kind:'item',p_ids:[mat],p_action:'nominate',p_note:null});check('الأصناف','المهندس لا يعتمد',no(r),msg(r));
 await rpc('admin','fm_mat_approve',{p_kind:'item',p_ids:[mat],p_action:'nominate',p_note:null});
 let m=(await get('admin','wo_materials?select=approval,approved_at,code&id=eq.'+mat)).j[0]||{};
 const hasOwner=m.approval==='nominated';
 check('الأصناف','مدير النظام يرشّح الصنف (يُعتمد نهائياً إن لم يوجد ممثل للمالك)',m.approved_at||hasOwner,m.approval+' '+(m.code||''));
 const usable=!!m.approved_at;
 if(!usable)skip('العهد','الصرف والعهدة','يوجد ممثل للجهة المالكة: الصنف التجريبي ينتظر اعتماده فلا يُصرف');
 /* test store */
 let st=(await get('admin','wo_stores?select=id&name=eq.'+encodeURIComponent('[اختبار] مستودع'))).j[0];st=st&&st.id;
 if(!st){r=await rpc('admin','fm_stock_store_save',{p:{name:'[اختبار] مستودع',region:'riyadh',is_default:false}});st=r.ok?r.j:null;check('المستودع','إنشاء مستودع اختبار',!!st,r.ok?'':msg(r))}
 r=await rpc('supervisor','fm_stock_store_save',{p:{name:'[اختبار] مشرف',region:'riyadh'}});check('المستودع','المشرف لا ينشئ مستودعاً',no(r,/not allowed/),msg(r));
 if(T.sk&&st){r=await rpc('admin','fm_stock_store_keeper',{p_store:st,p_keeper:ID.sk});check('المستودع','تعيين أمين المستودع',r.ok,r.ok?'':msg(r))}
 if(st&&mat){
  r=await rpc('admin','fm_stock_move',{p:{kind:'in',store_id:st,supplier:'[اختبار] مورد',invoice_no:'T-1',lines:[{material_id:mat,qty:5,price:10}]}});check('المستودع','توريد 5 للمستودع',r.j===1,msg(r));
  var bal0=+(((await get('admin',`wo_stock?select=qty&store_id=eq.${st}&material_id=eq.${mat}`)).j||[])[0]||{qty:0}).qty;
  for(const k of ['viewer','contractor','supervisor']){r=await rpc(k,'fm_stock_move',{p:{kind:'in',store_id:st,lines:[{material_id:mat,qty:1}]}});check('المستودع',k+' لا يورّد',no(r,/not allowed/),msg(r))}
  r=await get('viewer','wo_custody?select=holder&holder=eq.'+ID.supervisor);check('العهد','المشاهد لا يرى عهدة غيره',r.ok&&r.j.length===0||!r.ok)}
 if(st&&mat&&usable&&T.sk){
  r=await rpc('supervisor','fm_issue_req_new',{p:{source:'direct',store_id:st,lines:[{material_id:mat,qty:2}]}});check('العهد','المشرف لا يطلب بدون أمر عمل أو بلاغ',no(r,/source required/),msg(r));
  r=await rpc('supervisor','fm_issue_req_new',{p:{source:'ticket',ticket_ref:'[اختبار] TK-1',store_id:st,lines:[{material_id:mat,qty:2}],note:'[اختبار]'}});const q1=r.ok?r.j.id:null;
  check('العهد','المشرف يطلب قطعاً على بلاغ',!!q1,r.ok?r.j.code:msg(r));
  r=await rpc('engineer','fm_issue_req_new',{p:{source:'direct',holder:ID.supervisor,store_id:st,lines:[{material_id:mat,qty:1}],note:'[اختبار] توجيه'}});const q2=r.ok?r.j.id:null;
  check('العهد','المهندس يطلب لمشرفه مباشرة',!!q2,r.ok?'':msg(r));
  r=await rpc('contractor','fm_issue_req_new',{p:{source:'direct',holder:ID.supervisor,store_id:st,lines:[{material_id:mat,qty:1}]}});check('العهد','المقاول لا يطلب لغيره',no(r),msg(r));
  if(q2){r=await rpc('engineer','fm_issue_req_act',{p_id:q2,p_action:'cancel',p:{}});check('العهد','مقدّم الطلب يلغيه',r.j==='cancelled',msg(r))}
  if(q1){r=await rpc('admin','fm_issue_req_act',{p_id:q1,p_action:'issue',p:{}});check('العهد','الصرف لأمين المستودع فقط',no(r,/storekeeper only/),msg(r));
   r=await rpc('sk','fm_issue_req_act',{p_id:q1,p_action:'issue',p:{}});check('العهد','أمين المستودع يصرف للعهدة',r.j==='issued',msg(r));
   r=await rpc('engineer','fm_issue_req_act',{p_id:q1,p_action:'receive',p:{}});check('العهد','لا يؤكد الاستلام إلا صاحب العهدة',no(r),msg(r));
   /* V230: receipt = signature bound to the issued snapshot (fm_issue_req_sign_once) */
   {const g=await req(T.supervisor,'GET','/rest/v1/wo_issue_requests?select=issued_at,lines&id=eq.'+q1);const row=(g.j||[])[0]||{};
    const PNG='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    r=await rpc('supervisor','fm_issue_req_sign_once',{p:{op_id:'test-'+Date.now(),id:q1,expected_issued_at:row.issued_at,expected_lines:row.lines,sign:PNG,inperson:false}});
    check('العهد','المشرف يؤكد الاستلام بالتوقيع',r.ok,msg(r))}}
  const cus=k=>get(k,`wo_custody?select=qty&holder=eq.${ID.supervisor}&material_id=eq.${mat}`);
  r=await cus('supervisor');check('العهد','العهدة لدى المشرف = 2',r.ok&&r.j[0]&&+r.j[0].qty===2,r.ok?JSON.stringify(r.j):msg(r));
  r=await cus('engineer');check('العهد','المهندس يرى عهدة مشرفه',r.ok&&r.j.length===1);
  r=await cus('contractor');check('العهد','المقاول لا يرى عهدة المشرف',r.ok?r.j.length===0:true);
  r=await get('admin',`wo_stock?select=qty&store_id=eq.${st}&material_id=eq.${mat}`);check('المستودع','رصيد المستودع نقص بالمصروف (2)',r.ok&&r.j[0]&&+r.j[0].qty===bal0-2,`${bal0} → ${r.ok&&r.j[0]&&r.j[0].qty}`);
  r=await rpc('supervisor','fm_issue_req_new',{p:{source:'ticket',ticket_ref:'[اختبار] TK-2',store_id:st,lines:[{material_id:mat,qty:50}]}});const q3=r.ok?r.j.id:null;
  if(q3){r=await rpc('sk','fm_issue_req_act',{p_id:q3,p_action:'issue',p:{}});check('العهد','لا يُصرف أكثر من رصيد المستودع',no(r,/insufficient/),msg(r));
   r=await rpc('sk','fm_issue_req_act',{p_id:q3,p_action:'reject',p:{}});check('العهد','الرفض يتطلب سبباً',no(r,/note required/),msg(r));
   r=await rpc('sk','fm_issue_req_act',{p_id:q3,p_action:'reject',p:{note:'[اختبار] الكمية كبيرة'}});check('العهد','أمين المستودع يرفض الطلب',r.j==='rejected',msg(r))}
  r=await rpc('sk','fm_custody_return',{p:{store_id:st,holder:ID.supervisor,lines:[{material_id:mat,kind:'return',qty:5}]}});check('العهد','لا يُرجَع أكثر من العهدة',no(r,/more than held/),msg(r));
  r=await rpc('sk','fm_custody_return',{p:{store_id:st,holder:ID.supervisor,note:'[اختبار]',lines:[{material_id:mat,kind:'return',qty:1}]}});check('العهد','إرجاع قطعة للمستودع',r.ok,msg(r));
  r=await cus('supervisor');check('العهد','العهدة بعد الإرجاع = 1',r.ok&&r.j[0]&&+r.j[0].qty===1);
  r=await rpc('sk','fm_custody_count_new',{p:{holder:ID.supervisor,month,lines:[{material_id:mat,counted:1}]}});const cn=r.ok?r.j:null;check('الجرد','أمين المستودع يجرد عهدة المشرف',!!cn,r.ok?'':msg(r));
  if(cn){r=await rpc('engineer','fm_custody_count_sign',{p_id:cn,p_agree:true,p_note:null});check('الجرد','لا يوقّع إلا صاحب العهدة',no(r),msg(r));
   r=await rpc('supervisor','fm_custody_count_sign',{p_id:cn,p_agree:true,p_note:'[اختبار]'});check('الجرد','المشرف يوقّع الجرد',r.j==='signed',msg(r))}
  r=await rpc('engineer','fm_custody_writeoff',{p:{holder:ID.supervisor,reason:'[اختبار]',lines:[{material_id:mat,qty:1}]}});check('العهد','الشطب لمدير النظام / المشروع / التشغيل فقط',no(r),msg(r));
  r=await rpc('admin','fm_custody_writeoff',{p:{holder:ID.supervisor,reason:'[اختبار] تنظيف',lines:[{material_id:mat,qty:1}]}});check('العهد','مدير النظام يشطب العهدة المتبقية',r.ok,msg(r));
  r=await cus('supervisor');check('العهد','العهدة صفر بعد الشطب',r.ok&&(!r.j[0]||+r.j[0].qty===0))}
 r=await rpc('engineer','fm_wh_people');check('المستودع','fm_wh_people يعمل',r.ok&&Array.isArray(r.j),r.ok?r.j.length+' شخص':msg(r));

 /* V184: contractor bills (draft → submit → review → return → cancel; never approved or paid) */
 const oc=((await get('admin','fm_contracts?select=id&name=eq.'+encodeURIComponent('[اختبار] عقد صيانة'))).j||[])[0];
 r=await rpc('admin','fm_contract_save',{p:{id:oc&&oc.id,name:'[اختبار] عقد صيانة',contractor_id:ID.contractor,region:'riyadh',monthly_fixed:1000,rates:{inspection:50,repair:80},mat_mode:'buy',retention_pct:5,vat_pct:15,penalty_cap_pct:10}});
 let ct=r.ok?r.j:null;check('المستخلصات','إنشاء عقد للمقاول التجريبي',!!ct,r.ok?'':msg(r));
 r=await rpc('engineer','fm_contract_save',{p:{name:'[اختبار] x',contractor_name:'x'}});check('المستخلصات','المهندس لا ينشئ عقوداً',no(r,/not allowed/),msg(r));
 if(ct){
  r=await rpc('admin','fm_bill_build',{p_contract:ct,p_month:month,p_bill:null});const lines=r.ok?r.j:[];
  check('المستخلصات','بناء بنود الشهر (الثابت + أوامر المقاول المغلقة)',r.ok&&lines.some(l=>l.k==='fixed'),r.ok?lines.length+' بند':msg(r));
  const old=(await get('admin',`fm_bills?select=id,status&contract_id=eq.${ct}&month=eq.${month}`)).j||[];
  for(const b of old.filter(b=>['draft','returned'].includes(b.status)))await rpc('admin','fm_bill_act',{p_id:b.id,p_action:'cancel',p_note:'[اختبار]'});
  const all=lines.concat([{k:'add',t:'[اختبار] إضافي',q:1,p:200},{k:'ded',t:'[اختبار] خصم',q:1,p:100},{k:'pen',t:'[اختبار] غرامة كبيرة',q:1,p:100000}]);
  r=await rpc('contractor','fm_bill_save',{p:{contract_id:ct,month,lines:all}});check('المستخلصات','المقاول لا يُعدّ مستخلصاً',no(r,/not allowed/),msg(r));
  r=await rpc('admin','fm_bill_save',{p:{contract_id:ct,month,lines:all,note:'[اختبار]'}});const bl=r.ok?r.j:null;
  check('المستخلصات','حفظ مسودة المستخلص',!!bl,r.ok?'الإجمالي '+bl.total:msg(r));
  if(bl){const g=all.filter(l=>['fixed','wo','mat','add'].includes(l.k)).reduce((s,l)=>s+(+l.q||1)*(+l.p||0),0),pen=Math.min(100000,g*.1),net=g-100-pen;
   const exp=Math.round((net+net*.15-net*.05)*100)/100;
   check('المستخلصات','الغرامة بحد 10% والضريبة والمحتجز محسوبة في السيرفر',Math.abs(+bl.total-exp)<0.02,`${bl.total} مقابل ${exp}`);
   r=await get('contractor','fm_bills?select=id,status&id=eq.'+bl.id);check('المستخلصات','المقاول يرى مستخلصه',r.ok&&r.j.length===1);
   r=await get('viewer','fm_bills?select=id&id=eq.'+bl.id);check('المستخلصات','المشاهد لا يرى المستخلصات',r.ok?r.j.length===0:true);
   r=await get('supervisor','fm_bills?select=id&id=eq.'+bl.id);check('المستخلصات','المشرف لا يرى المستخلصات',r.ok?r.j.length===0:true);
   r=await rpc('admin','fm_bill_save',{p:{contract_id:ct,month,lines:[]}});check('المستخلصات','مستخلص واحد للعقد في الشهر',no(r,/bill exists/),msg(r));
   r=await rpc('admin','fm_bill_act',{p_id:bl.id,p_action:'submit',p_note:null});check('المستخلصات','رفع المستخلص للمراجعة',r.j==='submitted',msg(r));
   r=await rpc('engineer','fm_bill_act',{p_id:bl.id,p_action:'approve',p_note:null});check('المستخلصات','المهندس لا يعتمد',no(r,/not allowed/),msg(r));
   r=await rpc('engineer','fm_bill_act',{p_id:bl.id,p_action:'review',p_note:null});check('المستخلصات','مهندس المنطقة يراجع',r.j==='reviewed',msg(r));
   r=await rpc('admin','fm_bill_act',{p_id:bl.id,p_action:'return',p_note:''});check('المستخلصات','الإعادة تتطلب سبباً',no(r,/note required/),msg(r));
   r=await rpc('admin','fm_bill_act',{p_id:bl.id,p_action:'return',p_note:'[اختبار] راجع البنود'});check('المستخلصات','إعادة المستخلص للتعديل',r.j==='returned',msg(r));
   r=await rpc('admin','fm_bill_act',{p_id:bl.id,p_action:'cancel',p_note:'[اختبار]'});check('المستخلصات','إلغاء المستخلص (لا يُعتمد في الفحص)',r.j==='cancelled',msg(r))}}

 /* V186: cost centers */
 const perms=((await get('admin','fm_settings?select=value&key=eq.cc_perms')).j||[])[0];const pv=(perms&&perms.value&&perms.value.view)||[];
 r=await rpc('admin','fm_cc_data',{p_year:year});check('مركز التكلفة','مدير النظام يقرأ مركز التكلفة',r.ok&&r.j&&Array.isArray(r.j.centers),r.ok?r.j.centers.length+' مركز':msg(r));
 const POS={supervisor:'supervisor',contractor:'contractor',viewer:'viewer'};
 for(const k of Object.keys(POS)){r=await rpc(k,'fm_cc_data',{p_year:year});const may=pv.includes(POS[k]);
  check('مركز التكلفة',`${k} ${may?'يقرأ (مسموح في الإعدادات)':'لا يقرأ'}`,may?r.ok:no(r,/not allowed/),r.ok?'':msg(r))}
 r=await req(T.admin,'GET','/rest/v1/fm_cc_staff?select=id&limit=1');check('مركز التكلفة','جدول الرواتب مغلق أمام القراءة المباشرة',!r.ok||r.j.length===0,r.s+'');
 let cc=null;r=await rpc('admin','fm_cc_center_save',{p:{code:'TEST-CC',name:'[اختبار] مركز',kind:'dept',auto:[]}});
 if(r.ok)cc=r.j;else if(/duplicate code/.test(msg(r))){const d=await rpc('admin','fm_cc_data',{p_year:year});cc=((d.j&&d.j.centers)||[]).find(c=>c.code==='TEST-CC');cc=cc&&cc.id;if(cc)await rpc('admin','fm_cc_center_save',{p:{id:cc,code:'TEST-CC',name:'[اختبار] مركز',kind:'dept',auto:[],active:true}})}
 check('مركز التكلفة','إنشاء مركز اختبار',!!cc,r.ok?'':msg(r));
 r=await rpc('contractor','fm_cc_center_save',{p:{code:'TEST-CC2',name:'x'}});check('مركز التكلفة','المقاول لا ينشئ مراكز',no(r,/not allowed/),msg(r));
 if(cc){r=await rpc('admin','fm_cc_entry_save',{p:{center_id:cc,month,kind:'cost',cat:'fuel',amount:1,note:'[اختبار]'}});const en=r.ok?r.j:null;check('مركز التكلفة','قيد يدوي',!!en,r.ok?'':msg(r));
  r=await rpc('admin','fm_cc_entry_save',{p:{center_id:cc,month,kind:'cost',cat:'fuel',amount:0}});check('مركز التكلفة','رفض قيد بمبلغ صفر',no(r,/invalid/),msg(r));
  if(en){r=await rpc('admin','fm_cc_entry_cancel',{p_id:en,p_reason:''});check('مركز التكلفة','الإلغاء يتطلب سبباً',no(r,/reason required/),msg(r));
   r=await rpc('admin','fm_cc_entry_cancel',{p_id:en,p_reason:'[اختبار]'});check('مركز التكلفة','إلغاء القيد',r.j===true,msg(r))}
  r=await rpc('admin','fm_cc_budget_set',{p_center:cc,p_year:year,p_rows:[{m:1,cat:'fuel',amount:-5}]});check('مركز التكلفة','رفض ميزانية سالبة',no(r,/invalid/),msg(r));
  r=await rpc('admin','fm_cc_center_save',{p:{id:cc,code:'TEST-CC',name:'[اختبار] مركز',kind:'dept',auto:[],active:false}});check('مركز التكلفة','إيقاف مركز الاختبار',r.ok,msg(r))}
 r=await req(null,'POST','/rest/v1/rpc/fm_cc_data',{p_year:year});check('مركز التكلفة','الزائر لا يقرأ مركز التكلفة',!r.ok,r.s+'');
 done('v180_results.json')})().catch(e=>{console.log('FATAL',e.stack);process.exitCode=2});
