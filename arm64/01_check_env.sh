#!/bin/bash
# =============================================================================
# 01_check_env.sh — LDM-OS aarch64 adaptation: prerequisite check
#
# Verifies that the host is arm64/aarch64 (Kunpeng 920) and that all tools
# needed for kernel build, initramfs assembly and QEMU verification exist.
# Exit code 0 on success, 1 with a summary of missing items.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

step "LDM-OS AArch64 adaptation — environment check"
echo "  Date     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Host     : $(uname -m) / Linux $(uname -r)"
echo "  CPUs     : $(nproc)"
echo "  QEMU     : ${QEMU_BIN}"
echo ""

RC=0

echo "--- [1/5] Architecture (require arm64/aarch64) ---"
if is_aarch64; then
    ok "host arch = $(uname -m) (Kunpeng/aarch64 OK)"
    lscpu 2>/dev/null | grep -iE "Model name|CPU part" | head -2 || true
else
    err "host arch = $(uname -m); this flow targets arm64/aarch64 (Kunpeng 920)"
    RC=1
fi

echo "--- [2/5] Kernel build tools ---"
if require_cmd gcc make bc bison flex; then ok "gcc/make/bc/bison/flex present"; else err "kernel build tool missing"; RC=1; fi
if [ -d "${KERNEL_SRC}" ]; then
    ok "kernel source: ${KERNEL_SRC}"
else
    err "kernel source not found: ${KERNEL_SRC} (set KERNEL_SRC=...)"
    RC=1
fi

echo "--- [3/5] Initramfs ingredients ---"
if is_elf_aarch64 "${BUSYBOX_BIN}"; then ok "busybox (aarch64): ${BUSYBOX_BIN}"; else err "busybox missing or not aarch64: ${BUSYBOX_BIN}"; RC=1; fi
if is_elf_aarch64 "${DD_BIN}"; then ok "dd (aarch64): ${DD_BIN}"; else err "dd missing or not aarch64: ${DD_BIN}"; RC=1; fi
ld="$(resolve_lib ld-linux-aarch64.so.1)"
if [ -n "$ld" ]; then ok "glibc loader: $ld"; else err "ld-linux-aarch64.so.1 not found in GLIBC_SEARCH_PATH"; RC=1; fi
if require_cmd cpio readelf file; then ok "cpio/readelf/file present"; else err "packaging tool missing"; RC=1; fi

echo "--- [4/5] QEMU aarch64 ---"
if [ -x "${QEMU_BIN}" ] || command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    ok "qemu: ${QEMU_BIN} ($("${QEMU_BIN}" --version | head -1))"
    if "${QEMU_BIN}" -machine help 2>/dev/null | awk '/^virt/{found=1} END{exit !found}'; then
        ok "machine 'virt' supported"
    else
        warn "machine 'virt' not advertised (will still attempt boot)"
    fi
    if [ -e /dev/kvm ]; then ok "/dev/kvm present — KVM acceleration available"; else warn "no /dev/kvm — using TCG (QEMU_ACCEL=${QEMU_ACCEL})"; fi
else
    err "qemu not found: ${QEMU_BIN} (set QEMU_BIN=...)"
    RC=1
fi

echo "--- [5/5] Benchmark prerequisites ---"
if require_cmd gcc python3; then ok "gcc/python3 present for benchmark build/aggregation"; else err "benchmark prerequisite missing"; RC=1; fi

echo ""
if [ "${RC}" -eq 0 ]; then
    ok "All prerequisites satisfied — ready to run ./run_all_aarch64.sh"
else
    err "One or more prerequisites missing (see above)."
fi
exit "${RC}"