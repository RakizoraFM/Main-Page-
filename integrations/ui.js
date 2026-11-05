'use strict';
const I=window.FMIntegration,$=id=>document.getElementById(id),labels={new:'إضافة',update:'تحديث أحدث',unchanged:'بلا تغيير',duplicate:'رقم مكرر داخل الملف — مستبعد',stale:'تحديث أقدم — مستبعد',conflict:'نفس التوقيت وبيانات مختلفة — مستبعد'},names={tickets:'بلاغ',stock:'رصيد',movements:'حركة'};
let records=[],preview=[],logs=[],busy=false;
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function download(name,data,type='application/json'){const u=URL.createObjectURL(new Blob([data],{type})),a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);}
function log(message){logs.unshift({at:new Date().toISOString(),message});logs=logs.slice(0,100);render();}
function invalidate(){preview=[];$('previewRows').innerHTML='';$('approve').disabled=true;$('exportPreview').disabled=true;}
function render(){
 $('stats').innerHTML=['tickets','stock','movements'].map(k=>'<div class="stat">'+names[k]+'<strong>'+records.filter(r=>r.kind===k).length+'</strong></div>').join('')+[...new Set(records.filter(r=>r.kind==='movements').map(r=>r.source))].map(s=>'<div class="stat">صافي تكلفة الحركات · '+esc(s)+'<strong>'+I.costs(records,s).toLocaleString('en-US',{maximumFractionDigits:2})+'</strong>عملة المصدر · لا تجمع مصادر مكررة</div>').join('');
 $('records').innerHTML=records.slice(0,500).map(r=>'<tr><td>'+esc(r.source)+' · '+names[r.kind]+'</td><td>'+esc(r.external_id)+'</td><td dir="ltr">'+esc(r.updated_at)+'</td><td>'+esc(JSON.stringify(r))+'</td></tr>').join('');
 $('logs').innerHTML=logs.map(l=>'<p><time>'+esc(l.at)+'</time> — '+esc(l.message)+'</p>').join('')||'لا توجد عمليات في هذه الجلسة.';
}
function showPlan(){const count={};for(const p of preview)count[p.action]=(count[p.action]||0)+1;
 $('message').textContent=Object.entries(count).map(([k,n])=>labels[k]+': '+n).join(' · ')+'\nالمعروض أول 500 صف؛ التقرير يشمل كل الصفوف. السجلات الغائبة عن الملف تبقى دون حذف.';
 $('previewRows').innerHTML=preview.slice(0,500).map(p=>'<tr><td>'+esc(p.row.external_id)+'</td><td><span class="tag">'+labels[p.action]+'</span></td><td>'+esc(JSON.stringify(p.row))+'</td></tr>').join('');
 $('approve').disabled=!preview.some(p=>['new','update'].includes(p.action));$('exportPreview').disabled=!preview.length;
}
async function readFile(file){if(!file)throw Error('اختر الملف أولاً');if(file.size>5*1024*1024)throw Error('الحد الأقصى ٥ ميجابايت');return file.text();}
for(const id of ['source','kind','file'])$(id).onchange=()=>{invalidate();$('fields').textContent=I.fields[$('kind').value].join(', ');};
$('source').oninput=invalidate;
$('fields').textContent=I.fields.tickets.join(', ');
$('template').onclick=()=>{const k=$('kind').value;download('rakizora-'+k+'-template.csv','\uFEFF'+I.fields[k].join(',')+'\r\n','text/csv;charset=utf-8');};
$('preview').onclick=async()=>{if(busy)return;busy=true;invalidate();const source=$('source').value,kind=$('kind').value,file=$('file').files[0];$('preview').disabled=true;
 try{const text=await readFile(file);if(source!==$('source').value||kind!==$('kind').value||file!==$('file').files[0])throw Error('تغير الاختيار؛ أعد الفحص');const rows=file.name.toLowerCase().endsWith('.json')?JSON.parse(text):I.csv(text);preview=I.plan(records,I.normalize(kind,source,rows));showPlan();log('فحص '+file.name+' — '+rows.length+' سجل — '+source);}
 catch(e){$('message').textContent=e.message;}finally{busy=false;$('preview').disabled=false;}};
$('approve').onclick=()=>{if(busy)return;const accepted=preview.filter(p=>['new','update'].includes(p.action)).length;records=I.apply(records,preview);invalidate();$('message').textContent='تم اعتماد '+accepted+' سجل في نسخة المراجعة فقط. نزّل نسخة الجلسة للاحتفاظ بها.';log('اعتماد محلي: '+accepted+' سجل');};
$('exportPreview').onclick=()=>download('rakizora-review.json',JSON.stringify(preview,null,2));
$('backup').onclick=()=>download('rakizora-integration-session.json',JSON.stringify({format:'rakizora-integration-331',at:new Date().toISOString(),records,logs},null,2));
$('clear').onclick=()=>{if(busy)return;if(confirm('مسح نسخة المراجعة في هذه الصفحة؟ نزّل نسخة الجلسة إذا كنت تحتاجها.')){records=[];logs=[];invalidate();$('message').textContent='تم مسح مساحة المراجعة.';render();}};
$('restore').onclick=()=>{if(!busy)$('restoreFile').click();};
$('restoreFile').onchange=async()=>{if(busy)return;busy=true;try{const d=JSON.parse(await readFile($('restoreFile').files[0]));if(d.format!=='rakizora-integration-331'||!Array.isArray(d.records)||d.records.length>10000)throw Error('نسخة جلسة غير صحيحة');
 const restored=d.records.map(r=>I.normalize(r.kind,String(r.source??''),[r])[0]);if(new Set(restored.map(I.key)).size!==restored.length)throw Error('تكرار في نسخة الجلسة');
 if(records.length&&!confirm('استبدال نسخة المراجعة الحالية بنسخة الجلسة؟'))return;records=restored;logs=[];invalidate();$('message').textContent='تمت استعادة نسخة المراجعة؛ لم يتغير أي نظام خارجي.';log('استعادة جلسة: '+records.length+' سجل');}catch(e){$('message').textContent=e.message;}finally{busy=false;$('restoreFile').value='';}};
window.addEventListener('beforeunload',e=>{if(records.length){e.preventDefault();e.returnValue='';}});
render();
