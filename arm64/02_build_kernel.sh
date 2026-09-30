#!/bin/bash
# =============================================================================
# 02_build_kernel.sh — LDM-OS aarch64 adaptation: build arm64 kernel Image
#
# Builds the LDM-modified Linux kernel (kernel-src) for arm64 using an
# out-of-tree object directory so the source tree stays clean.
#
#   - Native aarch64 host: builds with host gcc (no cross toolchain needed).
#   - x86_64 cross-build host: set CROSS_COMPILE=aarch64-linux-gnu- .
#   - If ${KERNEL_OUT}/.config exists it is reused (recommended: keeps the
#     proven QEMU/initramfs config). Otherwise defconfig + required options.
#
# Output: ${KERNEL_IMAGE}  (arch/arm64/boot/Image)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

JOBS="${JOBS:-$(nproc)}"
CROSS_COMPILE="${CROSS_COMPILE:-}"

step "LDM-OS AArch64 kernel build"
echo "  Source : ${KERNEL_SRC}"
echo "  Output : ${KERNEL_OUT}"
echo "  Jobs   : ${JOBS}"
echo "  Cross  : ${CROSS_COMPILE:-<native>}"
echo ""

[ -d "${KERNEL_SRC}" ] || { err "kernel source missing: ${KERNEL_SRC}"; exit 1; }

mkdir -p "${KERNEL_OUT}"

if [ ! -f "${KERNEL_OUT}/.config" ]; then
    info "No existing .config — generating defconfig + required options"
    make -C "${KERNEL_SRC}" O="${KERNEL_OUT}" ARCH=arm64 \
         CROSS_COMPILE="${CROSS_COMPILE}" defconfig
    # Options needed for the initramfs-driven QEMU boot + LDM debugfs.
    "${KERNEL_SRC}/scripts/config" --file "${KERNEL_OUT}/.config" \
        -e BLK_DEV_INITRD -e DEVTMPFS -e DEVTMPFS_MOUNT -e PROC_FS -e SYSFS \
        -e DEBUG_FS -e TMPFS -e POSIX_TIMERS -e PROC_SYSCTL \
        -e FRAME_POINTER -d DEBUG_INFO -d RANDOMIZE_BASE
    make -C "${KERNEL_SRC}" O="${KERNEL_OUT}" ARCH=arm64 \
         CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
else
    info "Reusing existing ${KERNEL_OUT}/.config"
fi

info "Building Image (this takes a while)..."
make -C "${KERNEL_SRC}" O="${KERNEL_OUT}" ARCH=arm64 \
     CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}" Image

if [ -f "${KERNEL_IMAGE}" ]; then
    info "Generated: $(ls -la "${KERNEL_IMAGE}" | awk '{print $5" bytes"}') ${KERNEL_IMAGE}"
    # Sanity: guest kernel must be arm64.
    if file "${KERNEL_IMAGE}" | awk 'tolower($0) ~ /arm64|aarch64/{found=1} END{exit !found}'; then
        ok "Kernel Image is arm64"
    else
        warn "Kernel Image architecture check inconclusive"
    fi
    exit 0
fi

err "Kernel Image not produced: ${KERNEL_IMAGE}"
exit 1