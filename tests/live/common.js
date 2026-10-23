// Shared helpers for the live tests against the real Supabase project (test accounts only).
// Passwords are never stored in the repo: FM_TEST_PASS (one password for all test accounts),
// or FM_TEST_<ROLE>_PASS for one account. Node must use the environment proxy: run with
// NODE_USE_ENV_PROXY=1 (and NODE_EXTRA_CA_CERTS when the proxy has its own CA).
const fs=require('fs'),path=require('path');
const ROOT=path.resolve(__dirname,'../..');
const html=fs.readFileSync(path.join(ROOT,'start.html'),'utf8');
const U=html.match(/https:\/\/[a-z0-9]+\.supabase\.co/)[0],K=html.match(/key:'([^']+)'/)[1];
const ROLES=['admin','engineer','supervisor','contractor','viewer'];
const NAMES={admin:'مدير اختبار',engineer:'مهندس اختبار',supervisor:'مشرف اختبار',contractor:'مقاول اختبار',viewer:'مشاهد اختبار'};
const C={};for(const k of ROLES)C[k]={email:`fm.test.${k}@rakizora.test`,password:process.env[`FM_TEST_${k.toUpperCase()}_PASS`]||process.env.FM_TEST_PASS||'',name:NAMES[k]};
// V180: an extra storekeeper account (not in ROLES; the test admin creates it when missing, region «test» only)
C.storekeeper={email:'fm.test.storekeeper@rakizora.test',password:process.env.FM_TEST_STOREKEEPER_PASS||process.env.FM_TEST_PASS||'',name:'أمين مستودع اختبار'};
const SCHOOL='مدرسة اختبار RakizoraFM',CODE='TEST-RKZ-001';
async function req(tok,method,p,body,h={}){const bin=body instanceof Buffer;
 const r=await fetch(U+p,{method,headers:Object.assign({apikey:K,Authorization:'Bearer '+(tok||K)},body!==undefined&&!bin?{'Content-Type':'application/json'}:{},h),body:body===undefined?undefined:bin?body:JSON.stringify(body)});
 const t=await r.text();let j;try{j=JSON.parse(t)}catch(e){j=t}return {s:r.status,j,ok:r.ok}}
const msg=x=>typeof x.j==='object'&&x.j?(x.j.message||x.j.msg||x.j.error_description||JSON.stringify(x.j).slice(0,120)):String(x.j).slice(0,120);
async function login(k){if(!C[k].password)throw Error('no password (FM_TEST_PASS)');const r=await req(null,'POST','/auth/v1/token?grant_type=password',{email:C[k].email,password:C[k].password});
 if(!r.ok)throw Error(r.s+' '+msg(r));return {token:r.j.access_token,id:r.j.user.id}}
function reporter(){const R=[];return {R,check(area,name,pass,detail){R.push({area,name,pass:!!pass,detail:detail||''});console.log(pass?'✅':'❌',area,'—',name,detail?'— '+detail:'')},
 skip(area,name,why){R.push({area,name,pass:null,detail:why});console.log('⏭️ ',area,'—',name,'—',why)},
 done(file){const p=R.filter(x=>x.pass===true).length,f=R.filter(x=>x.pass===false).length,s=R.filter(x=>x.pass===null).length;
  fs.writeFileSync(path.join(__dirname,file),JSON.stringify(R,null,1));console.log(`\nناجح ${p} • فاشل ${f} • متخطّى ${s}`);if(f)process.exitCode=1}}}
module.exports={ROOT,U,K,C,ROLES,SCHOOL,CODE,req,msg,login,reporter};
