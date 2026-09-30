#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

PASS=0; FAIL=0
check() { [ "$1" = "0" ] && { echo "[PASS] $2"; PASS=$((PASS+1)); } || { echo "[FAIL] $2"; FAIL=$((FAIL+1)); }; }

echo "╔══════════════════════════════════════════╗"
echo "║  LDM-OS COMPLETE KERNEL AUDIT FINAL     ║"
echo "╚══════════════════════════════════════════╝"

LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
[ "$LDM_SYMS" -gt 220 ] && check 0 "LDM symbols: $LDM_SYMS" || check 1 "LDM symbols: $LDM_SYMS"

# All 9 debugfs interfaces
for f in ldm_os/stats hooks_stats deep_hooks_stats lazy_stats cache_stats \
         iommu_stats net_stats vfs_stats sched_block_stats; do
    [ -f "/sys/kernel/debug/$f" ] && check 0 "debugfs: $f" || check 1 "debugfs: $f"
done

# Key symbols from each module
for sym in ldm_init ldm_copy_page_hook ldm_cow_page_hook ldm_memcpy \
           ldm_lazy_copy_create ldm_cache_invalidate_lazy ldm_isolate_address \
           ldm_skb_copy_bits ldm_tcp_send_hint ldm_vfs_read_hint \
           ldm_context_switch_hint ldm_bio_add_page_hint ldm_hugetlb_cow_hint \
           ldm_memset_hint ldm_deep_hooks_init ldm_net_init ldm_vfs_init \
           ldm_sched_block_init; do
    grep -q " ${sym}$" /proc/kallsyms 2>/dev/null
    check $? "API: $sym"
done

MEM=$(free 2>/dev/null | awk '/Mem:/{print $2}')
[ "$MEM" -gt 50000 ] && check 0 "Memory: ${MEM}kB" || check 1 "Memory"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "╔══════════════════════════════════════════╗
║  LDM-OS ALL SUBSYSTEMS FULLY OPERATIONAL ║
╚══════════════════════════════════════════╝" || echo "ISSUES DETECTED"
poweroff -f 2>/dev/null
