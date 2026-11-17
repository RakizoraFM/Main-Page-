/* ERP002: project administration using the current tenant/session and ERP001 RPCs. */
(function () {
 'use strict';
 const C = window.FMCloud;
 const E = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const allowed = () => C?.state?.on && C.state.profile?.role === 'admin' && C.state.profile.active !== false && !C.state.profile.deleted_at;
 let projects = [], people = [], orders = [], links = [], members = [], busy = false, generation = 0;
 const q = s => document.querySelector('#erp002 ' + s);
 function page() {
  let p = document.getElementById('erp002');
  if (p) return p;
  p = document.createElement('section'); p.id = 'erp002'; p.className = 'fm103-page';
  p.innerHTML = `<div class="fm103-wrap"><div class="fm103-head"><h2>إدارة المشروعات</h2><button data-close>إغلاق</button></div>
   <p>أنشئ المشروع وحدد أعضاءه، ثم راجع إسناد أوامر العمل.</p><p role="status" data-status></p>
   <button data-reload>تحديث البيانات</button><div data-content hidden>
   <form data-create><h3>مشروع جديد</h3><label>كود المشروع <input name="code" required pattern="[A-Za-z0-9][A-Za-z0-9_-]{1,39}" maxlength="40"></label>
   <label>اسم المشروع <input name="name" required maxlength="200"></label><label>رمز المنطقة <input name="region" required maxlength="100" list="erp002-regions"></label><datalist id="erp002-regions"><option value="qassim">القصيم</option><option value="riyadh">الرياض</option></datalist><button>إنشاء المشروع</button></form>
   <h3>المشروعات</h3><label>اختر المشروع <select data-project></select></label><div data-summary></div>
   <form data-member><h3>أعضاء المشروع</h3><label>المستخدم <select name="user" required></select></label><label>الإجراء <select name="enabled"><option value="true">إضافة</option><option value="false">إلغاء العضوية</option></select></label><label>سبب التعديل <input name="reason" required minlength="3" maxlength="1000"></label><button>حفظ العضوية</button></form><div data-members></div>
   <h3>أوامر العمل</h3><label>بحث بالكود أو العنوان <input data-search type="search"></label><label>العرض <select data-filter><option value="unassigned">غير المنسوب</option><option value="project">المشروع المحدد</option><option value="all">كل الأوامر المتاحة</option></select></label><p data-count></p><div data-orders></div><button data-more hidden>عرض المزيد</button>
   <form data-bind><h3>إسناد أو تصحيح أمر عمل</h3><p data-chosen>اختر أمراً من الجدول</p><label>سبب الإسناد أو التصحيح <input name="reason" required minlength="3" maxlength="1000"></label><button disabled>ربط بالمشروع المحدد</button></form></div></div>`;
  document.body.appendChild(p);
  q('[data-close]').onclick = () => { p.classList.remove('open'); generation++; };
  q('[data-reload]').onclick = load;
  q('[data-project]').onchange = () => { chosen = null; draw(); };
  q('[data-search]').oninput = () => { limit = 50; drawOrders(); };
  q('[data-filter]').onchange = () => { limit = 50; drawOrders(); };
  q('[data-more]').onclick = () => { limit += 50; drawOrders(); };
  q('[data-create]').onsubmit = e => { e.preventDefault(); const f = e.target.elements; mutate('fm_erp_project_create', {p_code:f.code.value.trim(),p_name:f.name.value.trim(),p_region:f.region.value.trim()}); };
  q('[data-member]').onsubmit = e => { e.preventDefault(); const f = e.target.elements; if (!selected()) return status('اختر مشروعاً أولاً'); mutate('fm_erp_project_member_set',{p_project:selected(),p_user:f.user.value,p_enabled:f.enabled.value === 'true',p_reason:f.reason.value.trim()}); };
  q('[data-bind]').onsubmit = e => { e.preventDefault(); if (!chosen || !selected()) return; const link = links.find(l => l.wo_id === chosen.id); mutate('fm_erp_work_order_project_set',{p_wo:chosen.id,p_project:selected(),p_expected_revision:link?.revision || 0,p_reason:e.target.elements.reason.value.trim()}); };
  return p;
 }
 function status(text) { q('[data-status]').textContent = text; }
 const selected = () => q('[data-project]').value;
 async function rows(db, table, fields) {
  const result = [];
  for (let offset = 0;; offset += 500) {
   let query = db.from(table).select(fields).order(table === 'fm_erp_work_order_projects' ? 'wo_id' : table === 'fm_erp_project_members' ? 'project_id' : 'id');
   if (table === 'fm_erp_project_members') query = query.order('user_id');
   const r = await query.range(offset, offset + 499);
   if (r.error) throw r.error;
   result.push(...r.data); if (r.data.length < 500) return result;
  }
 }
 async function load() {
  const seq = ++generation; q('[data-content]').hidden = true;
  if (!allowed()) return status('هذه الصفحة متاحة لمدير النظام الفعّال فقط.');
  status('جارٍ تحميل البيانات…');
  try {
   const db = await C.engClient();
   const data = await Promise.all([
    rows(db,'fm_erp_projects','id,code,name,region,active'), rows(db,'profiles','id,full_name,role,active,deleted_at'),
    rows(db,'work_orders','id,code,title,region'), rows(db,'fm_erp_work_order_projects','wo_id,project_id,revision'),
    rows(db,'fm_erp_project_members','project_id,user_id')
   ]);
   if (seq !== generation || !allowed()) return;
   [projects,people,orders,links,members] = data; const previous = selected();
   q('[data-project]').innerHTML = '<option value="">اختر مشروعاً</option>' + projects.map(p => `<option value="${E(p.id)}">${E(p.code)} — ${E(p.name)}${p.active?'':' (غير نشط)'}</option>`).join('');
   if (projects.some(p => p.id === previous)) q('[data-project]').value = previous;
   q('[data-member] select[name=user]').innerHTML = people.filter(p => p.active && !p.deleted_at && p.role !== 'pending').map(p => `<option value="${E(p.id)}">${E(p.full_name || p.id)}</option>`).join('');
   chosen = null; draw(); q('[data-content]').hidden = false; status('تم تحديث البيانات.'); return true;
  } catch (e) {
   if (seq !== generation) return;
   status(/does not exist|schema cache|PGRST20|42P01/i.test(e.message || e.code || '') ? 'أساس المشروعات غير متاح في قاعدة هذه الشركة. يلزم تطبيق ترحيل ERP001 على بيئة الاختبار أولاً.' : 'تعذر تحميل البيانات: ' + (e.message || 'تحقق من الاتصال وأعد المحاولة.'));
  }
 }
 let chosen = null, limit = 50;
 function draw() {
  const p = projects.find(p => p.id === selected());
  q('[data-summary]').textContent = p ? `المنطقة: ${p.region} — الأعضاء: ${members.filter(m => m.project_id === p.id).length} — أوامر العمل المتاحة: ${links.filter(l => l.project_id === p.id).length}` : '';
  q('[data-members]').textContent = members.filter(m => m.project_id === selected()).map(m => people.find(p => p.id === m.user_id)?.full_name || m.user_id).join('، ') || 'لا يوجد أعضاء';
  q('[data-member] button').disabled = !p;
  q('[data-bind] button').disabled = !p?.active || !chosen || chosen.region !== p.region;
  q('[data-chosen]').textContent = chosen ? `${chosen.code}: ${chosen.title}${chosen.region !== p?.region ? ' — منطقة الأمر تختلف عن المشروع' : ''}` : 'اختر أمراً من الجدول';
  drawOrders();
 }
 function drawOrders() {
  const search = q('[data-search]').value.trim().toLocaleLowerCase(), filter = q('[data-filter]').value;
  const map = new Map(links.map(l => [l.wo_id,l]));
  const list = orders.filter(w => (!search || `${w.code} ${w.title}`.toLocaleLowerCase().includes(search)) && (filter === 'all' || (filter === 'unassigned' ? !map.has(w.id) : map.get(w.id)?.project_id === selected())));
  q('[data-count]').textContent = `عدد النتائج: ${list.length} — المعروض: ${Math.min(limit,list.length)}`;
  q('[data-orders]').innerHTML = `<table><thead><tr><th>الكود</th><th>العنوان</th><th>المنطقة</th><th>المشروع</th><th>اختيار</th></tr></thead><tbody>${list.slice(0,limit).map(w => `<tr><td>${E(w.code)}</td><td>${E(w.title)}</td><td>${E(w.region)}</td><td>${E(projects.find(p => p.id === map.get(w.id)?.project_id)?.name || 'غير منسوب')}</td><td><button data-id="${E(w.id)}">اختيار</button></td></tr>`).join('')}</tbody></table>`;
  q('[data-more]').hidden = list.length <= limit;
  q('[data-orders]').querySelectorAll('button').forEach(b => b.onclick = () => { chosen = orders.find(w => w.id === b.dataset.id); draw(); });
 }
 async function mutate(fn,args) {
  if (busy || !allowed()) return;
  busy = true; const controls = [...document.querySelectorAll('#erp002 button,#erp002 input,#erp002 select')]; controls.forEach(b => b.disabled = true);
  try {
   const db = await C.engClient(), r = await db.rpc(fn,args); if (r.error) throw r.error;
   if (await load()) status('تم الحفظ وتحديث البيانات.');
  } catch (e) {
   if (/stale project assignment/.test(e.message)) { await load(); status('تغير الإسناد بواسطة مستخدم آخر. راجع البيانات المحدّثة ثم اختر الأمر مجدداً.'); }
   else status('تعذر الحفظ: ' + e.message);
  } finally { busy = false; controls.forEach(b => b.disabled = false); if (allowed()) draw(); }
 }
 window.fmERPProjects = async () => { window.fmV103ClosePages?.(); page().classList.add('open'); await load(); };
 setInterval(() => {
  const old = document.getElementById('erp002-nav');
  if (!allowed()) { old?.remove(); document.getElementById('erp002')?.classList.remove('open'); generation++; return; }
  if (old) return; const nav = document.querySelector('nav.v2-nav'); if (!nav) return;
  const b = document.createElement('button'); b.id = 'erp002-nav'; b.className = 'v2-nav-btn'; b.innerHTML = '<span class="v2-nav-label">إدارة المشروعات</span>'; b.onclick = window.fmERPProjects; nav.appendChild(b); window.fmV123Rebuild?.();
 },1500);
})();
