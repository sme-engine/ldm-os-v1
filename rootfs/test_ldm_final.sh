#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

PASS=0; FAIL=0
check() { [ "$1" = "0" ] && { echo "[PASS] $2"; PASS=$((PASS+1)); } || { echo "[FAIL] $2"; FAIL=$((FAIL+1)); }; }

echo "=== LDM-OS Complete Stack Final Verification ==="

LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
[ "$LDM_SYMS" -gt 200 ] && check 0 "LDM symbols: $LDM_SYMS" || check 1 "LDM symbols: $LDM_SYMS"

# All debugfs (correct paths)
for f in ldm_os/stats hooks_stats deep_hooks_stats lazy_stats cache_stats iommu_stats net_stats vfs_stats; do
    [ -f "/sys/kernel/debug/$f" ] && check 0 "debugfs: $f" || check 1 "debugfs: $f"
done

MEM=$(free 2>/dev/null | awk '/Mem:/{print $2}')
[ "$MEM" -gt 50000 ] && check 0 "Memory: ${MEM}kB" || check 1 "Memory"

PROC=$(ls /proc/ 2>/dev/null | grep -c '^[0-9]')
[ "$PROC" -gt 10 ] && check 0 "Processes: $PROC" || check 1 "Processes"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "LDM-OS COMPLETE STACK FULLY OPERATIONAL" || echo "ISSUES DETECTED"
poweroff -f 2>/dev/null
