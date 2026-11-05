(function(root){
'use strict';
const fields={tickets:['external_id','building_code','status','updated_at','description'],stock:['external_id','item_code','warehouse','quantity','unit_cost','updated_at'],movements:['external_id','ticket_external_id','item_code','warehouse','type','quantity','unit_cost','updated_at']};
function csv(text){
 const rows=[];let row=[],cell='',quoted=false;
 text=text.replace(/^\uFEFF/,'');
 for(let i=0;i<text.length;i++){const c=text[i];if(c==='"'){if(quoted&&text[i+1]==='"'){cell+='"';i++;}else if(quoted||cell==='')quoted=!quoted;else throw Error('علامة اقتباس غير صحيحة');}
 else if(!quoted&&(c===','||c==='\n'||c==='\r')){row.push(cell);cell='';if(c!==','){if(c==='\r'&&text[i+1]==='\n')i++;if(row.some(x=>x.trim()))rows.push(row);row=[];}}
 else cell+=c;}
 if(quoted)throw Error('حقل اقتباس غير مغلق');row.push(cell);if(row.some(x=>x.trim()))rows.push(row);
 if(!rows.length)throw Error('الملف فارغ');const heads=rows.shift().map(x=>x.trim());
 if(new Set(heads).size!==heads.length||heads.some(x=>!x))throw Error('أسماء أعمدة فارغة أو مكررة');
 return rows.map((r,i)=>{if(r.length!==heads.length)throw Error('عدد الأعمدة غير صحيح في الصف '+(i+2));return Object.fromEntries(heads.map((h,j)=>[h,r[j]]));});
}
function normalize(kind,source,input){
 if(!fields[kind]||!source.trim())throw Error('اختر نوع البيانات واسم المصدر');
 if(!Array.isArray(input)||input.length>10000)throw Error('المطلوب مصفوفة حتى 10000 سجل');
 return input.map((v,i)=>{
 if(!v||typeof v!=='object'||Array.isArray(v))throw Error('سجل غير صحيح: '+(i+1));
 const r={};for(const f of fields[kind])r[f]=String(v[f]??'').trim();
 const required=fields[kind].filter(f=>!['description','ticket_external_id'].includes(f));
 for(const f of required)if(!r[f])throw Error('الصف '+(i+1)+': الحقل مطلوب '+f);
 if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(r.updated_at)||!Number.isFinite(Date.parse(r.updated_at)))throw Error('الصف '+(i+1)+': updated_at يحتاج توقيتاً بمنطقة زمنية');
 for(const f of ['quantity','unit_cost'])if(f in r){if(!/^(\d+(\.\d*)?|\.\d+)$/.test(r[f]))throw Error('الصف '+(i+1)+': رقم موجب أو صفر مطلوب '+f);r[f]=Number(r[f]);if(!Number.isFinite(r[f]))throw Error('قيمة رقمية كبيرة');}
 if(kind==='movements'&&(!['issue','return','cancelled'].includes(r.type)||r.quantity<=0))throw Error('نوع الحركة issue / return / cancelled والكمية أكبر من صفر');
 return {...r,source:source.trim(),kind};
 });
}
const key=r=>JSON.stringify([r.source,r.kind,r.external_id]);
const same=(a,b)=>fields[a.kind].every(f=>a[f]===b[f]);
function plan(current,incoming){
 const counts=new Map();for(const r of incoming)counts.set(key(r),(counts.get(key(r))||0)+1);
 return incoming.map(row=>{const old=current.find(x=>key(x)===key(row));let action='new';
 if(counts.get(key(row))>1)action='duplicate';
 else if(old){const t=Date.parse(row.updated_at)-Date.parse(old.updated_at);action=same(old,row)?'unchanged':t<0?'stale':t===0?'conflict':'update';}
 return {row,action};
 });
}
function apply(current,preview){const map=new Map(current.map(r=>[key(r),r]));for(const p of preview)if(['new','update'].includes(p.action))map.set(key(p.row),p.row);return [...map.values()];}
function costs(records,source){return records.filter(r=>r.kind==='movements'&&r.source===source&&r.type!=='cancelled').reduce((a,r)=>a+(r.type==='return'?-1:1)*r.quantity*r.unit_cost,0);}
const api={fields,csv,normalize,key,plan,apply,costs};if(typeof module!=='undefined')module.exports=api;else root.FMIntegration=api;
})(typeof window!=='undefined'?window:globalThis);
