#!/bin/bash
# =============================================================================
# LDM-OS One-Click Build & Boot Tool
#
# Usage:
#   ./ldm-build.sh              # Build + boot (default)
#   ./ldm-build.sh build        # Build only
#   ./ldm-build.sh boot         # Boot only (requires prior build)
#   ./ldm-build.sh test         # Build + boot + run verification tests
#   ./ldm-build.sh clean        # Clean build artifacts
#   ./ldm-build.sh shell        # Boot into interactive debug shell
#
# Environment overrides:
#   JOBS=N          Parallel build jobs (default: nproc or 8)
#   UML_MEM=256M    Guest memory (default: 128M)
#   SKIP_CONFIG=1   Skip kernel config regeneration
#   VERBOSE=1       Enable verbose build output
#
# Copyright (C) 2026 LDM-OS Project
# =============================================================================

set -euo pipefail

# ---- Resolve paths --------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}"
KERNEL_SRC="${WORKSPACE}/src/linux"
OUTPUT_DIR="${WORKSPACE}/output"
ROOTFS_DIR="${WORKSPACE}/rootfs"
LOG_DIR="${WORKSPACE}/logs"
SCRIPTS_DIR="${WORKSPACE}/scripts"

# If kernel-src is a symlink, resolve it
if [ -L "${KERNEL_SRC}" ]; then
    KERNEL_SRC="$(readlink -f "${KERNEL_SRC}")"
fi

# Fallback: if src/linux doesn't exist, try top-level (deploy layout)
if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
    if [ -f "${WORKSPACE}/Makefile" ]; then
        KERNEL_SRC="${WORKSPACE}"
    elif [ -f "${WORKSPACE}/kernel-src/Makefile" ]; then
        KERNEL_SRC="${WORKSPACE}/kernel-src"
    else
        echo "[ERROR] Cannot find kernel source. Expected at:"
        echo "  ${WORKSPACE}/src/linux/"
        echo "  ${WORKSPACE}/kernel-src/"
        echo "  ${WORKSPACE}/ (top-level)"
        exit 1
    fi
fi

# ---- Toolchain setup ------------------------------------------------------
TOOLCHAIN_ROOT="/tmp/qemu_extract"
export PATH="${TOOLCHAIN_ROOT}/usr/bin:${TOOLCHAIN_ROOT}/bin:${PATH}"
export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib64:${TOOLCHAIN_ROOT}/lib64:/lib64:/usr/lib64"
export C_INCLUDE_PATH="${TOOLCHAIN_ROOT}/usr/include:/usr/include"
export LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib64:/usr/lib64"
export M4="${TOOLCHAIN_ROOT}/usr/bin/m4"
export BISON_PKGDATADIR="${TOOLCHAIN_ROOT}/usr/share/bison"

# Verify toolchain
for tool in gcc make flex bison bc m4; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[ERROR] Required tool not found: $tool"
        echo "Ensure RPM-extracted toolchain is at ${TOOLCHAIN_ROOT}"
        exit 1
    fi
done

# ---- Parameters -----------------------------------------------------------
MODE="${1:-all}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"
UML_MEM="${UML_MEM:-128M}"
SKIP_CONFIG="${SKIP_CONFIG:-0}"
VERBOSE="${VERBOSE:-0}"
V_FLAG=""
[ "${VERBOSE}" = "1" ] && V_FLAG="V=1"

UML_KERNEL="${OUTPUT_DIR}/linux.uml"
UML_ROOTFS_CPIO="${OUTPUT_DIR}/alpine-uml-rootfs.cpio.gz"
BUILD_LOG="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

# ---- Functions ------------------------------------------------------------

banner() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║   LDM-OS Build System                   ║"
    echo "║   Low Data Movement Operating System     ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "  Mode:    ${MODE}"
    echo "  Kernel:  ${KERNEL_SRC}"
    echo "  Output:  ${OUTPUT_DIR}"
    echo "  Jobs:    ${JOBS}"
    echo "  Memory:  ${UML_MEM}"
    echo "  Log:     ${BUILD_LOG}"
    echo ""
}

do_config() {
    echo "[CONFIG] Generating UML debug kernel configuration..."
    cd "${KERNEL_SRC}"

    if [ -f "${SCRIPTS_DIR}/generate_uml_debug_config.sh" ]; then
        bash "${SCRIPTS_DIR}/generate_uml_debug_config.sh" 2>&1 | tee -a "${BUILD_LOG}"
    else
        # Inline config: start from UML defconfig + LDM options
        make ARCH=um x86_64_defconfig 2>&1 | tee -a "${BUILD_LOG}"

        # Enable LDM and debug options
        cat >> .config << 'LDMCFG'
CONFIG_LDM_OS=y
CONFIG_LDM_OS_DEBUG=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_KERNEL=y
CONFIG_FRAME_POINTER=y
CONFIG_KALLSYMS_ALL=y
CONFIG_GDB_SCRIPTS=y
CONFIG_DEBUG_LOCK_ALLOC=y
CONFIG_SLUB_DEBUG=y
CONFIG_DYNAMIC_DEBUG=y
CONFIG_FTRACE=y
CONFIG_STACKTRACE=y
CONFIG_SCHED_DEBUG=y
CONFIG_LATENCYTOP=y
CONFIG_DEBUG_OBJECTS=y
CONFIG_MAGIC_SYSRQ=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_HOSTFS=y
CONFIG_MCONSOLE=y
CONFIG_EARLY_PRINTK=y
CONFIG_PRINTK_TIME=y
CONFIG_SECURITY=y
CONFIG_AUDIT=y
LDMCFG
        # Disable options that cause early-boot panic on UML+GCC8
        sed -i 's/^CONFIG_PROVE_LOCKING=y/# CONFIG_PROVE_LOCKING is not set/' .config
        sed -i 's/^CONFIG_DEBUG_LOCKDEP=y/# CONFIG_DEBUG_LOCKDEP is not set/' .config
        sed -i 's/^CONFIG_PROVE_RAW_LOCK_NESTING=y/# CONFIG_PROVE_RAW_LOCK_NESTING is not set/' .config
        sed -i 's/^CONFIG_DEBUG_PAGEALLOC=y/# CONFIG_DEBUG_PAGEALLOC is not set/' .config

        make ARCH=um M4="$M4" BISON_PKGDATADIR="$BISON_PKGDATADIR" olddefconfig 2>&1 | tee -a "${BUILD_LOG}"
    fi

    # Verify LDM enabled
    if ! grep -q "^CONFIG_LDM_OS=y" .config; then
        echo "[ERROR] CONFIG_LDM_OS not enabled in .config!"
        exit 1
    fi
    echo "[CONFIG] ✓ LDM-OS configuration ready"
}

do_build() {
    echo "[BUILD] Compiling LDM-OS UML kernel (-j${JOBS})..."
    echo "[BUILD] Start: $(date '+%Y-%m-%d %H:%M:%S')"
    cd "${KERNEL_SRC}"

    make ARCH=um \
         M4="$M4" \
         BISON_PKGDATADIR="$BISON_PKGDATADIR" \
         -j"${JOBS}" \
         ${V_FLAG} \
         2>&1 | tee -a "${BUILD_LOG}"

    BUILD_EXIT=${PIPESTATUS[0]}
    echo "[BUILD] End: $(date '+%Y-%m-%d %H:%M:%S')"

    if [ ${BUILD_EXIT} -ne 0 ]; then
        echo "[ERROR] Kernel build failed! Check log: ${BUILD_LOG}"
        exit ${BUILD_EXIT}
    fi

    # Copy artifacts
    cp linux "${UML_KERNEL}"
    cp System.map "${OUTPUT_DIR}/System.map" 2>/dev/null || true
    cp .config "${OUTPUT_DIR}/.config" 2>/dev/null || true

    echo "[BUILD] ✓ Kernel built successfully"
    echo "[BUILD]   Binary: ${UML_KERNEL} ($(du -h "${UML_KERNEL}" | cut -f1))"
    echo "[BUILD]   Symbols: $(wc -l < "${OUTPUT_DIR}/System.map" 2>/dev/null || echo N/A)"
    echo "[BUILD]   LDM symbols: $(grep -c ldm_ "${OUTPUT_DIR}/System.map" 2>/dev/null || echo N/A)"
}

do_rootfs() {
    echo "[ROOTFS] Building Alpine rootfs..."

    if [ -f "${SCRIPTS_DIR}/build_rootfs.sh" ]; then
        bash "${SCRIPTS_DIR}/build_rootfs.sh" 2>&1 | tee -a "${BUILD_LOG}"
    else
        echo "[ROOTFS] Using existing rootfs at ${ROOTFS_DIR}"
    fi

    if [ ! -d "${ROOTFS_DIR}" ]; then
        echo "[ERROR] Rootfs directory not found: ${ROOTFS_DIR}"
        exit 1
    fi
    echo "[ROOTFS] ✓ Rootfs ready"
}

do_boot() {
    if [ ! -f "${UML_KERNEL}" ]; then
        echo "[ERROR] UML kernel not found: ${UML_KERNEL}"
        echo "Run '${0} build' first."
        exit 1
    fi

    local INIT_CMD="${1:-/etc/init.d/rc.sysinit}"

    echo "[BOOT] Starting LDM-OS UML..."
    echo "[BOOT]   Kernel: ${UML_KERNEL}"
    echo "[BOOT]   Rootfs: ${ROOTFS_DIR} (hostfs)"
    echo "[BOOT]   Memory: ${UML_MEM}"
    echo "[BOOT]   Init:   ${INIT_CMD}"
    echo ""

    "${UML_KERNEL}" \
        mem="${UML_MEM}" \
        rootfstype=hostfs \
        rootflags="${ROOTFS_DIR}" \
        rw \
        console=tty0 \
        loglevel=7 \
        init="${INIT_CMD}"
}

do_test() {
    if [ ! -f "${UML_KERNEL}" ]; then
        echo "[ERROR] UML kernel not found. Build first."
        exit 1
    fi

    # Create inline test script
    local TEST_SCRIPT="${ROOTFS_DIR}/.ldm_quick_test.sh"
    cat > "${TEST_SCRIPT}" << 'TESTEOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
PASS=0; FAIL=0
check() { [ "$1" = "0" ] && { echo "[PASS] $2"; PASS=$((PASS+1)); } || { echo "[FAIL] $2"; FAIL=$((FAIL+1)); }; }
echo "=== LDM-OS Quick Verification ==="
KVER=$(uname -r); [ -n "$KVER" ] && check 0 "Kernel: $KVER" || check 1 "Kernel"
zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_LDM_OS=y" && check 0 "CONFIG_LDM_OS=y" || check 1 "CONFIG_LDM_OS"
LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
[ "$LDM_SYMS" -gt 100 ] && check 0 "LDM symbols: $LDM_SYMS" || check 1 "LDM symbols"
[ -f /sys/kernel/debug/ldm_os/stats ] && check 0 "debugfs stats" || check 1 "debugfs stats"
[ -f /sys/kernel/debug/deep_hooks_stats ] && check 0 "deep hooks stats" || check 1 "deep hooks"
MEM=$(free 2>/dev/null | awk '/Mem:/{print $2}')
[ "$MEM" -gt 50000 ] && check 0 "Memory: ${MEM}kB" || check 1 "Memory"
echo ""; echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "LDM-OS FULLY OPERATIONAL" || echo "ISSUES DETECTED"
poweroff -f 2>/dev/null
TESTEOF
    chmod +x "${TEST_SCRIPT}"

    echo "[TEST] Running verification tests..."
    timeout 20 "${UML_KERNEL}" \
        mem="${UML_MEM}" \
        rootfstype=hostfs \
        rootflags="${ROOTFS_DIR}" \
        rw console=tty0 loglevel=4 \
        init="/.ldm_quick_test.sh" \
        < /dev/null 2>&1 | grep -v "^Core\|^Check\|^Adding\|^remove_umid\|soft.*NONE\|hard.*NONE"

    rm -f "${TEST_SCRIPT}"
}

do_clean() {
    echo "[CLEAN] Removing build artifacts..."
    cd "${KERNEL_SRC}"
    make ARCH=um clean 2>/dev/null || true
    rm -f "${OUTPUT_DIR}/linux.uml" "${OUTPUT_DIR}/System.map" "${OUTPUT_DIR}/.config"
    echo "[CLEAN] ✓ Done"
}

# ---- Main -----------------------------------------------------------------

banner

case "${MODE}" in
    all|build-and-boot)
        [ "${SKIP_CONFIG}" = "0" ] && do_config
        do_build
        do_rootfs
        do_boot
        ;;
    build)
        [ "${SKIP_CONFIG}" = "0" ] && do_config
        do_build
        do_rootfs
        echo ""
        echo "[DONE] Build complete. Run '${0} boot' to start UML."
        ;;
    boot)
        do_boot "/etc/init.d/rc.sysinit"
        ;;
    shell)
        do_boot "/bin/sh"
        ;;
    test)
        [ "${SKIP_CONFIG}" = "0" ] && do_config
        do_build
        do_rootfs
        do_test
        ;;
    clean)
        do_clean
        ;;
    *)
        echo "Usage: $0 {all|build|boot|shell|test|clean}"
        echo ""
        echo "  all     Build kernel + rootfs, then boot (default)"
        echo "  build   Build kernel + rootfs only"
        echo "  boot    Boot existing build with LDM init"
        echo "  shell   Boot into interactive debug shell"
        echo "  test    Build + run automated verification"
        echo "  clean   Remove build artifacts"
        exit 1
        ;;
esac
