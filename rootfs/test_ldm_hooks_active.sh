#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

echo "=== LDM Hooks Activity Verification ==="
echo ""

# Check hooks_stats exists
if [ -f /sys/kernel/debug/ldm_os/hooks_stats ]; then
    echo "[PASS] hooks_stats debugfs file exists"
else
    # It might be at a different path since we didn't put it under ldm_os dir
    echo "[INFO] Checking alternative paths..."
fi

# Check all LDM debugfs files
echo ""
echo "--- All LDM debugfs entries ---"
find /sys/kernel/debug -name "*ldm*" -o -name "*hooks*" -o -name "*lazy*" -o -name "*cache*" -o -name "*iommu*" 2>/dev/null | while read f; do
    echo "  $f"
done

# Read hooks stats if available
for f in /sys/kernel/debug/ldm_os/hooks_stats /sys/kernel/debug/hooks_stats; do
    if [ -f "$f" ]; then
        echo ""
        echo "--- hooks_stats content ---"
        cat "$f"
        break
    fi
done

# Read core stats
echo ""
echo "--- Core LDM stats ---"
cat /sys/kernel/debug/ldm_os/stats 2>/dev/null || echo "N/A"

# Generate some memory activity to trigger hooks
echo ""
echo "--- Generating memory activity ---"
dd if=/dev/zero of=/tmp/ldm_test bs=4096 count=100 2>/dev/null
cp /tmp/ldm_test /tmp/ldm_test2 2>/dev/null
cat /tmp/ldm_test > /dev/null 2>/dev/null
rm -f /tmp/ldm_test /tmp/ldm_test2

# Check kallsyms for hook symbols
echo ""
echo "--- Hook symbols in kallsyms ---"
grep "ldm_.*hook\|ldm_copy_page" /proc/kallsyms 2>/dev/null | head -10

echo ""
echo "=== HOOKS VERIFICATION COMPLETE ==="
poweroff -f 2>/dev/null
