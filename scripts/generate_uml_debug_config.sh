#!/bin/bash
# =============================================================================
# Alpine UML Debug Kernel Configuration Generator
# 
# Purpose: Generate a comprehensive kernel .config for UML with ALL debug
#          options enabled, suitable for source-level debugging via gdb/kgdb.
#
# Base:    Alpine v3.20 virt config + UML x86_64 defconfig
# Target:  User-Mode Linux (arch/um) with full debuggability
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
KERNEL_SRC="${WORKSPACE}/src/linux"
OUTPUT_CONFIG="${WORKSPACE}/kernel/.config.uml-debug"
ALPINE_VIRT_CONFIG="${WORKSPACE}/src/alpine-virt.config"
UML_DEFCONFIG="${KERNEL_SRC}/arch/um/configs/x86_64_defconfig"

echo "[CONFIG] Generating UML Debug Kernel Configuration"
echo "[CONFIG] Kernel Source: ${KERNEL_SRC}"
echo "[CONFIG] Alpine Virt Base: ${ALPINE_VIRT_CONFIG}"
echo "[CONFIG] UML Defconfig: ${UML_DEFCONFIG}"

# Step 1: Start from UML defconfig
cd "${KERNEL_SRC}"
make ARCH=um KCONFIG_ALLCONFIG="${UML_DEFCONFIG}" alldefconfig 2>/dev/null || \
  cp "${UML_DEFCONFIG}" .config

# Step 2: Apply comprehensive debug overlay
cat >> .config << 'DEBUG_OVERLAY'

# =============================================================================
# CORE DEBUG OPTIONS
# =============================================================================
CONFIG_DEBUG_KERNEL=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
CONFIG_DEBUG_INFO_REDUCED=n
CONFIG_DEBUG_INFO_SPLIT=n
CONFIG_GDB_SCRIPTS=y
CONFIG_FRAME_POINTER=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_KALLSYMS_ABSOLUTE_PERCPU=y
CONFIG_KALLSYMS_BASE_RELATIVE=y

# =============================================================================
# KERNEL HACKING / DEBUGGING
# =============================================================================
CONFIG_PRINTK_TIME=y
CONFIG_DYNAMIC_DEBUG=y
CONFIG_DYNAMIC_DEBUG_CORE=y
CONFIG_SYMBOLIC_ERRNAME=y
CONFIG_DEBUG_BUGVERBOSE=y
CONFIG_DEBUG_FS=y
CONFIG_DEBUG_FS_ALLOW_ALL=y

# =============================================================================
# MEMORY DEBUGGING
# =============================================================================
CONFIG_DEBUG_PAGEALLOC=y
CONFIG_DEBUG_PAGEALLOC_ENABLE_DEFAULT=y
CONFIG_SLUB_DEBUG=y
CONFIG_SLUB_DEBUG_ON=y
CONFIG_DEBUG_OBJECTS=y
CONFIG_DEBUG_OBJECTS_SELFTEST=y
CONFIG_DEBUG_OBJECTS_FREE=y
CONFIG_DEBUG_OBJECTS_TIMERS=y
CONFIG_DEBUG_OBJECTS_WORK=y
CONFIG_DEBUG_OBJECTS_RCU_HEAD=y
CONFIG_DEBUG_OBJECTS_PERCPU_COUNTER=y
CONFIG_DEBUG_STACKOVERFLOW=y
CONFIG_HAVE_DEBUG_STACKOVERFLOW=y
CONFIG_DEBUG_MEMORY_INIT=y
CONFIG_DEBUG_SG=y
CONFIG_DEBUG_NOTIFIERS=y
CONFIG_DEBUG_CREDENTIALS=y

# =============================================================================
# LOCK DEBUGGING
# =============================================================================
CONFIG_PROVE_LOCKING=y
CONFIG_PROVE_RAW_LOCK_NESTING=y
CONFIG_DEBUG_LOCK_ALLOC=y
CONFIG_DEBUG_SPINLOCK=y
CONFIG_DEBUG_MUTEXES=y
CONFIG_DEBUG_WW_MUTEX_SLOWPATH=y
CONFIG_DEBUG_RWSEMS=y
CONFIG_DEBUG_LOCKDEP=y
CONFIG_DEBUG_ATOMIC_SLEEP=y
CONFIG_TRACE_IRQFLAGS=y
CONFIG_STACKTRACE=y
CONFIG_DEBUG_LIST=y
CONFIG_DEBUG_PLIST=y

# =============================================================================
# TRACING & PROFILING
# =============================================================================
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_IRQSOFF_TRACER=y
CONFIG_PREEMPT_TRACER=y
CONFIG_SCHED_TRACER=y
CONFIG_HWLAT_TRACER=y
CONFIG_OSNOISE_TRACER=y
CONFIG_TIMERLAT_TRACER=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_BLK_DEV_IO_TRACE=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_DYNAMIC_FTRACE_WITH_REGS=y
CONFIG_FUNCTION_PROFILER=y
CONFIG_STACK_TRACER=y
CONFIG_HIST_TRIGGERS=y
CONFIG_TRACER_SNAPSHOT=y
CONFIG_TRACER_MAX_TRACE=y
CONFIG_RING_BUFFER=y
CONFIG_EVENT_TRACING=y
CONFIG_TRACEPOINTS=y

# =============================================================================
# KGDB / REMOTE DEBUGGING
# =============================================================================
CONFIG_KGDB=y
CONFIG_KGDB_SERIAL_CONSOLE=y
CONFIG_KGDB_TESTS=y
CONFIG_KGDB_TESTS_ON_BOOT=n
CONFIG_KGDB_LOW_LEVEL_TRAP=y
CONFIG_KGDB_KDB=y
CONFIG_KDB_KEYBOARD=y

# =============================================================================
# UML-SPECIFIC DEBUG
# =============================================================================
CONFIG_UML_NET=y
CONFIG_UML_NET_VECTOR=y
CONFIG_UML_NET_VDE=y
CONFIG_UML_NET_PCAP=y
CONFIG_HOSTFS=y
CONFIG_MCONSOLE=y
CONFIG_MAGIC_SYSRQ=y
CONFIG_EARLY_PRINTK=y
CONFIG_UML_RANDOM=y
CONFIG_NULL_CHAN=y
CONFIG_PORT_CHAN=y
CONFIG_PTY_CHAN=y
CONFIG_TTY_CHAN=y
CONFIG_XTERM_CHAN=y
CONFIG_CON_CHAN="xterm"
CONFIG_SSL_CHAN="pty"
CONFIG_UML_SOUND=m
CONFIG_UML_WATCHDOG=y

# =============================================================================
# FILESYSTEM SUPPORT (minimal but complete for Alpine)
# =============================================================================
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_CONFIGFS_FS=y
CONFIG_RAMFS=y
CONFIG_OVERLAY_FS=m

# =============================================================================
# NETWORKING (for UML network debugging)
# =============================================================================
CONFIG_NET=y
CONFIG_INET=y
CONFIG_UNIX=y
CONFIG_NET_CORE=y
CONFIG_NETDEVICES=y
CONFIG_TUN=y
CONFIG_VETH=m

# =============================================================================
# SECURITY AUDITING
# =============================================================================
CONFIG_AUDIT=y
CONFIG_AUDITSYSCALL=y
CONFIG_SECURITY=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_NETWORK=y

# =============================================================================
# ADDITIONAL DIAGNOSTICS
# =============================================================================
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_LOG_BUF_SHIFT=17
CONFIG_LOG_CPU_MAX_BUF_SHIFT=17
CONFIG_PRINTK_CALLER=y
CONFIG_PANIC_ON_OOPS=y
CONFIG_PANIC_TIMEOUT=-1
CONFIG_DETECT_HUNG_TASK=y
CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=120
CONFIG_BOOTPARAM_HUNG_TASK_PANIC=n
CONFIG_WQ_WATCHDOG=y
CONFIG_SCHEDSTATS=y
CONFIG_SCHED_DEBUG=y
CONFIG_LATENCYTOP=y
CONFIG_USER_STACKTRACE_SUPPORT=y
CONFIG_NOP_TRACER=y
CONFIG_HAVE_FUNCTION_TRACER=y
CONFIG_HAVE_FUNCTION_GRAPH_TRACER=y
CONFIG_HAVE_DYNAMIC_FTRACE=y
CONFIG_HAVE_DYNAMIC_FTRACE_WITH_REGS=y
CONFIG_HAVE_FENTRY=y
DEBUG_OVERLAY

echo "[CONFIG] Debug overlay applied"

# Step 3: Run olddefconfig to resolve dependencies
make ARCH=um olddefconfig 2>&1 | tail -5

# Step 4: Copy final config
cp .config "${OUTPUT_CONFIG}"

# Step 5: Verify critical debug options
echo ""
echo "=== Critical Debug Options Verification ==="
CRITICAL_OPTS=(
  "CONFIG_DEBUG_INFO"
  "CONFIG_DEBUG_KERNEL"
  "CONFIG_KGDB"
  "CONFIG_KGDB_SERIAL_CONSOLE"
  "CONFIG_FTRACE"
  "CONFIG_FUNCTION_TRACER"
  "CONFIG_DEBUG_LOCK_ALLOC"
  "CONFIG_PROVE_LOCKING"
  "CONFIG_DEBUG_PAGEALLOC"
  "CONFIG_SLUB_DEBUG"
  "CONFIG_FRAME_POINTER"
  "CONFIG_KALLSYMS_ALL"
  "CONFIG_DYNAMIC_DEBUG"
  "CONFIG_HOSTFS"
  "CONFIG_MCONSOLE"
  "CONFIG_MAGIC_SYSRQ"
  "CONFIG_DEBUG_FS"
  "CONFIG_STACK_TRACER"
  "CONFIG_EARLY_PRINTK"
)

PASS=0
FAIL=0
for opt in "${CRITICAL_OPTS[@]}"; do
  val=$(grep "^${opt}=" "${OUTPUT_CONFIG}" 2>/dev/null | head -1)
  if [ -n "$val" ] && [[ ! "$val" =~ "=n$" ]]; then
    echo "  [OK] $val"
    ((PASS++))
  else
    echo "  [!!] ${opt} NOT ENABLED"
    ((FAIL++))
  fi
done

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
echo "[CONFIG] Output: ${OUTPUT_CONFIG}"
echo "[CONFIG] Total config lines: $(wc -l < "${OUTPUT_CONFIG}")"
echo "[CONFIG] Enabled options: $(grep -c '^CONFIG_.*=y\|^CONFIG_.*=m' "${OUTPUT_CONFIG}")"
