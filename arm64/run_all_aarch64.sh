#!/bin/bash
# =============================================================================
# run_all_aarch64.sh — one-shot LDM-OS aarch64 / Kunpeng 920 adaptation flow
#
#   1. 01_check_env.sh          prerequisite check
#   2. 02_build_kernel.sh       build arm64 kernel Image (skips if exists)
#   3. 03_build_initramfs.sh    assemble bootable initramfs
#   4. 04_run_qemu_verify.sh    boot under QEMU, run 53-check OS validation
#   5. 05_run_benchmarks.sh     build + run 8 benchmark suites (trad+ldm)
#   6. 06_aggregate_report.sh   produce aggregated.csv + report
#
# Any step can be run individually; environment overrides are documented in
# arm64/common.sh and in each script header.
#
# Quick skip flags:
#   SKIP_KERNEL=1      reuse existing ${KERNEL_IMAGE}
#   SKIP_BENCH=1       stop after QEMU guest validation
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

step "LDM-OS AArch64 / Kunpeng 920 adaptation — full flow"
echo "  Repo     : ${REPO_ROOT}"
echo "  Kernel   : ${KERNEL_IMAGE}"
echo "  Initramfs: ${INITRAMFS_OUT}"
echo "  Bench    : ${BENCH_RESULTS}"
echo ""

"${SCRIPT_DIR}/01_check_env.sh"

if [ -f "${KERNEL_IMAGE}" ]; then
    if [ "${SKIP_KERNEL:-0}" = "1" ]; then
        warn "SKIP_KERNEL=1 — reusing ${KERNEL_IMAGE}"
    else
        info "Kernel Image exists — reuse (set SKIP_KERNEL=1 to skip check)"
    fi
else
    "${SCRIPT_DIR}/02_build_kernel.sh"
fi

"${SCRIPT_DIR}/03_build_initramfs.sh"

"${SCRIPT_DIR}/04_run_qemu_verify.sh" /root/ldm-qemu-verify.log

if [ "${SKIP_BENCH:-0}" = "1" ]; then
    warn "SKIP_BENCH=1 — benchmarks not run"
    exit 0
fi

"${SCRIPT_DIR}/05_run_benchmarks.sh" --rounds "${ROUNDS:-50}"
"${SCRIPT_DIR}/06_aggregate_report.sh"

ok "Full aarch64 adaptation flow completed."
echo "  QEMU guest log  : /root/ldm-qemu-verify.log"
echo "  Benchmark data  : ${BENCH_RESULTS}"
echo "  Aggregate report: ${BENCH_RESULTS}/aggregated_report.md"