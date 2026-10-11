# FM Platform — notes for Claude

School facility-maintenance ticket analytics for Shalfa International (Riyadh and Qassim regions).
The owner is Mohamed (Facility Program Manager). Reply to him in **Arabic**, concisely. Code comments stay in English.

## Files
| File | What it is |
|---|---|
| `index.html` | The whole desktop platform. It is a single offline-capable HTML file (~1.8 MB) with all CSS and JS inline. |
| `field.html` | The mobile field app (FM Field): a small standalone page for supervisors and contractors. |
| `start.html` | The start page: one sign-in for every role, then admin/engineer/viewer go to `index.html` and supervisor/contractor go to `field.html`. Shares the cloud config and session with both. `DEFAULT_CFG` holds the site's Supabase URL and anon key (never a service_role key). |
| `supabase_setup.sql` | Supabase schema and Row Level Security. The owner runs it in the Supabase SQL editor; it is idempotent. |

GitHub Pages publishes the `main` branch. Every merge to `main` goes live within about a minute.

## How index.html is built (read before editing)
- **Layered patches.** Each version (V1xx) appended a `<style id="fm-v1xx-…">` and/or a `<script id="fm-v1xx-…">` block before `</body>`. Later layers wrap or override earlier globals (for example `window.processData`, `renderDataTable`, `fmSchoolDbRender`). Many globals are defined several times on purpose: the last definition wins. Do not "deduplicate" without tracing the callers.
- **Prefer adding a new layer** (a new `<script id="fm-v1NN-…">` before `</body>`) or making small exact replacements. Do not rewrite big sections.
- **Version bump on every change** (all three are required):
  1. `<meta name="fm-version" content="V1NN">` at the top of `<head>`. The «يوجد إصدار جديد» banner compares this value with the copy on the server.
  2. `const APP={version:'V1NN',date:'YYYY-MM-DD'` in the APP script.
  3. A new first entry after `const CHANGELOG=[` in this shape: `{v:'V1NN',d:'YYYY-MM-DD',t:'عنوان',i:['تغيير 1','تغيير 2']},` with the text in Arabic.

  For `field.html`, bump `<meta name="fm-version" content="F…">`; for `start.html`, bump `content="S…"`.
- **First script must stay first:** `fm-v116-health-capture` records load errors into `window.__fmHealth`.
- **Key globals:**
  - `state` holds `rawTickets`, `filteredTickets`, `columnsMap{ticketId,school,status,priority,date,category,subCategory,description,resolvedDate?}` and `detectedMaxDate`.
  - `FM41.active` is `'riyadh'` or `'qassim'`; `FM41.datasets[k].rows` holds that region's rows.
  - Helpers: `normalizeStatus`, `normalizePriority`, `getTicketSLAInfo(row)` (open tickets are measured up to `detectedMaxDate`), `getTicketStaff(row)`, `fmV81SchoolMeta(row)`, `fmAuthoritativeSchoolName(row)`, `parseDateTime`.
- **Pages:** a sub-page is a `section.fm103-page` with `.fm103-head`, `.fm103-actions`, `.extra` and `.body`. Open it with the pattern used by the other layers (`page(id,title)` and `openPage(id,btn)`), and close it with `fmV103ClosePages()`.
- **Sidebar:** `nav.v2-nav` (it has a class, not an id), grouped by the V123 `GROUPS` array. Add new nav ids to the right group there.
- **Settings hub:** «الإعدادات» has tabs. Extend a tab with `(window.fmHubExtras=window.fmHubExtras||[]).push((tab,pane)=>{…})`.
- **Ticket work (V135):** stages, solution, photos, notes. Records are stored in `localStorage['fm_ticket_work_v135']` and laid over the uploaded rows, so every indicator follows them. Photos go to IndexedDB `fm_photos_v135`, or to Supabase when the cloud is on.
- **Cloud (V136):** `window.FMCloud` (in `fm-v136-cloud`). All network calls go through `FMCloud.api.*`; tests replace that object with a mock. Roles are `admin`, `engineer`, `supervisor`, `contractor`, `viewer` and `pending`, enforced by RLS in `supabase_setup.sql`. Never put a service_role key in any file.
- **Work orders (V145, field F8):** tables `work_orders`, `wo_events`, `wo_photos` (bucket `wo-photos`). Reads go through RLS (`fm_wo_can_see`); every change goes through `fm_wo_create` / `fm_wo_act`, which enforce the hierarchy (`profiles.reports_to`, ranks admin > engineer > supervisor > contractor) and the allowed status steps. The assignee reports «done» (needs an «after» photo); the assigner approves (`close`) or returns it.
- **Group orders (V146):** «أمر لمجموعة مدارس» creates one order per school through `fm_wo_create_many` (all or nothing, max 500 per call, sent in chunks of 200 with the same `batch_id`). Orders of one group share `batch_id` / `batch_title` («حملة»). Schools come from the school DB (filters: region, office, city taken from the tickets, responsible person) or from an Excel file; the assignee is each school's responsible person matched to `fm_wo_assignable()` by email, then by name / `person_names`.
- **Templates and recurring campaigns (V147):** built-in templates (`READY` in `fm-v147-wo-templates`) plus saved ones in table `wo_templates` (shared or private, may carry school keys). Recurring campaigns live in `wo_schedules` (snapshot of schools + assignees). Writes go through `fm_wo_schedule_save` / `fm_wo_schedule_act`; `fm_wo_run_due()` creates the due batches in the owner's name (`fm_wo_create_as`, hierarchy re-checked, schools whose assignee left the line are skipped). pg_cron calls it hourly when enabled; the platform also calls it once when it opens.
- **Approved PPM set and inspection results (V148, field F9):** the owner's 20 preventive-maintenance orders (8 systems, 125 items) live in `PPM` in `fm-v148-ppm` and appear first in the template list. A checklist item is `{t, tool?, done, res?:'ok'|'fix'|'fixed'|'na', note?, materials?:[{n,q,u,src:'store'|'buy'}]}`; `wo_photos.item` ties a photo to an item index and `kind='arrival'` + `tag` (sign / entrance / fence) documents the arrival. `fm_wo_act('done')` refuses a school order without the 3 arrival photos, a «fixed» item without materials and before/after photos, and a «fix» item without a before photo.
- **Repair orders, materials, costs, PDF, offline (V149, field F10):** `fm_wo_repair(src, p)` turns the «fix» items of an order into a repair order (`type='repair'`, `source_wo`, items get `rwo` = the new code, their before photos are copied; the storage read policy also allows a photo path listed in a visible order). Table `wo_materials` is the warehouse list (admin/engineer edit it from «🧰 أصناف المواد»); a material keeps `id` and the unit `price` at the time of use, and a purchase (`src:'buy'`) needs a price and an `invoice` photo on the item (also checked by `fm_wo_act('done')`). `fmV149Pdf(orders)` opens a printable report (one page per order). The field app queues work-order actions and photos (`woSend`; photos in IndexedDB `fmf_photos`) and sends them in order when the connection returns; in a checklist textarea one item per line is written `البند | الأداة` (`fmWoParseCl`). The field app records `res`/`note` per item; the platform shows them in the order detail, counts «يحتاج إصلاح» in the campaign header and exports a «بنود الفحص» sheet. Revised files in the same layout are imported as shared templates (`fmV148Import`).
- **School DB:** stored in `localStorage['fm_school_master_db_v1']`. The approved Excel template has 22 columns in a fixed order (see `rowObj` in `fm-school-db-maintenance-excel-v9`). Importing never wipes a column that is missing from the file.

## Rules
- Keep everything in **one file per app**. External libraries come only from cdnjs or jsdelivr, with exact versions.
- Arabic RTL UI. Use the Cairo font with Tahoma as fallback, and Gregorian dates via `ar-SA-u-ca-gregory`.
- Do not change existing numbers or SLA logic unless asked. After a change, compare the KPIs and page outputs with the previous version.
- Be honest in the summary about anything that could not be tested, for example a real Supabase server, the real OpenStreetMap search, or a real phone.
- Commit message: `V1NN — short description`. Deliver through a branch and PR; the owner merges to `main`.
