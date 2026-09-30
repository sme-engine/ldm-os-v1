#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

PASS=0; FAIL=0
check() { [ "$1" = "0" ] && { echo "[PASS] $2"; PASS=$((PASS+1)); } || { echo "[FAIL] $2"; FAIL=$((FAIL+1)); }; }

echo "=== LDM-OS VFS/IO + Full Stack Verification ==="

LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
echo "Total LDM symbols: $LDM_SYMS"
[ "$LDM_SYMS" -gt 200 ] && check 0 "LDM symbols > 200 ($LDM_SYMS)" || check 1 "LDM symbols"

# VFS module symbols
for sym in ldm_vfs_read_hint ldm_vfs_write_hint ldm_iovec_hint \
           ldm_iouring_import_hint ldm_dma_map_hint ldm_sg_copy_hint \
           ldm_sendfile_track ldm_vfs_init; do
    grep -q " $sym$\| ${sym}$" /proc/kallsyms 2>/dev/null
    check $? "Symbol: $sym"
done

# All debugfs interfaces
for f in stats hooks_stats deep_hooks_stats lazy_stats cache_stats iommu_stats net_stats vfs_stats; do
    [ -f "/sys/kernel/debug/$f" ] && check 0 "debugfs: $f" || check 1 "debugfs: $f"
done

echo ""
echo "--- VFS Stats ---"
cat /sys/kernel/debug/vfs_stats 2>/dev/null | head -15

MEM=$(free 2>/dev/null | awk '/Mem:/{print $2}')
[ "$MEM" -gt 50000 ] && check 0 "Memory OK (${MEM}kB)" || check 1 "Memory"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "LDM-OS FULL STACK FULLY OPERATIONAL" || echo "ISSUES DETECTED"
poweroff -f 2>/dev/null
