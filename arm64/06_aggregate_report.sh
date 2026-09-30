#!/bin/bash
# =============================================================================
# 06_aggregate_report.sh — LDM-OS aarch64 adaptation: aggregate + compare
#
# Reads every CSV suite under ${BENCH_RESULTS} (plus the classic txt suite),
# computes trad-vs-LDM deltas at test granularity, classifies each test as
# improved / equal / regression, and writes:
#   ${BENCH_RESULTS}/aggregated.csv
#   ${BENCH_RESULTS}/aggregated_report.md
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

step "LDM-OS AArch64 benchmark aggregation"
echo "  Results dir: ${BENCH_RESULTS}"
[ -d "${BENCH_RESULTS}" ] || { err "results dir missing: ${BENCH_RESULTS} (run 05 first)"; exit 1; }

python3 - "${BENCH_RESULTS}" <<'PYEOF'
import csv, os, re, sys
from pathlib import Path
from collections import OrderedDict

res = Path(sys.argv[1])
THRESH = 1.0  # classify |delta| >= 1% as improvement/regression

def load_csv(p):
    d = {}
    try:
        with open(p) as f:
            for row in csv.DictReader(f):
                t = row['test']
                d.setdefault(t, []).append(float(row['throughput_mbps']))
    except Exception as e:
        print(f"  WARN {p}: {e}")
    return d

def mean(xs):
    return sum(xs)/len(xs) if xs else 0.0

cls = {}
# CSV suites
for csv_trad in sorted(res.glob("*_trad.csv")):
    suite = csv_trad.name.replace("_trad.csv", "")
    csv_ldm = res / f"{suite}_ldm.csv"
    if not csv_ldm.exists():
        continue
    td, ld = load_csv(csv_trad), load_csv(csv_ldm)
    for t in sorted(set(td) | set(ld)):
        cls[(suite, t)] = (mean(td.get(t, [0.0])), mean(ld.get(t, [0.0])))

# classic txt suite: lines like "  memcpy_sequential    3.365 ms     19946.0 MB/s  (...)"
txt_re = re.compile(r"^\s+(\S+)\s+[\d.]+\s+ms\s+([\d.]+)\s+MB/s")
def load_txt(mode):
    p = res / f"ldm_benchmark_{mode}.txt"
    out = {}
    if p.exists():
        with open(p) as f:
            for line in f:
                m = txt_re.match(line)
                if m:
                    out[m.group(1)] = float(m.group(2))
    return out

trad_t, ldm_t = load_txt("trad"), load_txt("ldm")
for t in sorted(set(trad_t) | set(ldm_t)):
    cls[("classic", t)] = (trad_t.get(t, 0.0), ldm_t.get(t, 0.0))

rows = []
for (suite, t), (ta, la) in cls.items():
    delta = ((la - ta)/ta*100.0) if ta else 0.0
    if delta >= THRESH:
        verdict = "IMPROVED"
    elif delta <= -THRESH:
        verdict = "REGRESSION"
    else:
        verdict = "equal"
    rows.append([suite, t, f"{ta:.2f}", f"{la:.2f}", f"{delta:+.2f}%", verdict])

rows.sort(key=lambda r: (r[0], r[1]))

with open(res / "aggregated.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["suite", "test", "trad_mbps", "ldm_mbps", "delta_pct", "verdict"])
    w.writerows(rows)

n_imp = sum(1 for r in rows if r[5] == "IMPROVED")
n_reg = sum(1 for r in rows if r[5] == "REGRESSION")
n_eq  = len(rows) - n_imp - n_reg

lines = []
lines.append("# LDM-OS AArch64 Benchmark Aggregate Report")
lines.append("")
lines.append(f"- Generated: {__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
lines.append(f"- Data dir : {res}")
lines.append(f"- Tests    : {len(rows)}  |  IMPROVED {n_imp}  |  equal {n_eq}  |  REGRESSION {n_reg}")
lines.append("")
lines.append("| suite | test | trad (MB/s) | ldm (MB/s) | delta | verdict |")
lines.append("|---|---|---:|---:|---:|---|")
for r in rows:
    lines.append("| {} | {} | {} | {} | {} | {} |".format(*r))
lines.append("")
with open(res / "aggregated_report.md", "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"  aggregated.csv        : {len(rows)} rows")
print(f"  aggregated_report.md  : IMPROVED {n_imp} / equal {n_eq} / REGRESSION {n_reg}")
PYEOF
ok "Aggregate report written to ${BENCH_RESULTS}/aggregated_report.md"