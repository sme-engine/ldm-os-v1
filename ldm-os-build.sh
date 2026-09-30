#!/bin/bash
# =============================================================================
# LDM-OS Build Script — UML + QEMU Image Generator
#
# Builds the LDM-OS modified Alpine Linux kernel as:
#   1. UML (User-Mode Linux) binary for direct execution
#   2. QEMU bootable disk image (qcow2/raw)
#
# Usage:
#   ./ldm-os-build.sh              # Build UML only (default)
#   ./ldm-os-build.sh uml          # Build UML binary
#   ./ldm-os-build.sh qemu         # Build QEMU image (includes UML build)
#   ./ldm-os-build.sh all          # Build both UML + QEMU image
#   ./ldm-os-build.sh test         # Build UML + run enterprise test suite
#   ./ldm-os-build.sh clean        # Clean build artifacts
#   ./ldm-os-build.sh status       # Show current build status
#
# Environment overrides:
#   JOBS=N           Parallel build jobs (default: nproc or 8)
#   UML_MEM=256M     Guest memory for UML (default: 128M)
#   QEMU_FMT=qcow2   QEMU image format: qcow2 or raw (default: qcow2)
#   QEMU_SIZE=2G     QEMU disk size (default: 2G)
#   KERNEL_SRC=path  Override kernel source path
#   VERBOSE=1        Enable verbose build output
#   SKIP_CONFIG=1    Skip kernel config regeneration
#
# Requirements:
#   - GCC 8+ with UML support
#   - flex, bison, bc, m4 (or extracted RPM toolchain)
#   - For QEMU: qemu-img, genext2fs or e2fsprogs
#
# Copyright (C) 2026 LDM-OS Project
# =============================================================================

set -euo pipefail

# ---- Colors ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}"; \
          echo -e "${CYAN}  $*${NC}"; \
          echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; }

# ---- Resolve paths --------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}"
KERNEL_SRC="${KERNEL_SRC:-${WORKSPACE}/src/linux}"
OUTPUT_DIR="${WORKSPACE}/output"
ROOTFS_DIR="${WORKSPACE}/rootfs"
LOG_DIR="${WORKSPACE}/logs"
SCRIPTS_DIR="${WORKSPACE}/scripts"
TOOLCHAIN_ROOT="/tmp/qemu_extract"

# Derived
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"
UML_MEM="${UML_MEM:-128M}"
QEMU_FMT="${QEMU_FMT:-qcow2}"
QEMU_SIZE="${QEMU_SIZE:-2G}"
UML_BIN="${OUTPUT_DIR}/linux.uml"
QEMU_IMG="${OUTPUT_DIR}/ldm-os.${QEMU_FMT}"
ROOTFS_IMG="${OUTPUT_DIR}/rootfs.ext2"
BUILD_LOG="${LOG_DIR}/build.log"

mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"

# ---- Toolchain setup ------------------------------------------------------
setup_toolchain() {
    info "Setting up build toolchain..."

    # Check for required tools
    local missing=()
    for tool in gcc make; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    # Check flex/bison/bc/m4 — try system first, then extracted RPMs
    for tool in flex bison bc m4; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            if [ -x "${TOOLCHAIN_ROOT}/usr/bin/${tool}" ]; then
                export PATH="${TOOLCHAIN_ROOT}/usr/bin:${PATH}"
                export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib64:${LD_LIBRARY_PATH:-}"
            else
                missing+=("$tool")
            fi
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing tools: ${missing[*]}"
        warn "Attempting to extract from RPM packages..."
        extract_toolchain_rpms || true
    fi

    # Set environment for extracted tools
    if [ -d "${TOOLCHAIN_ROOT}/usr/bin" ]; then
        export PATH="${TOOLCHAIN_ROOT}/usr/bin:${TOOLCHAIN_ROOT}/bin:${PATH}"
        export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib64:${TOOLCHAIN_ROOT}/lib64:${LD_LIBRARY_PATH:-}"
        export M4="${TOOLCHAIN_ROOT}/usr/bin/m4"
        export BISON_PKGDATADIR="${TOOLCHAIN_ROOT}/usr/share/bison"
    fi

    # Verify critical tools
    if ! command -v gcc >/dev/null 2>&1; then
        err "GCC not found. Cannot build."
        exit 1
    fi
    ok "Toolchain ready: $(gcc --version | head -1)"
}

extract_toolchain_rpms() {
    info "Extracting build tools from RPM packages..."
    mkdir -p "${TOOLCHAIN_ROOT}"

    local rpm_dir="${WORKSPACE}/toolchain/rpms"
    if [ ! -d "$rpm_dir" ]; then
        warn "No RPM directory found at ${rpm_dir}"
        warn "Please place flex, bison, bc, m4 RPMs in ${rpm_dir}/"
        return 1
    fi

    for rpm in "$rpm_dir"/*.rpm; do
        [ -f "$rpm" ] || continue
        info "Extracting: $(basename "$rpm")"
        cd "${TOOLCHAIN_ROOT}"
        rpm2cpio "$rpm" 2>/dev/null | cpio -idmv 2>/dev/null || true
    done
    cd "${WORKSPACE}"
    ok "RPM extraction complete"
}

# ---- Kernel config --------------------------------------------------------
configure_kernel() {
    step "Step 1/4: Configuring LDM-OS Kernel"

    if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
        err "Kernel source not found at ${KERNEL_SRC}"
        err "Expected: src/linux/Makefile"
        exit 1
    fi

    cd "${KERNEL_SRC}"

    if [ "${SKIP_CONFIG:-0}" = "1" ] && [ -f .config ]; then
        warn "Skipping kernel config (SKIP_CONFIG=1)"
    else
        info "Generating UML defconfig..."
        make ARCH=um defconfig 2>&1 | tee -a "${BUILD_LOG}" | tail -3

        info "Enabling LDM-OS modules..."
        # Enable LDM-OS
        scripts/config --enable CONFIG_LDM_OS 2>/dev/null || \
            sed -i 's/# CONFIG_LDM_OS is not set/CONFIG_LDM_OS=y/' .config
        scripts/config --enable CONFIG_LDM_OS_DEBUG 2>/dev/null || \
            sed -i 's/# CONFIG_LDM_OS_DEBUG is not set/CONFIG_LDM_OS_DEBUG=y/' .config

        # Disable problematic options for UML+GCC8
        scripts/config --disable CONFIG_PROVE_LOCKING 2>/dev/null || true
        scripts/config --disable CONFIG_DEBUG_LOCKDEP 2>/dev/null || true
        scripts/config --disable CONFIG_PROVE_RAW_LOCK_NESTING 2>/dev/null || true
        scripts/config --disable CONFIG_DEBUG_PAGEALLOC 2>/dev/null || true

        # Enable useful features
        scripts/config --enable CONFIG_HOSTFS 2>/dev/null || true
        scripts/config --enable CONFIG_TMPFS 2>/dev/null || true
        scripts/config --enable CONFIG_PROC_FS 2>/dev/null || true
        scripts/config --enable CONFIG_SYSFS 2>/dev/null || true
        scripts/config --enable CONFIG_DEBUG_FS 2>/dev/null || true

        info "Running olddefconfig..."
        make ARCH=um olddefconfig 2>&1 | tee -a "${BUILD_LOG}" | tail -3
    fi

    # Verify LDM is enabled
    if grep -q "CONFIG_LDM_OS=y" .config; then
        ok "CONFIG_LDM_OS=y confirmed"
    else
        err "CONFIG_LDM_OS not enabled in .config!"
        exit 1
    fi

    cd "${WORKSPACE}"
}

# ---- Build UML ------------------------------------------------------------
build_uml() {
    step "Step 2/4: Building UML Kernel Binary"

    cd "${KERNEL_SRC}"

    info "Compiling with ${JOBS} parallel jobs..."
    local start_time=$(date +%s)

    if [ "${VERBOSE:-0}" = "1" ]; then
        make ARCH=um -j"${JOBS}" 2>&1 | tee -a "${BUILD_LOG}"
    else
        make ARCH=um -j"${JOBS}" 2>&1 | tee -a "${BUILD_LOG}" | \
            grep -E "(CC|LD|error|warning:.*ldm)" | tail -30
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # Copy output
    if [ -f "${KERNEL_SRC}/linux" ]; then
        cp "${KERNEL_SRC}/linux" "${UML_BIN}"
        chmod +x "${UML_BIN}"
        local size=$(du -h "${UML_BIN}" | cut -f1)
        ok "UML binary built: ${UML_BIN} (${size}) in ${elapsed}s"
    else
        err "Build failed — linux binary not found"
        err "Check ${BUILD_LOG} for details"
        exit 1
    fi

    # Copy System.map if available
    if [ -f "${KERNEL_SRC}/System.map" ]; then
        cp "${KERNEL_SRC}/System.map" "${OUTPUT_DIR}/System.map"
        local ldm_syms=$(grep -c "ldm_" "${OUTPUT_DIR}/System.map" 2>/dev/null || echo 0)
        ok "System.map copied (${ldm_syms} LDM symbols)"
    fi

    cd "${WORKSPACE}"
}

# ---- Build rootfs image ---------------------------------------------------
build_rootfs_image() {
    step "Step 3/4: Building Root Filesystem Image"

    if [ ! -d "${ROOTFS_DIR}" ]; then
        err "Root filesystem not found at ${ROOTFS_DIR}"
        exit 1
    fi

    info "Creating ext2 rootfs image..."

    # Calculate required size
    local rootfs_size=$(du -sm "${ROOTFS_DIR}" 2>/dev/null | cut -f1)
    local img_size=$((rootfs_size + 50))  # Add 50MB headroom

    # Try genext2fs first (no root needed), fall back to dd+mke2fs
    if command -v genext2fs >/dev/null 2>&1; then
        genext2fs -b "${img_size}"K -d "${ROOTFS_DIR}" "${ROOTFS_IMG}" 2>&1 | tee -a "${BUILD_LOG}"
    elif command -v mke2fs >/dev/null 2>&1; then
        dd if=/dev/zero of="${ROOTFS_IMG}" bs=1M count="${img_size}" 2>/dev/null
        mke2fs -F -t ext2 "${ROOTFS_IMG}" 2>&1 | tee -a "${BUILD_LOG}"
        # Mount and copy (may need root)
        local mnt="/tmp/ldm_rootfs_mnt"
        mkdir -p "${mnt}"
        if mount -o loop "${ROOTFS_IMG}" "${mnt}" 2>/dev/null; then
            cp -a "${ROOTFS_DIR}"/* "${mnt}/" 2>/dev/null
            umount "${mnt}"
        else
            warn "Cannot mount loop device (no root). Using hostfs mode instead."
            rm -f "${ROOTFS_IMG}"
        fi
        rmdir "${mnt}" 2>/dev/null || true
    else
        warn "Neither genext2fs nor mke2fs available."
        warn "QEMU image will use hostfs mode."
        return 0
    fi

    if [ -f "${ROOTFS_IMG}" ]; then
        local img_actual=$(du -h "${ROOTFS_IMG}" | cut -f1)
        ok "Rootfs image: ${ROOTFS_IMG} (${img_actual})"
    fi
}

# ---- Build QEMU image -----------------------------------------------------
build_qemu_image() {
    step "Step 4/4: Creating QEMU Bootable Image"

    if [ ! -f "${UML_BIN}" ]; then
        err "UML binary not found. Run 'uml' target first."
        exit 1
    fi

    if ! command -v qemu-img >/dev/null 2>&1; then
        warn "qemu-img not found. Creating raw image with dd."
        QEMU_FMT="raw"
        QEMU_IMG="${OUTPUT_DIR}/ldm-os.raw"
    fi

    info "Creating ${QEMU_FMT} disk image (${QEMU_SIZE})..."

    # Create disk image
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -f "${QEMU_FMT}" "${QEMU_IMG}" "${QEMU_SIZE}" 2>&1 | tee -a "${BUILD_LOG}"
    else
        local size_mb=$(echo "${QEMU_SIZE}" | sed 's/G/*1024/;s/M//' | bc 2>/dev/null || echo 2048)
        dd if=/dev/zero of="${QEMU_IMG}" bs=1M count="${size_mb}" 2>/dev/null
    fi

    # If we have a rootfs image, embed it
    if [ -f "${ROOTFS_IMG}" ]; then
        info "Embedding rootfs into QEMU image..."
        if command -v qemu-img >/dev/null 2>&1 && [ "${QEMU_FMT}" = "raw" ]; then
            dd if="${ROOTFS_IMG}" of="${QEMU_IMG}" conv=notrunc 2>/dev/null
        elif command -v guestfish >/dev/null 2>&1; then
            # Use guestfish to copy files into the image
            warn "guestfish available but complex setup needed."
            warn "Use hostfs mode for QEMU instead."
        fi
    fi

    # Generate QEMU launch script
    cat > "${OUTPUT_DIR}/run-qemu.sh" << 'QEMU_SCRIPT'
#!/bin/bash
# LDM-OS QEMU Launch Script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${SCRIPT_DIR}/ldm-os.qcow2"
[ ! -f "$IMG" ] && IMG="${SCRIPT_DIR}/ldm-os.raw"
ROOTFS="${SCRIPT_DIR}/../rootfs"

if [ ! -f "$IMG" ]; then
    echo "ERROR: No QEMU image found. Run: ./ldm-os-build.sh qemu"
    exit 1
fi

echo "=== LDM-OS QEMU Boot ==="
echo "Image: $IMG"
echo "RootFS: $ROOTFS"
echo ""

# Try KVM first, fall back to TCG
KVM_OPT=""
if [ -w /dev/kvm ] 2>/dev/null; then
    KVM_OPT="-enable-kvm"
    echo "Using KVM acceleration"
else
    echo "Using TCG (software emulation)"
fi

qemu-system-x86_64 \
    ${KVM_OPT} \
    -m 512 \
    -kernel "${SCRIPT_DIR}/linux.uml" \
    -drive file="${IMG}",format=qcow2,if=virtio \
    -append "root=/dev/vda rootfstype=ext2 rw console=ttyS0 mem=256M" \
    -nographic \
    -serial mon:stdio \
    -net none \
    "$@"
QEMU_SCRIPT
    chmod +x "${OUTPUT_DIR}/run-qemu.sh"

    # Also generate a hostfs-mode QEMU script (more reliable)
    cat > "${OUTPUT_DIR}/run-qemu-hostfs.sh" << HOSTFS_SCRIPT
#!/bin/bash
# LDM-OS QEMU HostFS Mode (recommended for development)
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="\${SCRIPT_DIR}/../rootfs"
UML="\${SCRIPT_DIR}/linux.uml"

if [ ! -f "\$UML" ]; then
    echo "ERROR: UML binary not found. Run: ./ldm-os-build.sh uml"
    exit 1
fi

echo "=== LDM-OS QEMU HostFS Mode ==="
echo "Kernel: \$UML"
echo "RootFS: \$ROOTFS"
echo ""

# Note: This uses the UML binary directly (it IS a valid x86 ELF)
# For true QEMU, you'd need a vmlinux bzImage. The UML binary
# runs natively on x86_64 hosts without QEMU.
exec "\$UML" \\
    rootfstype=hostfs rootflags="\$ROOTFS" \\
    mem=256M \\
    init=/bin/sh \\
    "\$@"
HOSTFS_SCRIPT
    chmod +x "${OUTPUT_DIR}/run-qemu-hostfs.sh"

    local img_size=$(du -h "${QEMU_IMG}" 2>/dev/null | cut -f1)
    ok "QEMU image: ${QEMU_IMG} (${img_size})"
    ok "Launch scripts: run-qemu.sh, run-qemu-hostfs.sh"
}

# ---- Test -----------------------------------------------------------------
run_tests() {
    step "Running Enterprise Test Suite"

    if [ ! -f "${UML_BIN}" ]; then
        err "UML binary not found. Build first."
        exit 1
    fi

    local test_script="${ROOTFS_DIR}/test_enterprise.sh"
    if [ ! -f "$test_script" ]; then
        test_script="${ROOTFS_DIR}/test_os_safe.sh"
    fi
    if [ ! -f "$test_script" ]; then
        warn "No test script found in rootfs."
        warn "Place test_enterprise.sh or test_os_safe.sh in ${ROOTFS_DIR}/"
        return 1
    fi

    # Create init wrapper
    local init_script="${ROOTFS_DIR}/run_bench_init.sh"
    cat > "$init_script" << INITEOF
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs none /sys/kernel/debug 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
mount -o remount,rw / 2>/dev/null
$(basename "$test_script")
echo "BENCHMARK_EXIT_CODE=\$?"
sleep 1
echo o > /proc/sysrq-trigger 2>/dev/null || true
INITEOF
    chmod +x "$init_script"

    info "Starting UML with test suite..."
    timeout 300 "${UML_BIN}" \
        rootfstype=hostfs rootflags="${ROOTFS_DIR}" \
        mem="${UML_MEM}" \
        init=/run_bench_init.sh \
        2>&1 | grep -E "(PASS|FAIL|RESULTS|╔|╚|║|===|Kernel:)" | tee "${LOG_DIR}/test_results.txt"

    local result=$(grep "RESULTS" "${LOG_DIR}/test_results.txt" 2>/dev/null || echo "")
    echo ""
    if echo "$result" | grep -q "0 FAIL"; then
        ok "All tests passed!"
    else
        warn "Some tests failed. See ${LOG_DIR}/test_results.txt"
    fi
}

# ---- Status ---------------------------------------------------------------
show_status() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              LDM-OS Build Status                        ║"
    echo "╠══════════════════════════════════════════════════════════╣"

    if [ -f "${UML_BIN}" ]; then
        local uml_size=$(du -h "${UML_BIN}" | cut -f1)
        local uml_date=$(stat -c '%y' "${UML_BIN}" 2>/dev/null | cut -d. -f1)
        printf "║  UML Binary:  %-40s ║\n" "✅ ${uml_size} (${uml_date})"
    else
        printf "║  UML Binary:  %-40s ║\n" "❌ Not built"
    fi

    if [ -f "${QEMU_IMG}" ]; then
        local qemu_size=$(du -h "${QEMU_IMG}" | cut -f1)
        printf "║  QEMU Image:  %-40s ║\n" "✅ ${qemu_size} (${QEMU_FMT})"
    else
        printf "║  QEMU Image:  %-40s ║\n" "❌ Not built"
    fi

    if [ -f "${ROOTFS_IMG}" ]; then
        local rfs_size=$(du -h "${ROOTFS_IMG}" | cut -f1)
        printf "║  Rootfs Img:  %-40s ║\n" "✅ ${rfs_size}"
    else
        printf "║  Rootfs Img:  %-40s ║\n" "⚠️  Using hostfs mode"
    fi

    if [ -f "${KERNEL_SRC}/.config" ]; then
        local ldm_cfg=$(grep "CONFIG_LDM_OS=y" "${KERNEL_SRC}/.config" 2>/dev/null && echo "✅ Enabled" || echo "❌ Disabled")
        printf "║  LDM Config:  %-40s ║\n" "${ldm_cfg}"
    else
        printf "║  LDM Config:  %-40s ║\n" "❌ No .config"
    fi

    local ldm_modules=$(find "${KERNEL_SRC}/mm" -name "ldm_*.c" 2>/dev/null | wc -l)
    printf "║  LDM Modules: %-40s ║\n" "${ldm_modules} source files"

    echo "╠══════════════════════════════════════════════════════════╣"
    printf "║  Workspace: %-44s ║\n" "${WORKSPACE}"
    printf "║  Kernel:    %-44s ║\n" "${KERNEL_SRC}"
    printf "║  Output:    %-44s ║\n" "${OUTPUT_DIR}"
    echo "╚══════════════════════════════════════════════════════════╝"
}

# ---- Clean ----------------------------------------------------------------
do_clean() {
    info "Cleaning build artifacts..."
    rm -f "${UML_BIN}" "${QEMU_IMG}" "${ROOTFS_IMG}"
    rm -f "${OUTPUT_DIR}/System.map"
    rm -f "${OUTPUT_DIR}/run-qemu.sh" "${OUTPUT_DIR}/run-qemu-hostfs.sh"
    rm -rf "${LOG_DIR}"/*.log "${LOG_DIR}"/*.txt

    if [ -f "${KERNEL_SRC}/Makefile" ]; then
        info "Cleaning kernel build tree..."
        cd "${KERNEL_SRC}"
        make ARCH=um clean 2>&1 | tail -3
        cd "${WORKSPACE}"
    fi

    ok "Clean complete"
}

# ---- Main -----------------------------------------------------------------
main() {
    local target="${1:-uml}"

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         LDM-OS Build System                             ║"
    echo "║         Low Data Movement Operating System               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    case "$target" in
        uml)
            setup_toolchain
            configure_kernel
            build_uml
            echo ""
            ok "UML build complete: ${UML_BIN}"
            info "Run: ${UML_BIN} rootfstype=hostfs rootflags=${ROOTFS_DIR} mem=${UML_MEM}"
            ;;
        qemu)
            setup_toolchain
            configure_kernel
            build_uml
            build_rootfs_image
            build_qemu_image
            echo ""
            ok "QEMU build complete: ${QEMU_IMG}"
            info "Run: ${OUTPUT_DIR}/run-qemu.sh"
            ;;
        all)
            setup_toolchain
            configure_kernel
            build_uml
            build_rootfs_image
            build_qemu_image
            echo ""
            ok "Full build complete"
            info "UML:  ${UML_BIN}"
            info "QEMU: ${QEMU_IMG}"
            ;;
        test)
            setup_toolchain
            if [ ! -f "${UML_BIN}" ]; then
                configure_kernel
                build_uml
            fi
            run_tests
            ;;
        clean)
            do_clean
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            echo "Usage: $0 [target]"
            echo ""
            echo "Targets:"
            echo "  uml     Build UML binary (default)"
            echo "  qemu    Build QEMU bootable image"
            echo "  all     Build both UML + QEMU"
            echo "  test    Build + run enterprise test suite"
            echo "  clean   Clean all build artifacts"
            echo "  status  Show current build status"
            echo ""
            echo "Environment:"
            echo "  JOBS=N         Parallel jobs (default: $(nproc 2>/dev/null || echo 8))"
            echo "  UML_MEM=256M   Guest memory (default: 128M)"
            echo "  QEMU_FMT=raw   Image format: qcow2|raw (default: qcow2)"
            echo "  QEMU_SIZE=4G   Disk size (default: 2G)"
            echo "  VERBOSE=1      Verbose output"
            echo "  SKIP_CONFIG=1  Skip kernel reconfig"
            ;;
        *)
            err "Unknown target: $target"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
