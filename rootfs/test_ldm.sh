#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

echo "=== LDM-OS Verification ==="
echo "Kernel: $(uname -r)"

echo ""
echo "--- LDM Config ---"
zcat /proc/config.gz 2>/dev/null | grep "CONFIG_LDM" || echo "IKCONFIG check"

echo ""
echo "--- LDM DebugFS Stats ---"
cat /sys/kernel/debug/ldm_os/stats 2>/dev/null || echo "debugfs not available"

echo ""
echo "--- Kernel Symbols (LDM) ---"
grep -c "ldm_" /proc/kallsyms 2>/dev/null || echo "N/A"
echo "LDM symbols:"
grep " T ldm_\| t ldm_" /proc/kallsyms 2>/dev/null | head -20

echo ""
echo "--- Memory Info ---"
free 2>/dev/null

echo ""
echo "=== LDM-OS VERIFICATION COMPLETE ==="
poweroff -f 2>/dev/null
