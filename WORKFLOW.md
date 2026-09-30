# Alpine Linux UML Debug Build Workflow

## Overview

Complete workflow for building a debug-enabled Alpine Linux kernel targeting
User-Mode Linux (UML), verified on SCNet (华东一区【昆山】) sandbox environment.

**Key properties:**
- Kernel: Linux 6.6.142 (Alpine v3.20 aligned)
- Architecture: UML (x86_64 user-mode)
- Rootfs: Alpine busybox-static with full debug filesystem mounts
- Debug features: DEBUG_INFO, SLUB_DEBUG, FTRACE, KALLSYMS_ALL, DYNAMIC_DEBUG, etc.
- No root/KVM/container required — pure user-space execution

## Directory Structure

```
alpine-uml-workspace/
├── scripts/
│   ├── env.sh                    # Master environment setup
│   ├── generate_uml_debug_config.sh  # Kernel .config generator
│   ├── build_uml_kernel.sh       # Kernel build script
│   ├── build_rootfs.sh           # Rootfs builder
│   └── run_uml.sh                # UML launch & debug script
├── src/
│   ├── linux -> linux-6.6.142    # Kernel source symlink
│   ├── linux-6.6.142/            # Full kernel source tree
│   ├── alpine-virt.config        # Reference Alpine virt config
│   └── busybox-extract/          # Extracted busybox-static binary
├── kernel/
│   └── .config.uml-debug         # Generated debug kernel config
├── rootfs/                       # Built rootfs directory (hostfs mode)
├── output/
│   ├── linux.uml                 # Compiled UML kernel (113MB, with debug_info)
│   ├── System.map                # Kernel symbol table
│   ├── .config                   # Final kernel config used
│   └── alpine-uml-rootfs.cpio.gz # CPIO rootfs archive
├── logs/                         # Build logs
├── toolchain/
│   └── env.sh                    # Legacy toolchain env (use scripts/env.sh)
└── uml-bullseye/                 # Debian bullseye UML binary (fallback)
```

## Quick Start

```bash
# 1. Setup environment
source scripts/env.sh

# 2. Generate debug kernel config
bash scripts/generate_uml_debug_config.sh

# 3. Build kernel (takes ~5 minutes on 8 cores)
bash scripts/build_uml_kernel.sh --jobs 8

# 4. Build rootfs
bash scripts/build_rootfs.sh

# 5. Test boot
bash scripts/run_uml.sh test

# 6. Interactive debug shell
bash scripts/run_uml.sh shell

# 7. GDB source-level debugging
bash scripts/run_uml.sh gdb
```

## Verified Debug Features

| Feature | Config | Status | Verification |
|---------|--------|--------|-------------|
| DWARF debug info | CONFIG_DEBUG_INFO=y | ✅ | `readelf -S linux.uml \| grep debug` → 7 sections |
| Frame pointers | CONFIG_FRAME_POINTER=y | ✅ | Stack traces in panic/oops |
| All kernel symbols | CONFIG_KALLSYMS_ALL=y | ✅ | `/proc/kallsyms` → 45,735 symbols |
| SLUB debugging | CONFIG_SLUB_DEBUG=y | ✅ | `/proc/slabinfo` with debug fields |
| Ftrace framework | CONFIG_FTRACE=y | ✅ | `/sys/kernel/tracing/` → 34 entries |
| Dynamic debug | CONFIG_DYNAMIC_DEBUG=y | ✅ | `/sys/kernel/debug/dynamic_debug/` |
| Debug objects | CONFIG_DEBUG_OBJECTS=y | ✅ | `/sys/kernel/debug/debug_objects/` |
| Scheduler debug | CONFIG_SCHED_DEBUG=y | ✅ | `/sys/kernel/debug/sched/` |
| Latency top | CONFIG_LATENCYTOP=y | ✅ | Latency tracking enabled |
| Stack traces | CONFIG_STACKTRACE=y | ✅ | Available for all debug subsystems |
| Magic SysRq | CONFIG_MAGIC_SYSRQ=y | ✅ | Emergency debug via console |
| Mconsole | CONFIG_MCONSOLE=y | ✅ | Runtime management socket |
| HostFS | CONFIG_HOSTFS=y | ✅ | Direct host filesystem access |
| Security/Audit | CONFIG_SECURITY=y, CONFIG_AUDIT=y | ✅ | LSM and audit framework |
| IKCONFIG | CONFIG_IKCONFIG=y | ✅ | `/proc/config.gz` available |

## Known Limitations & Workarounds

### /dev/shm Size (64MB on SCNet)
The SCNet sandbox has only 64MB of `/dev/shm`. UML uses shm for memory mapping.
- **Workaround**: Use `mem=128M` or less; use `rootfstype=hostfs` instead of initrd
- **Impact**: Limits maximum guest memory to ~128MB

### PROVE_LOCKING Early Boot Panic
`CONFIG_PROVE_LOCKING=y` causes a SIGSEGV during early boot on UML with GCC 8.4.
- **Workaround**: Disabled in final config; `DEBUG_LOCK_ALLOC` remains enabled
- **Impact**: Lock ordering validation unavailable at runtime; compile-time checks still active

### KGDB / FUNCTION_TRACER
Not supported on UML architecture (hardware-dependent features).
- **Alternative**: Use `gdb ./linux.uml` directly (UML is a regular process)
- **Alternative**: Use ftrace for function-level tracing

## Modifying Alpine Source Code (Second Iteration)

When you're ready to modify the Alpine kernel source:

```bash
# 1. Edit source files
vi src/linux/arch/um/kernel/skas/process.c  # example

# 2. Incremental rebuild (only recompiles changed files)
source scripts/env.sh
cd $KERNEL_SRC
make ARCH=um M4="$M4" BISON_PKGDATADIR="$BISON_PKGDATADIR" -j8

# 3. Copy new binary
cp linux $OUTPUT_DIR/linux.uml

# 4. Test immediately
bash scripts/run_uml.sh test
```

## GDB Debugging Guide

```bash
# Start UML under GDB
bash scripts/run_uml.sh gdb

# In GDB:
(gdb) break start_kernel          # Break at kernel entry
(gdb) break do_initcalls          # Break at init call sequence
(gdb) continue                     # Run to breakpoint
(gdb) info threads                 # List UML threads
(gdb) bt                           # Backtrace
(gdb) print task_struct->comm      # Inspect current task
(gdb) list                         # Show source around PC

# Attach to running UML (from another terminal):
(gdb) attach <pid>
```

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| UML_MEM | 256M | Guest memory size |
| UML_KERNEL | output/linux.uml | Path to UML kernel binary |
| UML_ROOTFS | output/alpine-uml-rootfs.cpio.gz | Path to rootfs archive |
| UML_EXTRA_ARGS | (empty) | Additional kernel cmdline args |
| AIAOS_CHAT_MAX_ATTEMPTS | 7 | Chat retry budget |
| AIAOS_CHAT_MAX_DELAY | 90.0 | Chat max backoff seconds |
