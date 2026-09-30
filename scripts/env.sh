#!/bin/bash
# =============================================================================
# Alpine UML Workspace — Master Environment Setup
# Source this file to configure the complete build & run environment.
# Usage: source scripts/env.sh
# =============================================================================

export ALPINE_WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TOOLCHAIN_ROOT="/tmp/qemu_extract"

# Extended PATH with extracted RPM tools (flex, bison, bc, m4, cmp, etc.)
export PATH="${ALPINE_WORKSPACE}/toolchain/bin:${TOOLCHAIN_ROOT}/usr/bin:${TOOLCHAIN_ROOT}/bin:$PATH"

# Library paths for extracted RPMs
export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib64:${TOOLCHAIN_ROOT}/lib64:/lib64:/usr/lib64"

# Kernel build requirements
export C_INCLUDE_PATH="${TOOLCHAIN_ROOT}/usr/include:/usr/include"
export LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib64:/usr/lib64"

# Build tool overrides (flex/bison need these)
export M4="${TOOLCHAIN_ROOT}/usr/bin/m4"
export BISON_PKGDATADIR="${TOOLCHAIN_ROOT}/usr/share/bison"

# Key paths
export KERNEL_SRC="${ALPINE_WORKSPACE}/src/linux"
export ROOTFS_DIR="${ALPINE_WORKSPACE}/rootfs"
export OUTPUT_DIR="${ALPINE_WORKSPACE}/output"
export LOG_DIR="${ALPINE_WORKSPACE}/logs"
export SCRIPTS_DIR="${ALPINE_WORKSPACE}/scripts"

# Versions
export ALPINE_VERSION="3.20"
export KERNEL_VERSION="6.6.142"

echo "[ENV] Alpine UML Workspace ready"
echo "[ENV]   Kernel:  Linux ${KERNEL_VERSION} (UML arch)"
echo "[ENV]   Alpine: v${ALPINE_VERSION}"
echo "[ENV]   Output: ${OUTPUT_DIR}"
