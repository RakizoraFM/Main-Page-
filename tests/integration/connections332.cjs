const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict'),I=require('../../integrations/core.js');
const elements={};function $(id){return elements[id]||(elements[id]={value:'',textContent:'',innerHTML:'',disabled:false});}
const saved=new Map();let fetched='',opened='',request;
const context={I,$,esc:s=>String(s),crypto:{randomUUID:()=> 'test-id'},localStorage:{getItem:k=>saved.get(k),setItem:(k,v)=>saved.set(k,v)},URL,TextDecoder,Uint8Array,AbortController,setTimeout,clearTimeout,confirm:()=>true,window:{open:u=>opened=u},busy:false,records:[],preview:[],invalidate(){context.preview=[]},showPlan(){},log(){},fetch:async(u,opt)=>{fetched=u;request=opt;return new Response(JSON.stringify([{external_id:'01',building_code:'S-01',status:'open',updated_at:'2026-11-05T09:00:00Z'}]),{headers:{'content-type':'application/json'}})}};
vm.createContext(context);vm.runInContext(fs.readFileSync(require.resolve('../../integrations/connections.js'),'utf8'),context);
(async()=>{
 $('connectionName').value='My platform';$('connectionSource').value='tickets-a';$('connectionKind').value='tickets';$('website').value='https://example.com';$('endpoint').value='https://example.com/first.json';
 $('saveConnection').onclick();assert.equal(JSON.parse([...saved.values()][0])[0].endpoint,'https://example.com/first.json');
 $('endpoint').value='https://other.example/data.json';$('saveConnection').onclick();assert.equal(JSON.parse([...saved.values()][0]).length,1);
 $('openConnection').onclick();assert.equal(opened,'https://example.com/');
 await $('fetchConnection').onclick();assert.equal(fetched,'https://other.example/data.json');assert.equal(request.credentials,'omit');assert.equal(request.redirect,'error');assert.equal(context.preview[0].action,'new');assert.equal(context.preview[0].row.source,'tickets-a');
 $('endpoint').value='javascript:alert(1)';$('saveConnection').onclick();assert.match($('connectionStatus').textContent,/HTTPS/);
 context.fetch=async()=>{throw Error('CORS')};await $('fetchConnection').onclick();assert.match($('connectionStatus').textContent,/CORS/);assert.equal(context.preview.length,0);
 console.log('V332: editable links, persistence, opening, fetch options, preview, unsafe URL rejection, failure passed');
})().catch(e=>{console.error(e);process.exit(1)});
