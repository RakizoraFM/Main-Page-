# V330 local verification

Use Node 22+ with `@electric-sql/pglite` and `playwright` installed in an external dependency directory; make dependencies resolvable without committing node_modules.

- `node tests/integration/billing330.mjs`: loads the complete current setup in an isolated PGlite database, synthetic Auth/Storage and test users, then exercises scopes, deductions, permissions, actual service billing, atomic rollback and section reapplication.
- `FM_BROWSER_PATH=/path/to/chromium node tests/integration/browser330.cjs`: full static app loaded via file URL (avoids published-site sign-in redirect), isolated report/query fixtures, external backends blocked. Checks monthly page, template dialog, formulas/download, monthly and individual print views, recurrence and mobile width. CDN assets are cached in the OS temp directory. Test-only PDFs/screenshots/XLSX are temporary and must not be delivered as real invoices.

No live Supabase, payment, WhatsApp, production write, deployment or external platform integration is exercised. Browser fixture checks do not replace the SQL permission checks. Fixtures use fictitious contracts and services.
