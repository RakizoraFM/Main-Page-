'use strict';
(function(){
 const storageKey='rakizora.integration.connections.v332';let connections=[];
 const status=s=>$('connectionStatus').textContent=s;
 function url(value,required=false){if(!value.trim()){if(required)throw Error('أدخل رابطاً أولاً');return '';}const u=new URL(value);if(u.protocol!=='https:'||u.username||u.password)throw Error('استخدم HTTPS دون بيانات دخول داخل الرابط');if(u.hash)throw Error('رابط البيانات لا يدعم جزء #');return u.href;}
 try{const saved=JSON.parse(localStorage.getItem(storageKey)||'[]');if(!Array.isArray(saved))throw Error();connections=saved.filter(x=>x&&typeof x.id==='string'&&typeof x.name==='string'&&typeof x.source==='string'&&I.fields[x.kind]&&typeof x.website==='string'&&typeof x.endpoint==='string');}catch{status('تعذرت قراءة إعدادات المتصفح؛ يمكنك إعادة إضافتها.');}
 function options(id=''){$('connection').innerHTML='<option value="">منصة جديدة</option>'+connections.map(c=>'<option value="'+esc(c.id)+'">'+esc(c.name)+'</option>').join('');$('connection').value=id;}
 function selected(){const c=connections.find(x=>x.id===$('connection').value);if(!c)throw Error('احفظ المنصة واخترها أولاً');return c;}
 function load(){const c=connections.find(x=>x.id===$('connection').value);for(const [id,key]of [['connectionName','name'],['connectionSource','source'],['connectionKind','kind'],['website','website'],['endpoint','endpoint']])$(id).value=c?.[key]||(key==='kind'?'tickets':'');$('connectionSource').readOnly=!!c;status(c?'يمكنك تعديل الروابط ثم حفظها. معرّف المصدر ثابت.':'أضف بيانات منصة جديدة.');}
 function persist(next){localStorage.setItem(storageKey,JSON.stringify(next));connections=next;}
 $('connection').onchange=load;
 $('saveConnection').onclick=()=>{try{const name=$('connectionName').value.trim(),source=$('connectionSource').value.trim(),kind=$('connectionKind').value,website=url($('website').value),endpoint=url($('endpoint').value);if(!name||!source||(!website&&!endpoint))throw Error('الاسم ومعرّف المصدر ورابط واحد على الأقل مطلوبة');
 const previous=connections.find(x=>x.id===$('connection').value);if(previous&&previous.source!==source)throw Error('معرّف المصدر ثابت');if(connections.some(c=>c.source===source&&c.kind===kind&&c.id!==previous?.id))throw Error('يوجد إعداد لهذا المصدر ونوع البيانات بالفعل');
 const id=previous?.id||crypto.randomUUID(),c={id,name,source,kind,website,endpoint};persist([...connections.filter(x=>x.id!==id),c]);options(id);load();status('تم حفظ روابط المنصة على هذا المتصفح.');}catch(e){status(e.message);}};
 $('deleteConnection').onclick=()=>{try{const c=selected();if(confirm('حذف إعداد '+c.name+'؟ بيانات المراجعة تبقى محفوظة في الجلسة.')){persist(connections.filter(x=>x.id!==c.id));options();load();}}catch(e){status(e.message);}};
 $('openConnection').onclick=()=>{try{const c=selected();window.open(url(c.website,true),'_blank','noopener,noreferrer');}catch(e){status(e.message);}};
 async function body(response){if(!response.body)throw Error('استجابة بلا محتوى');const reader=response.body.getReader(),chunks=[];let size=0;try{while(true){const v=await reader.read();if(v.done)break;size+=v.value.length;if(size>5*1024*1024)throw Error('حجم الاستجابة يتجاوز ٥ ميجابايت');chunks.push(v.value);}const bytes=new Uint8Array(size);let at=0;for(const c of chunks){bytes.set(c,at);at+=c.length;}return new TextDecoder().decode(bytes);}finally{await reader.cancel().catch(()=>{});}}
 $('fetchConnection').onclick=async()=>{if(busy)return;let timer;try{const c={...selected()},endpoint=url(c.endpoint,true);busy=true;invalidate();$('fetchConnection').disabled=true;$('preview').disabled=true;
 status('جارٍ جلب البيانات من '+c.name+'…');const controller=new AbortController();timer=setTimeout(()=>controller.abort(),20000);
 const response=await fetch(endpoint,{method:'GET',credentials:'omit',referrerPolicy:'no-referrer',redirect:'error',signal:controller.signal,headers:{Accept:'application/json,text/csv'}});
 if(!response.ok)throw Error('تعذر الجلب: HTTP '+response.status);const text=await body(response),type=response.headers.get('content-type')||'';
 if(type.includes('text/html')||/^\s*</.test(text))throw Error('هذا رابط صفحة ويب؛ أدخل رابط API أو ملف بيانات');
 const rows=type.includes('json')||/^\s*\[/.test(text)?JSON.parse(text):I.csv(text);
 const incoming=I.normalize(c.kind,c.source,rows);$('source').value=c.source;$('kind').value=c.kind;$('fields').textContent=I.fields[c.kind].join(', ');$('file').value='';
 preview=I.plan(records,incoming);showPlan();log('جلب للقراءة من '+c.name+' — '+rows.length+' سجل');status('تم الجلب والمعاينة. راجع النتائج ثم اعتمد محلياً. لم تتغير منصة المصدر.');
 }catch(e){invalidate();status(e.name==='AbortError'?'انتهت مهلة الجلب بعد ٢٠ ثانية.':e.message+' — تحقق من الرابط وCORS وتوافق حقول القالب. يمكنك استخدام رفع الملف.');}finally{clearTimeout(timer);busy=false;$('fetchConnection').disabled=false;$('preview').disabled=false;}};
 options();
})();
