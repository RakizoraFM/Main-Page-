#!/usr/bin/env python3
"""Split supabase_setup.sql into parts small enough for the Supabase SQL Editor («Query is too large» at ~1 MB).
Cuts only at numbered section headers («-- ---------- N)») outside begin / commit blocks, each part ≤ LIMIT bytes.
Usage: python3 tools/sql_parts.py [out_dir] [limit_kb]   → out_dir/supabase_setup_partXofN.sql (run them in order)."""
import re, sys, os
out = sys.argv[1] if len(sys.argv) > 1 else 'sql_parts'
LIMIT = int(sys.argv[2]) * 1024 if len(sys.argv) > 2 else 330 * 1024
src = os.path.join(os.path.dirname(__file__), '..', 'supabase_setup.sql')
lines = open(src, encoding='utf-8').read().split('\n')
depth, cands = 0, []
for i, l in enumerate(lines):
    if re.match(r'^-- ---------- \d+\)', l) and depth == 0: cands.append(i)
    if re.match(r'^(begin|BEGIN);\s*$', l): depth += 1
    if re.match(r'^(commit|COMMIT);\s*$', l): depth -= 1
cum = [0]
for l in lines: cum.append(cum[-1] + len(l.encode('utf-8')) + 1)
cuts, start = [], 0
for c in cands:
    if cum[c] - cum[start] > LIMIT:
        prev = [x for x in cands if start < x < c]
        cut = prev[-1] if prev else c
        cuts.append((start, cut)); start = cut
cuts.append((start, len(lines)))
os.makedirs(out, exist_ok=True)
for n, (a, b) in enumerate(cuts, 1):
    name = os.path.join(out, f'supabase_setup_part{n}of{len(cuts)}.sql')
    open(name, 'w', encoding='utf-8').write(f'-- supabase_setup.sql — الجزء {n} من {len(cuts)} (شغّل الأجزاء بالترتيب في SQL Editor، كل جزء في استعلام مستقل)\n' + '\n'.join(lines[a:b]) + '\n')
    print(name, round((cum[b] - cum[a]) / 1024), 'KB')
