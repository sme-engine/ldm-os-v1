#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

echo "============================================"
echo "  LDM-OS Full Verification Report"
echo "============================================"
echo ""
echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"
echo ""

echo "--- LDM Config ---"
zcat /proc/config.gz 2>/dev/null | grep "CONFIG_LDM" || echo "N/A"
echo ""

echo "--- LDM Kernel Symbols ---"
LDM_SYMS=$(grep -c "ldm_" /proc/kallsyms 2>/dev/null)
echo "Total LDM symbols: $LDM_SYMS"
echo ""
echo "Core API:"
grep " T ldm_\| t ldm_" /proc/kallsyms 2>/dev/null | awk '{print "  " $3}' | sort
echo ""

echo "--- LDM Core Stats ---"
cat /sys/kernel/debug/ldm_os/stats 2>/dev/null || echo "N/A"
echo ""

echo "--- Memory ---"
free 2>/dev/null
echo ""

echo "--- Kallsyms Count ---"
wc -l /proc/kallsyms 2>/dev/null
echo ""

echo "============================================"
echo "  LDM-OS VERIFICATION COMPLETE"
echo "============================================"
poweroff -f 2>/dev/null
