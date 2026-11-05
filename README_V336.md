# RakizoraFM V336

V336 adds three changes to the V335 source:

1. **Building file history:** an individual record can be opened from the buildings database and receives dated entries with a description, invoice month when relevant, creator, and approval state.
2. **Invoice effect:** an approved base change is applied from its effective date using the existing monthly building proration. An approved signed financial adjustment is added to the selected contractor and service line before VAT; it appears as a separate, described line. Pending or rejected entries do not change invoices. Approved/paid invoice months cannot accept a new approval.
3. **Workforce classification and navigation:** workforce people are classified as company staff or subcontractor personnel. The sidebar separates “الكادر” and “المقاولون”, and “التواصل مع المدارس” is grouped under “المدارس”.

## Supabase update

Apply `migration_v336_building_history.sql` once in the Supabase SQL editor after V335. The same SQL is appended to `supabase_setup.sql` for full installations. It creates the building history table and RPCs, adds `person_type` to workforce people, and updates the workforce save RPC.

## Using the feature

- Open the buildings database and choose **سجل المبنى** on a building row.
- Add the event date and description. For a financially relevant status/scope change, choose an invoice month that matches the event date and use **تغيير أساس الاحتساب**; the event affects the invoice after approval and follows the existing daily proration.
- For a separate addition or deduction, enter the signed amount before VAT, invoice month, service, and contractor. A manager with preparation/approval permission must approve it.
- Review the change log in the building file. The “تغيّرات المباني” billing tab also lists events for the selected month.
- In workforce management, use **كادر الشركة** or **مقاولو الباطن** to keep the classifications separate.

For local-only operation, entries are stored in this browser. Cloud use requires applying the migration first.
