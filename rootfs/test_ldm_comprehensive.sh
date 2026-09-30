#!/bin/sh
# LDM-OS Comprehensive Functional Verification
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null

PASS=0
FAIL=0

check() {
    if [ "$1" = "0" ]; then
        echo "[PASS] $2"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $2"
        FAIL=$((FAIL + 1))
    fi
}

echo "============================================"
echo "  LDM-OS Comprehensive Verification"
echo "============================================"
echo ""

# 1. Kernel boots and identifies as LDM-OS
echo "--- 1. Kernel Identity ---"
KVER=$(uname -r)
echo "Kernel: $KVER"
[ -n "$KVER" ] && check 0 "Kernel version available" || check 1 "Kernel version"

# 2. LDM config enabled
echo ""
echo "--- 2. LDM Config ---"
LDM_CFG=$(zcat /proc/config.gz 2>/dev/null | grep "^CONFIG_LDM_OS=y")
[ -n "$LDM_CFG" ] && check 0 "CONFIG_LDM_OS=y" || check 1 "CONFIG_LDM_OS"
LDM_DBG=$(zcat /proc/config.gz 2>/dev/null | grep "^CONFIG_LDM_OS_DEBUG=y")
[ -n "$LDM_DBG" ] && check 0 "CONFIG_LDM_OS_DEBUG=y" || check 1 "CONFIG_LDM_OS_DEBUG"

# 3. LDM symbols exported
echo ""
echo "--- 3. LDM Kernel Symbols ---"
LDM_SYM_COUNT=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
echo "LDM symbols: $LDM_SYM_COUNT"
[ "$LDM_SYM_COUNT" -gt 50 ] && check 0 "LDM symbols > 50 ($LDM_SYM_COUNT)" || check 1 "LDM symbols count"

# Check key API symbols
for sym in ldm_init ldm_zerocopy_transfer ldm_lazy_copy ldm_inplace_compute \
           ldm_isolate_address ldm_cache_lazy_update ldm_memcpy ldm_memmove \
           ldm_create_region ldm_destroy_region ldm_dma_map; do
    grep -q " $sym$\| ${sym}$" /proc/kallsyms 2>/dev/null
    check $? "Symbol: $sym"
done

# 4. DebugFS interface
echo ""
echo "--- 4. DebugFS Interface ---"
[ -d /sys/kernel/debug/ldm_os ] && check 0 "debugfs /sys/kernel/debug/ldm_os exists" || check 1 "debugfs ldm_os dir"
[ -f /sys/kernel/debug/ldm_os/stats ] && check 0 "debugfs stats file exists" || check 1 "debugfs stats file"

STATS=$(cat /sys/kernel/debug/ldm_os/stats 2>/dev/null)
echo "$STATS" | grep -q "zerocopy_transfers" && check 0 "Stats contains zerocopy_transfers" || check 1 "Stats content"

# 5. Core debug subsystems
echo ""
echo "--- 5. Debug Subsystems ---"
[ -d /sys/kernel/debug ] && check 0 "debugfs mounted" || check 1 "debugfs mount"
DEBUG_ENTRIES=$(ls /sys/kernel/debug/ 2>/dev/null | wc -l)
echo "Debug entries: $DEBUG_ENTRIES"
[ "$DEBUG_ENTRIES" -gt 5 ] && check 0 "Debug entries > 5" || check 1 "Debug entries"

[ -d /sys/kernel/tracing ] && check 0 "tracefs mounted" || check 1 "tracefs mount"
TRACE_ENTRIES=$(ls /sys/kernel/tracing/ 2>/dev/null | wc -l)
echo "Tracing entries: $TRACE_ENTRIES"
[ "$TRACE_ENTRIES" -gt 10 ] && check 0 "Tracing entries > 10" || check 1 "Tracing entries"

# 6. Memory subsystem
echo ""
echo "--- 6. Memory Subsystem ---"
MEM_TOTAL=$(free 2>/dev/null | awk '/Mem:/{print $2}')
echo "Total memory: ${MEM_TOTAL} kB"
[ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 50000 ] && check 0 "Memory > 50MB" || check 1 "Memory size"

KSYM_COUNT=$(wc -l < /proc/kallsyms 2>/dev/null)
echo "Kernel symbols: $KSYM_COUNT"
[ "$KSYM_COUNT" -gt 30000 ] && check 0 "Kallsyms > 30000" || check 1 "Kallsyms count"

# 7. SLUB debug
echo ""
echo "--- 7. SLUB Debug ---"
SLAB_LINES=$(wc -l < /proc/slabinfo 2>/dev/null)
echo "Slabinfo lines: $SLAB_LINES"
[ "$SLAB_LINES" -gt 5 ] && check 0 "Slabinfo available" || check 1 "Slabinfo"

# 8. Process management
echo ""
echo "--- 8. Process Management ---"
PROC_COUNT=$(ls /proc/ 2>/dev/null | grep -c '^[0-9]')
echo "Running processes: $PROC_COUNT"
[ "$PROC_COUNT" -gt 0 ] && check 0 "Processes running" || check 1 "Process count"

# 9. Filesystem operations
echo ""
echo "--- 9. Filesystem Operations ---"
echo "ldm_test_data" > /tmp/ldm_test_file 2>/dev/null
[ -f /tmp/ldm_test_file ] && check 0 "File write works" || check 1 "File write"
READ_DATA=$(cat /tmp/ldm_test_file 2>/dev/null)
[ "$READ_DATA" = "ldm_test_data" ] && check 0 "File read works" || check 1 "File read"
rm -f /tmp/ldm_test_file

# 10. Network stack
echo ""
echo "--- 10. Network Stack ---"
ifconfig lo 127.0.0.1 up 2>/dev/null
LO_UP=$(ifconfig lo 2>/dev/null | grep -c "UP")
[ "$LO_UP" -gt 0 ] && check 0 "Loopback interface up" || check 1 "Loopback"

# Summary
echo ""
echo "============================================"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -eq 0 ]; then
    echo "  LDM-OS FULLY OPERATIONAL"
else
    echo "  LDM-OS HAS ISSUES (see above)"
fi
echo "============================================"

poweroff -f 2>/dev/null
