#!/bin/bash
# =============================================================================
# Alpine UML Kernel Build Script
# 
# Builds a debug-enabled UML kernel from Linux 6.6.142 source with Alpine
# v3.20 virt configuration overlay. Produces a 'linux' binary ready for
# direct execution as a User-Mode Linux instance.
#
# Usage: ./build_uml_kernel.sh [--clean] [--jobs N]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"

# Source environment
source "${WORKSPACE}/toolchain/env.sh"

# Parse arguments
CLEAN=false
JOBS=$(nproc 2>/dev/null || echo 4)
while [[ $# -gt 0 ]]; do
  case $1 in
    --clean) CLEAN=true; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

KERNEL_SRC="${WORKSPACE}/src/linux"
OUTPUT_DIR="${WORKSPACE}/output"
LOG_DIR="${WORKSPACE}/logs"
BUILD_LOG="${LOG_DIR}/kernel-build-$(date +%Y%m%d-%H%M%S).log"

echo "[BUILD] ============================================"
echo "[BUILD] Alpine UML Kernel Build"
echo "[BUILD] ============================================"
echo "[BUILD] Kernel Source: ${KERNEL_SRC}"
echo "[BUILD] Output Dir:    ${OUTPUT_DIR}"
echo "[BUILD] Jobs:          ${JOBS}"
echo "[BUILD] Clean:         ${CLEAN}"
echo "[BUILD] Build Log:     ${BUILD_LOG}"
echo "[BUILD] ============================================"

cd "${KERNEL_SRC}"

# Apply debug config if not already configured
if [ ! -f .config ] || [ "${CLEAN}" = true ]; then
  echo "[BUILD] Applying UML debug configuration..."
  bash "${WORKSPACE}/scripts/generate_uml_debug_config.sh" 2>&1 | tee -a "${BUILD_LOG}"
fi

# Clean if requested
if [ "${CLEAN}" = true ]; then
  echo "[BUILD] Cleaning previous build artifacts..."
  make ARCH=um clean 2>&1 | tee -a "${BUILD_LOG}"
  # Re-apply config after clean
  cp "${WORKSPACE}/kernel/.config.uml-debug" .config
  export M4="/tmp/qemu_extract/usr/bin/m4"
  export BISON_PKGDATADIR="/tmp/qemu_extract/usr/share/bison"
  make ARCH=um M4="$M4" BISON_PKGDATADIR="$BISON_PKGDATADIR" olddefconfig 2>&1 | tee -a "${BUILD_LOG}"
fi

# Build the UML kernel
echo "[BUILD] Starting kernel compilation (ARCH=um, -j${JOBS})..."
echo "[BUILD] Start time: $(date '+%Y-%m-%d %H:%M:%S')"

export M4="/tmp/qemu_extract/usr/bin/m4"
export BISON_PKGDATADIR="/tmp/qemu_extract/usr/share/bison"

make ARCH=um \
     M4="$M4" \
     BISON_PKGDATADIR="$BISON_PKGDATADIR" \
     -j"${JOBS}" \
     V=0 \
     2>&1 | tee -a "${BUILD_LOG}"

BUILD_EXIT=${PIPESTATUS[0]}

echo "[BUILD] End time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "[BUILD] Exit code: ${BUILD_EXIT}"

if [ ${BUILD_EXIT} -ne 0 ]; then
  echo "[BUILD] ERROR: Kernel build failed!"
  echo "[BUILD] Check log: ${BUILD_LOG}"
  exit ${BUILD_EXIT}
fi

# Copy output
mkdir -p "${OUTPUT_DIR}"
cp linux "${OUTPUT_DIR}/linux.uml"
cp System.map "${OUTPUT_DIR}/System.map" 2>/dev/null || true
cp .config "${OUTPUT_DIR}/.config" 2>/dev/null || true

# Generate size report
echo ""
echo "[BUILD] === Build Artifacts ==="
ls -lh "${OUTPUT_DIR}/linux.uml"
file "${OUTPUT_DIR}/linux.uml"
echo "[BUILD] Symbol count: $(wc -l < "${OUTPUT_DIR}/System.map" 2>/dev/null || echo 'N/A')"
echo "[BUILD] Debug info: $(readelf -S "${OUTPUT_DIR}/linux.uml" 2>/dev/null | grep -c debug || echo 'check manually')"

echo ""
echo "[BUILD] === SUCCESS ==="
echo "[BUILD] UML kernel: ${OUTPUT_DIR}/linux.uml"
echo "[BUILD] Ready for: ${OUTPUT_DIR}/linux.uml mem=256M rootfstype=hostfs"
