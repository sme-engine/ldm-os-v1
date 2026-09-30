#!/bin/bash
# =============================================================================
# 05_run_benchmarks.sh — LDM-OS aarch64 adaptation: build & run all benchmarks
#
# Compiles the 8 user-space benchmark suites and runs every one in BOTH
# "traditional" and LDM-optimized modes for N rounds (default 50). Results
# land in a dedicated directory (default /root/bench-results) so the repo's
# reference data under benchmarks/aarch64_results is never overwritten.
#
# Suites: classic(8-test) / api / residency / enterprise / ai / ai_fullchain
#         / bench_v2 / bench_v3
#
# Usage: ./05_run_benchmarks.sh [--rounds N] [--size-mb MB] [--skip-build]
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

ROUNDS="${ROUNDS:-50}"
SIZE_MB="${SIZE_MB:-64}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BENCH_DIR="${BENCH_DIR:-${REPO_ROOT}/benchmarks}"

step "LDM-OS AArch64 benchmark run"
echo "  Bench dir : ${BENCH_DIR}"
echo "  Rounds    : ${ROUNDS} per mode x 2 modes"
echo "  Size(MB)  : ${SIZE_MB}"
echo "  Results   : ${BENCH_RESULTS}"
echo ""
mkdir -p "${BENCH_RESULTS}"

set -- --rounds "${ROUNDS}" --output

# ---- Build ------------------------------------------------------------------
if [ "${SKIP_BUILD}" != "1" ]; then
    info "Compiling benchmark suites..."
    ( cd "${BENCH_DIR}" && \
      gcc -O2 -Wall -o ldm_benchmark         ldm_benchmark.c        -lpthread -lrt && \
      gcc -O2 -Wall -o ldm_bench_v2          ldm_benchmark_v2.c     -lpthread -lrt && \
      gcc -O2 -Wall -o ldm_bench_v3          ldm_benchmark_v3.c     -lpthread -lrt && \
      gcc -O2 -Wall -o ldm_api_bench         ldm_api_benchmark.c    -lpthread -lrt && \
      gcc -O2 -Wall -o ldm_residency_bench   ldm_residency_bench.c  -lpthread -lrt && \
      gcc -O2 -Wall -o ldm_enterprise_bench  ldm_enterprise_bench.c -lpthread -lrt && \
      gcc -O2 -Wall -o ldm_ai_bench          ldm_ai_benchmark.c     -lpthread -lrt -lm && \
      gcc -O2 -Wall -o ldm_ai_fullchain      ldm_ai_fullchain.c     -lpthread -lrt -lm )
    ok "Build finished"
fi

run_suite() {
    local name="$1" bin="$2" extra="${3:-}"
    local trad="${BENCH_RESULTS}/${name}_trad.csv" ldm="${BENCH_RESULTS}/${name}_ldm.csv"
    echo ""
    echo "######## [${name}] traditional (${ROUNDS} rounds) ########"
    "${BENCH_DIR}/${bin}" --rounds "${ROUNDS}" --output "${trad}" ${extra} >/dev/null 2>&1 \
      || { err "[FAIL] ${name} traditional"; return 1; }
    echo "######## [${name}] LDM-optimized (${ROUNDS} rounds) ########"
    "${BENCH_DIR}/${bin}" --ldm --rounds "${ROUNDS}" --output "${ldm}" ${extra} >/dev/null 2>&1 \
      || { err "[FAIL] ${name} ldm"; return 1; }
    ok "${name} -> ${trad} + ${ldm}"
}

# Classic 8-test suite: no CSV, capture stdout
echo "######## [classic] traditional ########"
"${BENCH_DIR}/ldm_benchmark" --iterations 100 --size "${SIZE_MB}" \
    > "${BENCH_RESULTS}/ldm_benchmark_trad.txt" 2>&1
echo "######## [classic] LDM-optimized ########"
"${BENCH_DIR}/ldm_benchmark" --ldm --iterations 100 --size "${SIZE_MB}" \
    > "${BENCH_RESULTS}/ldm_benchmark_ldm.txt" 2>&1

run_suite api_bench       ldm_api_bench
run_suite residency_bench ldm_residency_bench
run_suite enterprise_bench ldm_enterprise_bench
run_suite ai_bench        ldm_ai_bench
run_suite ai_fullchain    ldm_ai_fullchain
run_suite bench_v2        ldm_bench_v2
run_suite bench_v3        ldm_bench_v3

echo ""
ok "All benchmark runs completed. Data in ${BENCH_RESULTS}"
echo "Next: generate the aggregate report (summary step of run_all or manual aggregation)."