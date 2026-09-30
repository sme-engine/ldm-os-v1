#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs none /sys/kernel/debug 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
mount -o remount,rw / 2>/dev/null
/test_enterprise.sh
echo "BENCHMARK_EXIT_CODE=$?"
sleep 1
echo o > /proc/sysrq-trigger 2>/dev/null || true
