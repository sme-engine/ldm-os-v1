#!/bin/bash
# =============================================================================
# 04_run_qemu_verify.sh — LDM-OS aarch64 adaptation: boot under QEMU + verify
#
# Boots the built arm64 kernel + initramfs in an emulated "virt" machine and
# runs the in-guest OS-level validation suite (test_os_safe.sh, 53 checks).
# The guest prints "ALL TESTS PASSED - LDM-OS FULLY COMPATIBLE" then powers
# itself off via sysrq.
#
#   - No /dev/kvm in containerized Kunpeng environments → TCG by default
#     (override with QEMU_ACCEL=kvm if /dev/kvm exists).
#   - `timeout` guards against a hang; on timeout we report FAIL.
#
# Usage: ./04_run_qemu_verify.sh [logfile]
#   Default log: /root/ldm-qemu-verify.log
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

LOG="${1:-/root/ldm-qemu-verify.log}"

step "LDM-OS AArch64 QEMU verification"
echo "  Kernel    : ${KERNEL_IMAGE}"
echo "  Initramfs : ${INITRAMFS_OUT}"
echo "  QEMU      : ${QEMU_BIN} (-M virt, accel=${QEMU_ACCEL}, cpu=${QEMU_CPU})"
echo "  Mem/SMP   : ${QEMU_MEM}M / ${QEMU_SMP} vCPU"
echo "  Timeout   : ${QEMU_TIMEOUT}s"
echo "  Log       : ${LOG}"
echo ""

[ -f "${KERNEL_IMAGE}" ]   || { err "kernel Image not found: ${KERNEL_IMAGE}"; exit 1; }
[ -f "${INITRAMFS_OUT}" ]  || { err "initramfs not found: ${INITRAMFS_OUT}"; exit 1; }

QEMU_ARGS=( -M virt -accel "${QEMU_ACCEL}" -cpu "${QEMU_CPU}" \
            -m "${QEMU_MEM}" -smp "${QEMU_SMP}" \
            -kernel "${KERNEL_IMAGE}" \
            -initrd "${INITRAMFS_OUT}" \
            -append "console=ttyAMA0 rdinit=/init panic=-1" \
            -nographic -no-reboot )

info "Starting QEMU (console captured to ${LOG})..."
set +e
timeout "${QEMU_TIMEOUT}"s "${QEMU_BIN}" "${QEMU_ARGS[@]}" > "${LOG}" 2>&1
QRC=$?
set -e

echo ""
if [ "${QRC}" -eq 124 ]; then
    err "QEMU timed out after ${QEMU_TIMEOUT}s (guest did not power off — likely hang)."
    err "Tail of log:"; tail -30 "${LOG}"
    exit 1
fi
if [ "${QRC}" -ne 0 ] && [ "${QRC}" -ne 1 ]; then
    err "QEMU exited with code ${QRC}."
    tail -30 "${LOG}"
    exit "${QRC}"
fi

echo "---- Guest console (boot banner) ----"
grep -E "Booting Linux|Linux version|LDM-OS|ldm" "${LOG}" | head -15 || true
echo "---- Validation summary ----"
grep -E "\[ *[0-9]+\]|PASS=|ALL TESTS PASSED|TEST_OS_SAFE_EXIT|FAIL" "${LOG}" | tail -70 || true

PASS_CNT=$(grep -c "PASS" "${LOG}" || true)
FAIL_CNT=$(grep -c "FAIL" "${LOG}" || true)
# Prefer the authoritative "RESULTS:  N PASS  M FAIL" summary over raw greps
# (the summary line itself contains the words PASS/FAIL and skews counts).
RESULT_LINE="$(grep -E "RESULTS:" "${LOG}" | head -1 || true)"
if [ -n "${RESULT_LINE}" ]; then
    PASS_CNT="$(echo "${RESULT_LINE}" | sed -nE 's/.*RESULTS:[^0-9]*([0-9]+)[[:space:]]+PASS.*/\1/p' | head -1)"
    FAIL_CNT="$(echo "${RESULT_LINE}" | sed -nE 's/.*[[:space:]]([0-9]+)[[:space:]]+FAIL.*/\1/p' | head -1)"
    [ -z "${PASS_CNT}" ] && PASS_CNT=$(grep -c "PASS" "${LOG}" || true)
    [ -z "${FAIL_CNT}" ] && FAIL_CNT=$(grep -c "FAIL" "${LOG}" || true)
fi
if grep -q "ALL TESTS PASSED - LDM-OS FULLY COMPATIBLE" "${LOG}"; then
    ok "GUEST VALIDATION PASSED (PASS=${PASS_CNT} FAIL=${FAIL_CNT})"
    exit 0
else
    err "Guest validation did not report full success (PASS=${PASS_CNT} FAIL=${FAIL_CNT})"
    exit 1
fi