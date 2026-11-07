#!/usr/bin/env bash
# Cloudflare Pages build: copies only the files the site needs into dist/.
# Pages settings: Build command «bash tools/cf_build.sh», Build output directory «dist».
# Not published: SQL files, reports (*.md), archives, tests, tools.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf dist && mkdir -p dist
cp index.html field.html start.html rate.html school.html supplier.html saas.html try.html dist/
cp integrations.html dist/
cp -r integrations dist/
cp -r assets dist/
# V334-V336 modules are loaded from the page at runtime and must be included in the Pages artifact.
cp workforce_v334.js workforce_v335.js building_history_v336.js dist/
cp sw.js manifest.webmanifest fci_template.xlsx ppm_template.xlsx dist/
cp -r icons dist/
# Repair two literal line breaks inside JavaScript strings in the generated homepage (no-op since V340 fixed the source).
python3 - <<'PY'
from pathlib import Path

page = Path("dist/index.html")
source = page.read_text(encoding="utf-8")
repairs = [
    (
        "+clone.outerHTML+'\n\n\n</body></html>';",
        "+clone.outerHTML+'\\n</body></html>';"
    ),
    (
        "⏳ جارٍ تجهيز التقرير…\n\n\n</body>');",
        "⏳ جارٍ تجهيز التقرير…\\n</body>');"
    ),
]
for broken, fixed in repairs:
    # V342: index.html itself was repaired in V340; only patch a copy that is still broken
    if broken in source:
        source = source.replace(broken, fixed, 1)
page.write_text(source, encoding="utf-8")
PY
# the Edge Function code (the settings cards copy it from the site)
for f in supabase/functions/*/index.ts; do mkdir -p "dist/$(dirname "$f")"; cp "$f" "dist/$f"; done
cp cloudflare/_worker.js cloudflare/_routes.json cloudflare/404.html dist/
echo "dist/: $(find dist -type f | wc -l) files"
