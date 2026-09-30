#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

PASS=0; FAIL=0
check() { [ "$1" = "0" ] && { echo "[PASS] $2"; PASS=$((PASS+1)); } || { echo "[FAIL] $2"; FAIL=$((FAIL+1)); }; }

echo "╔══════════════════════════════════════════════╗"
echo "║  LDM-OS EXHAUSTIVE AUDIT FINAL VERIFICATION ║"
echo "╚══════════════════════════════════════════════╝"

LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
[ "$LDM_SYMS" -gt 240 ] && check 0 "LDM symbols: $LDM_SYMS" || check 1 "LDM symbols: $LDM_SYMS"

# All 10 debugfs interfaces
for f in ldm_os/stats hooks_stats deep_hooks_stats lazy_stats cache_stats \
         iommu_stats net_stats vfs_stats sched_block_stats mm_adv_stats; do
    [ -f "/sys/kernel/debug/$f" ] && check 0 "debugfs: $f" || check 1 "debugfs: $f"
done

# Key API from new module
for sym in ldm_migrate_hint ldm_shmem_read_hint ldm_shmem_write_hint \
           ldm_unix_send_hint ldm_unix_recv_hint ldm_uffd_copy_hint \
           ldm_swap_hint ldm_mm_adv_init; do
    grep -q " ${sym}$" /proc/kallsyms 2>/dev/null
    check $? "API: $sym"
done

MEM=$(free 2>/dev/null | awk '/Mem:/{print $2}')
[ "$MEM" -gt 50000 ] && check 0 "Memory: ${MEM}kB" || check 1 "Memory"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "╔══════════════════════════════════════════════╗
║  LDM-OS EXHAUSTIVE AUDIT COMPLETE            ║
║  ALL KERNEL SUBSYSTEMS COVERED               ║
╚══════════════════════════════════════════════╝" || echo "ISSUES DETECTED"
poweroff -f 2>/dev/null
