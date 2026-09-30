#!/bin/bash
# =============================================================================
# LDM-OS Kernel Mode Switch — One-click toggle between kernel configurations
#
# Usage:
#   ./ldm-switch.sh status          Show current LDM configuration
#   ./ldm-switch.sh builtin         Switch to all-built-in mode (CONFIG=y)
#   ./ldm-switch.sh module          Switch to hybrid mode (core=y, rest=m)
#   ./ldm-switch.sh off             Disable LDM entirely (CONFIG=n)
#   ./ldm-switch.sh sysctl          Show/set runtime sysctl parameters
#   ./ldm-switch.sh sysctl <key> <val>  Set a specific sysctl parameter
#   ./ldm-switch.sh patch           Generate formal kernel patchset
#   ./ldm-switch.sh help            Show this help
#
# Copyright (C) 2026 LDM-OS Project
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="${SCRIPT_DIR}/kernel-src/"
KCONFIG="${KERNEL_SRC}/mm/Kconfig.ldm"
MAKEFILE_LDM="${KERNEL_SRC}/mm/Makefile.ldm"

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ---- Status ---------------------------------------------------------------
do_status() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              LDM-OS Configuration Status                ║"
    echo "╠══════════════════════════════════════════════════════════╣"

    if [ ! -f "${KERNEL_SRC}/.config" ]; then
        warn "No .config found. Run 'make ARCH=um defconfig' first."
        return 1
    fi

    local ldm_main=$(grep "^CONFIG_LDM_OS=" "${KERNEL_SRC}/.config" 2>/dev/null || echo "not set")
    printf "║  LDM_OS:          %-38s ║\n" "$ldm_main"

    for mod in CORE COMPAT LAZY IOMMU CACHE HOOKS DEEP_HOOKS NET VFS SCHED MM_ADVANCED VM DEBUG; do
        local val=$(grep "^CONFIG_LDM_OS_${mod}=" "${KERNEL_SRC}/.config" 2>/dev/null || echo "not set")
        printf "║  LDM_OS_%-10s %-38s ║\n" "${mod}:" "$val"
    done

    echo "╠══════════════════════════════════════════════════════════╣"

    # Check sysctl
    if [ -d /proc/sys/vm ] && ls /proc/sys/vm/ldm_* >/dev/null 2>&1; then
        echo "║  Sysctl: ✅ Active at /proc/sys/vm/ldm_*               ║"
        local enabled=$(cat /proc/sys/vm/ldm_enabled 2>/dev/null || echo "?")
        local mode=$(cat /proc/sys/vm/ldm_mode 2>/dev/null || echo "?")
        printf "║    ldm_enabled=%-5s  ldm_mode=%-27s ║\n" "$enabled" "$mode"
    else
        echo "║  Sysctl: ⚠️  Not available (kernel not running or      ║"
        echo "║          LDM not loaded)                                ║"
    fi

    echo "╚══════════════════════════════════════════════════════════╝"
}

# ---- Switch modes ---------------------------------------------------------
switch_mode() {
    local target="$1"

    if [ ! -f "${KERNEL_SRC}/.config" ]; then
        warn "No .config found. Creating from defconfig..."
        cd "${KERNEL_SRC}"
        make ARCH=um defconfig 2>/dev/null
        cd "${SCRIPT_DIR}"
    fi

    case "$target" in
        builtin)
            info "Switching to ALL BUILT-IN mode..."
            sed -i 's/^CONFIG_LDM_OS=.*/CONFIG_LDM_OS=y/' "${KERNEL_SRC}/.config"
            for mod in CORE COMPAT LAZY IOMMU CACHE HOOKS DEEP_HOOKS NET VFS SCHED MM_ADVANCED VM; do
                sed -i "s/^CONFIG_LDM_OS_${mod}=.*/CONFIG_LDM_OS_${mod}=y/" "${KERNEL_SRC}/.config"
                # Add if missing
                grep -q "^CONFIG_LDM_OS_${mod}=" "${KERNEL_SRC}/.config" || \
                    echo "CONFIG_LDM_OS_${mod}=y" >> "${KERNEL_SRC}/.config"
            done
            sed -i 's/^CONFIG_LDM_OS_DEBUG=.*/CONFIG_LDM_OS_DEBUG=y/' "${KERNEL_SRC}/.config"
            grep -q "^CONFIG_LDM_OS_DEBUG=" "${KERNEL_SRC}/.config" || \
                echo "CONFIG_LDM_OS_DEBUG=y" >> "${KERNEL_SRC}/.config"
            ok "All LDM modules set to built-in (y)"
            ;;
        module)
            info "Switching to HYBRID MODULE mode..."
            sed -i 's/^CONFIG_LDM_OS=.*/CONFIG_LDM_OS=y/' "${KERNEL_SRC}/.config"
            # Core always built-in
            sed -i "s/^CONFIG_LDM_OS_CORE=.*/CONFIG_LDM_OS_CORE=y/" "${KERNEL_SRC}/.config"
            grep -q "^CONFIG_LDM_OS_CORE=" "${KERNEL_SRC}/.config" || \
                echo "CONFIG_LDM_OS_CORE=y" >> "${KERNEL_SRC}/.config"
            # Rest as modules
            for mod in COMPAT LAZY IOMMU CACHE HOOKS DEEP_HOOKS NET VFS SCHED MM_ADVANCED VM; do
                sed -i "s/^CONFIG_LDM_OS_${mod}=.*/CONFIG_LDM_OS_${mod}=m/" "${KERNEL_SRC}/.config"
                grep -q "^CONFIG_LDM_OS_${mod}=" "${KERNEL_SRC}/.config" || \
                    echo "CONFIG_LDM_OS_${mod}=m" >> "${KERNEL_SRC}/.config"
            done
            sed -i 's/^CONFIG_LDM_OS_DEBUG=.*/CONFIG_LDM_OS_DEBUG=y/' "${KERNEL_SRC}/.config"
            grep -q "^CONFIG_LDM_OS_DEBUG=" "${KERNEL_SRC}/.config" || \
                echo "CONFIG_LDM_OS_DEBUG=y" >> "${KERNEL_SRC}/.config"
            ok "Hybrid mode: core=y, sub-modules=m"
            ;;
        off)
            info "Disabling LDM entirely..."
            sed -i 's/^CONFIG_LDM_OS=.*/# CONFIG_LDM_OS is not set/' "${KERNEL_SRC}/.config"
            for mod in CORE COMPAT LAZY IOMMU CACHE HOOKS DEEP_HOOKS NET VFS SCHED MM_ADVANCED VM DEBUG; do
                sed -i "s/^CONFIG_LDM_OS_${mod}=.*/# CONFIG_LDM_OS_${mod} is not set/" "${KERNEL_SRC}/.config"
            done
            ok "LDM disabled"
            ;;
        *)
            warn "Unknown mode: $target (use: builtin, module, off)"
            return 1
            ;;
    esac

    info "Run 'make ARCH=um olddefconfig && make ARCH=um -j\$(nproc)' to rebuild"
}

# ---- Sysctl management ----------------------------------------------------
do_sysctl() {
    if [ $# -eq 0 ]; then
        # Show all LDM sysctl parameters
        echo "=== LDM Runtime Parameters (/proc/sys/vm/ldm_*) ==="
        if ls /proc/sys/vm/ldm_* >/dev/null 2>&1; then
            for f in /proc/sys/vm/ldm_*; do
                local key=$(basename "$f")
                local val=$(cat "$f" 2>/dev/null)
                printf "  %-35s = %s\n" "$key" "$val"
            done
        else
            warn "LDM sysctl not available (kernel not running or LDM not loaded)"
            echo ""
            echo "Available parameters (when active):"
            echo "  vm.ldm_enabled              Global on/off (0/1)"
            echo "  vm.ldm_mode                 Mode: 0=off 1=compat 2=native 3=aggressive"
            echo "  vm.ldm_zerocopy_threshold   Zero-copy trigger (bytes, default 65536)"
            echo "  vm.ldm_nt_threshold         NT store trigger (bytes, default 262144)"
            echo "  vm.ldm_batch_threshold      Batch op trigger (bytes, default 1048576)"
            echo "  vm.ldm_cow_fork_threshold   Fork COW pages (default 4096)"
            echo "  vm.ldm_lazy_zero_enabled    Lazy zero on/off (0/1)"
            echo "  vm.ldm_lazy_cow_enabled     Lazy COW on/off (0/1)"
            echo "  vm.ldm_cache_affinity_enabled Cache affinity (0/1)"
            echo "  vm.ldm_iommu_mode           IOMMU: 0=off 1=sw 2=hw"
            echo "  vm.ldm_anchor_max_pages     Max anchored pages per process"
            echo "  vm.ldm_eviction_pressure_pct Memory pressure threshold %"
            echo "  vm.ldm_stats_interval_ms    Stats refresh interval ms"
            echo "  vm.ldm_debug_level          Debug: 0=off 1=warn 2=info 3=trace"
        fi
    elif [ $# -eq 2 ]; then
        local key="$1" val="$2"
        if [ -f "/proc/sys/vm/ldm_${key}" ]; then
            echo "$val" > "/proc/sys/vm/ldm_${key}"
            ok "Set vm.ldm_${key} = $(cat /proc/sys/vm/ldm_${key})"
        else
            warn "Parameter vm.ldm_${key} not found"
        fi
    else
        warn "Usage: $0 sysctl [key value]"
    fi
}

# ---- Main -----------------------------------------------------------------
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         LDM-OS Kernel Mode Switch                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    case "$cmd" in
        status)  do_status ;;
        builtin) switch_mode builtin ;;
        module)  switch_mode module ;;
        off)     switch_mode off ;;
        sysctl)  do_sysctl "$@" ;;
        help|--help|-h)
            echo "Usage: $0 <command> [args]"
            echo ""
            echo "Commands:"
            echo "  status              Show current LDM configuration"
            echo "  builtin             All modules built-in (CONFIG=y)"
            echo "  module              Hybrid: core=y, sub-modules=m"
            echo "  off                 Disable LDM entirely"
            echo "  sysctl              Show runtime parameters"
            echo "  sysctl <key> <val>  Set runtime parameter"
            echo "  help                Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 builtin          # Maximum performance, no module loading"
            echo "  $0 module           # Flexible deployment, load on demand"
            echo "  $0 sysctl enabled 0 # Disable LDM at runtime without reboot"
            echo "  $0 sysctl mode 3    # Enable aggressive optimization"
            ;;
        *)
            warn "Unknown command: $cmd"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
