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
cp sw.js manifest.webmanifest fci_template.xlsx ppm_template.xlsx dist/
cp -r icons dist/
# the Edge Function code (the settings cards copy it from the site)
for f in supabase/functions/*/index.ts; do mkdir -p "dist/$(dirname "$f")"; cp "$f" "dist/$f"; done
cp cloudflare/_worker.js cloudflare/_routes.json cloudflare/404.html dist/
echo "dist/: $(find dist -type f | wc -l) files"
