#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

PASS=0; FAIL=0
check() { [ "$1" = "0" ] && { echo "[PASS] $2"; PASS=$((PASS+1)); } || { echo "[FAIL] $2"; FAIL=$((FAIL+1)); }; }

echo "=== LDM-OS Network Stack Verification ==="

LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
echo "Total LDM symbols: $LDM_SYMS"
[ "$LDM_SYMS" -gt 170 ] && check 0 "LDM symbols > 170 ($LDM_SYMS)" || check 1 "LDM symbols"

# Net module symbols
for sym in ldm_skb_copy_bits ldm_skb_clone_hook ldm_tcp_send_hint \
           ldm_tcp_recv_hint ldm_ip_append_hint ldm_tun_zerocopy_check \
           ldm_gro_merge_hint ldm_skb_alloc_hint ldm_net_init; do
    grep -q " $sym$\| ${sym}$" /proc/kallsyms 2>/dev/null
    check $? "Symbol: $sym"
done

# DebugFS
[ -f /sys/kernel/debug/net_stats ] && check 0 "net_stats debugfs" || check 1 "net_stats debugfs"

echo ""
echo "--- Net Stats ---"
cat /sys/kernel/debug/net_stats 2>/dev/null | head -20

# All debugfs files
echo ""
echo "--- All LDM debugfs entries ---"
find /sys/kernel/debug -maxdepth 1 -name "*stats*" -o -name "ldm_os" 2>/dev/null | sort

MEM=$(free 2>/dev/null | awk '/Mem:/{print $2}')
[ "$MEM" -gt 50000 ] && check 0 "Memory OK (${MEM}kB)" || check 1 "Memory"

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "LDM-OS NETWORK STACK FULLY OPERATIONAL" || echo "ISSUES DETECTED"
poweroff -f 2>/dev/null
