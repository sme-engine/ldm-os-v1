#!/bin/bash
# =============================================================================
# Alpine UML Launch & Debug Script
#
# Modes:
#   ./run_uml.sh boot          — Boot and run init, exit after init completes
#   ./run_uml.sh shell         — Boot into interactive debug shell
#   ./run_uml.sh gdb           — Boot under GDB for source-level debugging
#   ./run_uml.sh test          — Quick boot test (timeout 15s)
#
# Environment variables:
#   UML_MEM        Memory size (default: 256M)
#   UML_ROOTFS     Path to rootfs cpio.gz (default: output/alpine-uml-rootfs.cpio.gz)
#   UML_KERNEL     Path to UML kernel (default: output/linux.uml)
#   UML_EXTRA_ARGS Extra kernel command line arguments
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
source "${WORKSPACE}/toolchain/env.sh"

MODE="${1:-test}"
UML_MEM="${UML_MEM:-256M}"
UML_KERNEL="${UML_KERNEL:-${WORKSPACE}/output/linux.uml}"
UML_ROOTFS="${UML_ROOTFS:-${WORKSPACE}/output/alpine-uml-rootfs.cpio.gz}"
UML_EXTRA_ARGS="${UML_EXTRA_ARGS:-}"

if [ ! -f "${UML_KERNEL}" ]; then
    echo "[ERROR] UML kernel not found: ${UML_KERNEL}"
    echo "Run: bash scripts/build_uml_kernel.sh"
    exit 1
fi

if [ ! -f "${UML_ROOTFS}" ]; then
    echo "[ERROR] Rootfs not found: ${UML_ROOTFS}"
    echo "Run: bash scripts/build_rootfs.sh"
    exit 1
fi

echo "[UML] ============================================"
echo "[UML] Alpine UML Launch"
echo "[UML] ============================================"
echo "[UML] Mode:    ${MODE}"
echo "[UML] Kernel:  ${UML_KERNEL} ($(du -h "${UML_KERNEL}" | cut -f1))"
echo "[UML] Rootfs:  ${UML_ROOTFS} ($(du -h "${UML_ROOTFS}" | cut -f1))"
echo "[UML] Memory:  ${UML_MEM}"
echo "[UML] ============================================"

COMMON_ARGS=(
    "mem=${UML_MEM}"
    "initrd=${UML_ROOTFS}"
    "root=/dev/ram0"
    "rw"
    "console=tty0"
    "earlyprintk"
    "loglevel=8"
    "debug"
    "panic=0"
    "oops=panic"
    "slub_debug=FZPU"
    "initcall_debug"
    "${UML_EXTRA_ARGS}"
)

case "${MODE}" in
    boot)
        echo "[UML] Booting with full init..."
        "${UML_KERNEL}" "${COMMON_ARGS[@]}" < /dev/null
        ;;
    shell)
        echo "[UML] Booting into debug shell..."
        "${UML_KERNEL}" "${COMMON_ARGS[@]}" "init=/bin/sh"
        ;;
    gdb)
        echo "[UML] Starting under GDB..."
        echo "[UML] Tips:"
        echo "  (gdb) break start_kernel"
        echo "  (gdb) continue"
        echo "  (gdb) info threads"
        echo "  (gdb) bt"
        echo ""
        gdb --args "${UML_KERNEL}" "${COMMON_ARGS[@]}" "init=/bin/sh"
        ;;
    test)
        echo "[UML] Quick boot test (15s timeout)..."
        timeout 15 "${UML_KERNEL}" "${COMMON_ARGS[@]}" "init=/bin/sh" "-c" \
            'echo "=== UML BOOT TEST ==="; uname -a; cat /proc/version; echo "=== DEBUG FS ==="; ls /sys/kernel/debug/ 2>/dev/null | head -10; echo "=== KALLSYMS ==="; wc -l /proc/kallsyms; echo "=== SLUB DEBUG ==="; cat /proc/slabinfo 2>/dev/null | head -5; echo "=== LOCKDEP ==="; cat /proc/lock_stat 2>/dev/null | head -5; echo "=== FTRACE ==="; cat /sys/kernel/tracing/available_filter_functions 2>/dev/null | wc -l; echo "=== MEMORY ==="; free; echo "=== TEST PASSED ==="; poweroff -f' \
            < /dev/null 2>&1
        EXIT_CODE=$?
        if [ ${EXIT_CODE} -eq 0 ] || [ ${EXIT_CODE} -eq 124 ]; then
            echo ""
            echo "[UML] === BOOT TEST SUCCESS ==="
        else
            echo ""
            echo "[UML] === BOOT TEST FAILED (exit=${EXIT_CODE}) ==="
        fi
        ;;
    *)
        echo "Usage: $0 {boot|shell|gdb|test}"
        exit 1
        ;;
esac
