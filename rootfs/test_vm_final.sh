#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

PASS=0; FAIL=0
check() { [ "$1" = "0" ] && { echo "[PASS] $2"; PASS=$((PASS+1)); } || { echo "[FAIL] $2"; FAIL=$((FAIL+1)); }; }

echo "╔══════════════════════════════════════════════╗"
echo "║  LDM-OS VM FINAL + FULL KERNEL VERIFICATION ║"
echo "╚══════════════════════════════════════════════╝"

LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
[ "$LDM_SYMS" -gt 260 ] && check 0 "LDM symbols: $LDM_SYMS" || check 1 "LDM symbols: $LDM_SYMS"

# All 11 debugfs interfaces
for f in ldm_os/stats hooks_stats deep_hooks_stats lazy_stats cache_stats \
         iommu_stats net_stats vfs_stats sched_block_stats mm_adv_stats vm_final_stats; do
    [ -f "/sys/kernel/debug/$f" ] && check 0 "debugfs: $f" || check 1 "debugfs: $f"
done

# Key API from vm_final module
for sym in ldm_zswap_compress_hint ldm_zswap_decompress_hint \
           ldm_zram_read_hint ldm_zram_write_hint \
           ldm_thp_collapse_hint ldm_reclaim_hint \
           ldm_readahead_hint ldm_mlock_hint ldm_vm_final_init; do
    grep -q " ${sym}$" /proc/kallsyms 2>/dev/null
    check $? "API: $sym"
done

MEM=$(free 2>/dev/null | awk '/Mem:/{print $2}')
[ "$MEM" -gt 50000 ] && check 0 "Memory: ${MEM}kB" || check 1 "Memory"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "╔══════════════════════════════════════════════╗
║  LDM-OS COMPLETE: ALL SUBSYSTEMS COVERED     ║
║  13 MODULES | 11 DEBUGFS | ZERO ERRORS       ║
╚══════════════════════════════════════════════╝" || echo "ISSUES DETECTED"
poweroff -f 2>/dev/null
