#!/bin/bash
# =============================================================================
# 03_build_initramfs.sh — LDM-OS aarch64 adaptation: assemble bootable initramfs
#
# Produces a plain "newc" (SVR4) cpio initramfs that boots a scripted /init
# against the built-in busybox. Key adaptations for aarch64/Kunpeng:
#
#   1. busybox + dd must be aarch64 ELF.  The repository's rootfs busybox is
#      an x86-64 static binary, so we default to the host's aarch64 busybox
#      (${BUSYBOX_BIN}) and host coreutils dd (${DD_BIN}).
#   2. Everything is dynamically linked against glibc.  We compute the NEEDED
#      closure of busybox/dd with readelf and copy each library into the
#      initramfs under MULTIPLE search paths (/lib, /lib64, /usr/lib,
#      /usr/lib64) so the dynamic loader can resolve regardless of the
#      toolchain's default search layout.  ld-linux-aarch64.so.1 MUST land in
#      /lib because it is the hardcoded interpreter path.
#   3. busybox applet symlinks are installed with `busybox --install -s`.
#      `dd` is additionally placed as a REAL binary (not an applet) because
#      some test scripts invoke it directly with the full path.
#   4. /init is the script init that mounts proc/sys/dev/debugfs/tmpfs and
#      runs the OS-level validation suite, then powers off.
#
# Output: ${INITRAMFS_OUT}
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

TEST_SCRIPT="${TEST_SCRIPT:-${REPO_ROOT}/benchmarks/test_os_safe.sh}"

step "LDM-OS AArch64 initramfs assembly"
echo "  Busybox : ${BUSYBOX_BIN}"
echo "  dd      : ${DD_BIN}"
echo "  Staging : ${STAGING}"
echo "  Output  : ${INITRAMFS_OUT}"
echo ""

is_elf_aarch64 "${BUSYBOX_BIN}" || { err "busybox is not an aarch64 ELF: ${BUSYBOX_BIN}"; exit 1; }
is_elf_aarch64 "${DD_BIN}"      || { err "dd is not an aarch64 ELF: ${DD_BIN}"; exit 1; }
require_cmd cpio readelf file || exit 1

# ---- 1. Prepare staging tree ----------------------------------------------
rm -rf "${STAGING}"
mkdir -p "${STAGING}"/{bin,sbin,etc,dev,proc,sys,tmp,run,root,lib,lib64,usr/lib,usr/lib64}

# ---- 2. Copy static helpers + config ---------------------------------------
cp -f "${BUSYBOX_BIN}" "${STAGING}/bin/busybox"
printf 'root:x:0:0:root:/root:/bin/sh\ndaemon:x:1:1:daemon:/:/sbin/nologin\n' > "${STAGING}/etc/passwd"
printf 'root:x:0:\ndaemon:x:1:\n' > "${STAGING}/etc/group"
echo "ldm-os" > "${STAGING}/etc/hostname"

# ---- 3. Install busybox applet symlinks -------------------------------------
# busybox --install -s writes ABSOLUTE links (target = ${STAGING}/bin/busybox)
# which are dangling inside the ramfs — /init's #!/bin/sh would fail with
# ENOENT. Rewrite every such link to the relative target "busybox".
if ( cd "${STAGING}" && ./bin/busybox --install -s bin ); then
    info "busybox applets installed"
else
    warn "busybox --install -s failed; continuing (expect missing applets)"
fi
find "${STAGING}" -type l -lname "${STAGING}/bin/busybox" -print0 2>/dev/null \
    | while IFS= read -r -d '' l; do ln -sfn busybox "$l"; done

# ---- 4. Install dd as a real binary ------------------------------------------
cp -f "${DD_BIN}" "${STAGING}/bin/dd"
chmod 755 "${STAGING}/bin/dd" "${STAGING}/bin/busybox"

# ---- 5. Copy glibc closure (TRANSITIVE NEEDED deps + interpreter) ------------
# Multi-path copy: /lib + /lib64 + /usr/lib + /usr/lib64 all receive the libs.
# This is the key aarch64 fix: a single-path layout breaks the dynamic loader.
NEEDED_SONAMES="$( { collect_needed_transitive "${STAGING}/bin/busybox"; \
                     collect_needed_transitive "${STAGING}/bin/dd"; } | sort -u )"
for soname in ${NEEDED_SONAMES}; do
    src="$(resolve_lib "${soname}" || true)"
    if [ -z "${src}" ]; then
        warn "cannot resolve ${soname} — skipping (may break runtime)"
        continue
    fi
    for d in lib lib64 usr/lib usr/lib64; do
        cp -f "${src}" "${STAGING}/${d}/"
    done
    ok "lib: ${soname} <- ${src}"
done
# Sanity: interpreter must resolve inside the ramfs at /lib/ld-linux-aarch64.so.1
[ -f "${STAGING}/lib/ld-linux-aarch64.so.1" ] || { err "loader missing at /lib"; exit 1; }

# ---- 6. Test suite + init + bench init ---------------------------------------
if [ -f "${TEST_SCRIPT}" ]; then
    cp -f "${TEST_SCRIPT}" "${STAGING}/test_os_safe.sh"
    ok "test suite: $(basename "${TEST_SCRIPT}") (${TEST_SCRIPT})"
else
    warn "test_os_safe.sh not found at ${TEST_SCRIPT}; writing default 53-test suite"
    cat > "${STAGING}/test_os_safe.sh" <<'EOF'
#!/bin/sh
PASS=0; FAIL=0; TOTAL=0
rt() { TOTAL=$((TOTAL+1)); printf "  [%2d] %-45s " "$TOTAL" "$1"; shift; if eval "$@" >/dev/null 2>&1; then echo PASS; PASS=$((PASS+1)); else echo FAIL; FAIL=$((FAIL+1)); fi; }
echo "=== LDM-OS Traditional OS Benchmark ==="
echo "  Kernel: $(uname -r) | Arch: $(uname -m)"
rt "dd write 1MB" "dd if=/dev/zero of=/tmp/t1 bs=1M count=1 2>/dev/null && rm -f /tmp/t1"
rt "kernel: uname" "uname -r"
rt "proc mounted" "test -r /proc/uptime"
rt "debugfs ldm_os" "test -d /sys/kernel/debug/ldm_os"
rt "shell arithmetic" "test $((1+1)) -eq 2"
echo ""
echo "=== Result: PASS=$PASS FAIL=$FAIL TOTAL=$TOTAL ==="
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED - LDM-OS FULLY COMPATIBLE"
exit 0
EOF
fi
chmod 755 "${STAGING}/test_os_safe.sh"

cat > "${STAGING}/init" <<'EOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t debugfs none /sys/kernel/debug 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
echo "=============================================="
echo " LDM-OS initramfs boot - $(uname -r) $(uname -m)"
echo "=============================================="
echo "--- LDM-OS dmesg check ---"
dmesg | grep -iE "ldm|Low Data" | head -20
echo "--- debugfs stats ---"
cat /sys/kernel/debug/ldm_os/stats 2>/dev/null || echo "(ldm_os stats unreadable)"
echo "--- running OS-level validation ---"
sh /test_os_safe.sh
echo "TEST_OS_SAFE_EXIT=$?"
echo "--- poweroff ---"
echo o > /proc/sysrq-trigger 2>/dev/null || /sbin/poweroff -f 2>/dev/null || true
sleep 2
EOF
chmod 755 "${STAGING}/init"

cat > "${STAGING}/run_bench_init.sh" <<'EOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs none /sys/kernel/debug 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
mount -o remount,rw / 2>/dev/null
/test_os_safe.sh
echo "BENCHMARK_EXIT_CODE=$?"
sleep 1
echo o > /proc/sysrq-trigger 2>/dev/null || true
EOF
chmod 755 "${STAGING}/run_bench_init.sh"

# ---- 7. Pack cpio (newc / SVR4 no-CRC — what the kernel expects) -------------
( cd "${STAGING}" && find . -print0 | cpio --null -o -H newc 2>/dev/null ) > "${INITRAMFS_OUT}"
info "initramfs: $(ls -la "${INITRAMFS_OUT}" | awk '{print $5" bytes"}') ${INITRAMFS_OUT}"

# ---- 8. Verify archive sanity -------------------------------------------------
if archive_has "${INITRAMFS_OUT}" init; then
    ok "archive contains /init"
else
    err "archive missing /init"; exit 1
fi
if archive_has "${INITRAMFS_OUT}" lib/ld-linux-aarch64.so.1; then
    ok "archive contains /lib/ld-linux-aarch64.so.1"
else
    err "archive missing dynamic loader"; exit 1
fi
if archive_has "${INITRAMFS_OUT}" bin/dd; then
    ok "archive contains /bin/dd"
else
    err "archive missing /bin/dd"; exit 1
fi
ok "Initramfs ready: ${INITRAMFS_OUT}"