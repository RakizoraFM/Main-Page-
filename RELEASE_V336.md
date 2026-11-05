# Release V336 — Building history, invoice adjustments, workforce classification

- Added a dated, auditable history panel to each building file.
- Added approval-gated financial adjustments, linked to a building, invoice month, contractor, and service. Approved amounts flow into the invoice before VAT; the invoice displays their descriptions.
- Approved base changes use their recorded effective date and existing invoice proration. Changes cannot be approved after the month is locked by an approved or paid bill.
- Added separate workforce classifications for company staff and subcontractor personnel.
- Moved “التواصل مع المدارس” into the “المدارس” sidebar group and separated “المقاولون” from “الكادر”.

## Database

Run `migration_v336_building_history.sql` after V335. It is also appended to `supabase_setup.sql`.
