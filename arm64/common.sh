#!/bin/bash
# =============================================================================
# LDM-OS AArch64 / Kunpeng 920 adaptation — common environment
#
# Shared helpers and default paths for the arm64 adaptation scripts.
# Sources:      ${REPO_ROOT}/kernel-src        (LDM-modified Linux 6.6.142)
# Outputs:      ${KERNEL_OUT}                  (out-of-tree kernel build)
#               ${INITRAMFS_OUT}               (bootable initramfs cpio)
#               ${STAGING}                     (initramfs staging dir)
#               ${BENCH_RESULTS}               (benchmark CSV/text outputs)
#
# Environment overrides (all optional):
#   REPO_ROOT, KERNEL_OUT, STAGING, INITRAMFS_OUT, BENCH_RESULTS
#   KERNEL_SRC, BUSYBOX_BIN, DD_BIN, GLIBC_SEARCH_PATH
#   QEMU_BIN, QEMU_MEM, QEMU_SMP, QEMU_TIMEOUT
# =============================================================================

set -euo pipefail

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}════════════════════════════════════════════════════════${NC}"; \
          echo -e "${CYAN}  $*${NC}"; \
          echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"; }

# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL_SRC="${KERNEL_SRC:-${REPO_ROOT}/kernel-src}"
KERNEL_OUT="${KERNEL_OUT:-/root/ldm-build-arm64}"
KERNEL_IMAGE="${KERNEL_OUT}/arch/arm64/boot/Image"

STAGING="${STAGING:-/root/ldm-initramfs}"
INITRAMFS_OUT="${INITRAMFS_OUT:-/root/ldm-initramfs.cpio}"
BENCH_RESULTS="${BENCH_RESULTS:-/root/bench-results}"

BUSYBOX_BIN="${BUSYBOX_BIN:-/usr/sbin/busybox}"
DD_BIN="${DD_BIN:-/usr/bin/dd}"
GLIBC_SEARCH_PATH="${GLIBC_SEARCH_PATH:-/usr/lib64 /usr/lib /lib64 /lib /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu}"

# ---------- QEMU ----------
# qemu-system-aarch64 on standard distros; Huawei Cloud EulerOS ships the
# system emulator as /usr/libexec/qemu-kvm. Auto-detect first match.
if [ -z "${QEMU_BIN:-}" ]; then
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        QEMU_BIN="$(command -v qemu-system-aarch64)"
    elif [ -x /usr/libexec/qemu-kvm ]; then
        QEMU_BIN="/usr/libexec/qemu-kvm"
    else
        QEMU_BIN="qemu-system-aarch64"
    fi
fi
QEMU_MEM="${QEMU_MEM:-512}"
QEMU_SMP="${QEMU_SMP:-2}"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-300}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"   # no /dev/kvm in container / HCE host default
# IMPORTANT: on Huawei Cloud EulerOS' qemu-kvm the DEFAULT cpu and even
# 'Kunpeng-920' fail to boot this kernel (no console). 'cortex-a57' works.
QEMU_CPU="${QEMU_CPU:-cortex-a57}"

# ---------- Checks ----------
require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || { err "missing required command: $c"; return 1; }
    done
}

is_aarch64() {
    [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]
}

is_elf_aarch64() {
    # $1 = file; returns 0 if the ELF is aarch64.
    # awk consumes the whole stream (no early exit) so this is immune to the
    # `grep -q | pipefail → SIGPIPE 141` trap.
    local f="$1"
    [ -f "$f" ] || return 1
    file "$f" | awk '/ARM aarch64/{found=1} END{exit !found}'
}

stream_has() {
    # $1 = substring; stdin = stream. awk consumes everything then reports.
    local pat="$1"
    awk -v p="$pat" 'index($0,p){found=1} END{exit !found}'
}

archive_has() {
    # $1 = cpio archive; $2 = exact path entry. No grep/SIGPIPE hazards.
    cpio -it < "$1" 2>/dev/null | awk -v p="$2" '$0==p{found=1} END{exit !found}'
}

resolve_lib() {
    # $1 = soname (e.g. libc.so.6); prints the first absolute path found
    # in GLIBC_SEARCH_PATH, or empty.
    local soname="$1" p
    for d in ${GLIBC_SEARCH_PATH}; do
        p="${d}/${soname}"
        if [ -f "$p" ]; then echo "$p"; return 0; fi
    done
    return 1
}

collect_needed() {
    # $1 = ELF; prints direct NEEDED sonames + the dynamic interpreter.
    local f="$1"
    readelf -d "$f" 2>/dev/null | awk '/\(NEEDED\)/{print $5}' | tr -d '[]'
    # interpreter (the dynamic loader) must be present too — detect it.
    # Note: the line ends with ']' ("[Requesting program interpreter: ...]"),
    # so strip brackets from the last field as well.
    readelf -l "$f" 2>/dev/null | awk '/interpreter:/{print $NF}' | tr -d '[]'
}

collect_needed_transitive() {
    # $1 = ELF; prints the FULL NEEDED closure (direct + transitive deps of
    # every library, including the loader's own deps). This is required for
    # dynamic binaries whose deps depend on further libs (e.g. libselinux.so.1
    # -> libpcre2-8.so.0), otherwise the guest loader fails at execve.
    local f="$1"
    local seen="" todo added s p
    todo="$(collect_needed "$f")"
    while [ -n "$todo" ]; do
        added=""
        for s in ${todo}; do
            case " ${seen} " in *" ${s} "*) continue ;; esac
            seen="${seen} ${s}"
            p="$(resolve_lib "${s}" || true)"
            if [ -n "${p}" ]; then
                added="${added} $(readelf -d "${p}" 2>/dev/null | awk '/\(NEEDED\)/{print $5}' | tr -d '[]')"
            fi
        done
        todo="${added}"
    done
    # normalize: basename + unique
    echo "${seen}" | tr ' ' '\n' | sed 's#^$##' | sed 's#.*/##' | sort -u
}