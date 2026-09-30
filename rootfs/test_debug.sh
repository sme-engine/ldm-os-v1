#!/bin/sh
# Mount essential filesystems first
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null

echo "=== UML DEBUG VERIFICATION ==="
echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"
echo ""

echo "--- /proc/kallsyms ---"
KSYM_COUNT=$(wc -l < /proc/kallsyms 2>/dev/null)
echo "Symbols: ${KSYM_COUNT:-N/A}"

echo "--- /sys/kernel/debug entries ---"
DEBUG_COUNT=$(ls /sys/kernel/debug/ 2>/dev/null | wc -l)
echo "Debug entries: ${DEBUG_COUNT}"
ls /sys/kernel/debug/ 2>/dev/null | head -10

echo "--- /sys/kernel/tracing ---"
TRACE_COUNT=$(ls /sys/kernel/tracing/ 2>/dev/null | wc -l)
echo "Tracing entries: ${TRACE_COUNT}"

echo "--- SLUB Debug (/proc/slabinfo) ---"
head -5 /proc/slabinfo 2>/dev/null || echo "N/A"

echo "--- Memory ---"
free 2>/dev/null

echo "--- Kernel Config (IKCONFIG) ---"
if [ -f /proc/config.gz ]; then
    zcat /proc/config.gz 2>/dev/null | grep -E "^CONFIG_(DEBUG_INFO|SLUB_DEBUG|FTRACE|KALLSYMS_ALL|MAGIC_SYSRQ|HOSTFS|MCONSOLE|FRAME_POINTER|DYNAMIC_DEBUG|STACKTRACE|SCHED_DEBUG|LATENCYTOP|DEBUG_OBJECTS|SECURITY|AUDIT)=" | sort
else
    echo "IKCONFIG not available at /proc/config.gz"
fi

echo "--- dmesg (last 5 lines) ---"
dmesg 2>/dev/null | tail -5

echo ""
echo "=== ALL CHECKS COMPLETE ==="
poweroff -f 2>/dev/null
