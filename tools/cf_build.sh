#!/usr/bin/env bash
# Cloudflare Pages build: copies only the files the site needs into dist/.
# Pages settings: Build command «bash tools/cf_build.sh», Build output directory «dist».
# Not published: SQL files, reports (*.md), archives, tests, tools.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf dist && mkdir -p dist
cp index.html field.html start.html rate.html school.html supplier.html saas.html try.html dist/
# Public marketing pages linked from the shared header must be present in the Pages artifact.
cp services.html rakizora.html solvix.html partners.html contact.html dist/
cp integrations.html dist/
cp -r integrations dist/
cp -r assets dist/
# V334-V336 modules are loaded from the page at runtime and must be included in the Pages artifact.
cp workforce_v334.js workforce_v335.js building_history_v336.js dist/
cp sw.js manifest.webmanifest fci_template.xlsx ppm_template.xlsx dist/
cp -r icons dist/
# V345: the old «repair two broken JavaScript strings» step was removed — index.html is fixed since V340, and the step's
# own Python broke when an edit inserted blank lines before every </body> (multi-line string literal → SyntaxError).
# the Edge Function code (the settings cards copy it from the site)
for f in supabase/functions/*/index.ts; do mkdir -p "dist/$(dirname "$f")"; cp "$f" "dist/$f"; done
cp cloudflare/_worker.js cloudflare/_routes.json cloudflare/404.html dist/
echo "dist/: $(find dist -type f | wc -l) files"
