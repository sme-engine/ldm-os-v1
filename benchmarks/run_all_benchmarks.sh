#!/bin/bash
# =============================================================================
# LDM-OS All-Benchmarks Runner (AArch64 / Kunpeng adapted)
#
# Builds and runs every user-space benchmark in this directory in BOTH
# traditional and LDM modes, then aggregates CSV data into the results
# directory and prints a summary table.
#
# Usage:
#   ./run_all_benchmarks.sh [--rounds N] [--size MB] [--skip-build]
#
# Environment:
#   ROUNDS : number of rounds per mode (default 50)
#   SIZE_MB: test buffer size in MB for ldm_benchmark (default 64)
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUNDS="${ROUNDS:-50}"
SIZE_MB="${SIZE_MB:-64}"
SKIP_BUILD="${SKIP_BUILD:-0}"
RES_DIR="${DIR}/aarch64_results"
mkdir -p "${RES_DIR}"

echo "================ LDM-OS All-Benchmarks Runner ================"
echo "Date    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Machine : $(uname -m) / Linux $(uname -r)"
echo "Rounds  : ${ROUNDS} per mode x 2 modes"
echo "Results : ${RES_DIR}"
echo "==============================================================="

if [ "${SKIP_BUILD}" != "1" ]; then
  echo ""
  echo "[build] Compiling all benchmarks..."
  gcc -O2 -Wall -o "${DIR}/ldm_benchmark"      "${DIR}/ldm_benchmark.c"      -lpthread -lrt
  gcc -O2 -Wall -o "${DIR}/ldm_bench_v2"       "${DIR}/ldm_benchmark_v2.c"   -lpthread -lrt
  gcc -O2 -Wall -o "${DIR}/ldm_bench_v3"       "${DIR}/ldm_benchmark_v3.c"   -lpthread -lrt
  gcc -O2 -Wall -o "${DIR}/ldm_api_bench"      "${DIR}/ldm_api_benchmark.c"  -lpthread -lrt
  gcc -O2 -Wall -o "${DIR}/ldm_residency_bench" "${DIR}/ldm_residency_bench.c" -lpthread -lrt
  gcc -O2 -Wall -o "${DIR}/ldm_enterprise_bench" "${DIR}/ldm_enterprise_bench.c" -lpthread -lrt
  gcc -O2 -Wall -o "${DIR}/ldm_ai_bench"        "${DIR}/ldm_ai_benchmark.c"   -lpthread -lrt -lm
  gcc -O2 -Wall -o "${DIR}/ldm_ai_fullchain"    "${DIR}/ldm_ai_fullchain.c"   -lpthread -lrt -lm
  echo "[build] Done."
fi

pids=()
run_one() {
  local name="$1"; shift
  local bin="$1"; shift
  local trad_csv="${RES_DIR}/${name}_trad.csv"
  local ldm_csv="${RES_DIR}/${name}_ldm.csv"
  echo ""
  echo "######## [$name] traditional ########"
  "${bin}" --rounds "${ROUNDS}" --output "${trad_csv}" >/dev/null 2>&1 || { echo "[FAIL] ${name} traditional"; exit 1; }
  echo "######## [$name] LDM-optimized ########"
  "${bin}" --ldm --rounds "${ROUNDS}" --output "${ldm_csv}" >/dev/null 2>&1 || { echo "[FAIL] ${name} ldm"; exit 1; }
  echo "[OK] ${name} -> ${trad_csv} + ${ldm_csv}"
}

# 1) Classic 8-test suite (CSV not supported; capture stdout)
echo ""
echo "######## [ldm_benchmark] traditional ########"
"${DIR}/ldm_benchmark" --iterations 100 --size "${SIZE_MB}" | tee "${RES_DIR}/ldm_benchmark_trad.txt"
echo "######## [ldm_benchmark] LDM-optimized ########"
"${DIR}/ldm_benchmark" --ldm --iterations 100 --size "${SIZE_MB}" | tee "${RES_DIR}/ldm_benchmark_ldm.txt"

# 2) CSV-producing suites
run_one api_bench        "${DIR}/ldm_api_bench"
run_one residency_bench  "${DIR}/ldm_residency_bench"
run_one enterprise_bench "${DIR}/ldm_enterprise_bench"
run_one ai_bench         "${DIR}/ldm_ai_bench"
run_one ai_fullchain     "${DIR}/ldm_ai_fullchain"
run_one bench_v2         "${DIR}/ldm_bench_v2"
run_one bench_v3         "${DIR}/ldm_bench_v3"

echo ""
echo "==================== SUMMARY (MB/s) ===================="
python3 - "${RES_DIR}" <<'PYEOF'
import csv, os, sys
from pathlib import Path
res = Path(sys.argv[1])
def load(mode):
    d = {}
    for p in sorted(res.glob(f"*_{mode}.csv")):
        name = p.name.replace(f"_{mode}.csv", "")
        d[name] = {}
        with open(p) as f:
            for row in csv.DictReader(f):
                try:
                    d[name][row['test']] = float(row['throughput_mbps'])
                except (KeyError, ValueError):
                    pass
    return d
trad, ldm = load("trad"), load("ldm")
rows = []
for suite in sorted(set(trad) | set(ldm)):
    for t in sorted(set(trad.get(suite,{})) | set(ldm.get(suite,{}))):
        ta = trad.get(suite,{}).get(t)
        la = ldm.get(suite,{}).get(t)
        if ta and la:
            delta = (la - ta) / ta * 100
            rows.append((suite, t, ta, la, delta))
print(f"{'suite':<18}{'test':<32}{'trad(MB/s)':>12}{'ldm(MB/s)':>12}{'delta%':>9}")
for suite, t, ta, la, delta in rows:
    print(f"{suite:<18}{t:<32}{ta:>12.1f}{la:>12.1f}{delta:>+8.1f}")
print(f"\nTotal rows: {len(rows)}")
PYEOF
echo ""
echo "All benchmarks completed. Results in ${RES_DIR}/"