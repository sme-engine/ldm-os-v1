# LDM-OS v1 — QEMU Guest OS 级验证报告（aarch64 / AArch64 / 鲲鹏920）

- 日期：2026-09-20
- 宿主：aarch64（鲲鹏920 容器）
- 内核：`/root/ldm-build-arm64/arch/arm64/boot/Image`（CONFIG_LDM_OS=y）
- 引导：`qemu-kvm -M virt -cpu cortex-a57 -smp 2 -m 512 -accel tcg`（TCG 无 KVM 依赖）
- initramfs：`/root/ldm-initramfs-bench.cpio.gz`（busybox 动态链接 + 多路径 lib 布局 + guest 验证 init）
- 完整日志：`/root/ldm-qemu-bench4.log`

## 结论

**OS 级测试 53/53 PASS（0 FAIL）**；两个用户态 benchmark 在 guest 内原生运行成功；
内核 LDM-OS 全套子系统初始化成功；debugfs 统计可读；无 panic/Oops；干净 poweroff。

## 1. 内核 LDM-OS 初始化（guest dmesg / kallsyms）

```
[    0.359656] LDM-OS: Low Data Movement subsystem initializing
[    0.359880] LDM-OS: Principle: 'Data stays where it is; move references, not bytes.'
[    0.360491] LDM-OS: initialized successfully
[    0.360683] LDM-OS: network stack optimization module loaded
[    0.360862] LDM-OS: hooks: skb_copy_bits, skb_clone, tcp_send/recv, ip_append, tun, gro, skb_alloc
[    0.361203] LDM-OS: VFS & I/O optimization module loaded
[    0.361372] LDM-OS: hooks: vfs_read/write, iov_iter, io_uring, dma_map, sg_copy, sendfile
[    0.361664] LDM-OS: scheduler/block/base optimization module loaded
...
[    0.501690] LDM-OS: lazy copy, lazy zero, lazy TLB, lazy reclaim active
[    0.502550] LDM-OS: IOMMU abstraction layer loaded (mode=SW)
[    0.503706] LDM-OS: deep hooks loaded (second-pass optimization)
```

debugfs 统计：`/sys/kernel/debug/ldm_os/stats` 可读（zerocopy_transfers / lazy_copies / lazy_copy_faults / iommu_mappings / bytes_saved 等）。

## 2. OS 级测试套件（test_os_safe.sh，guest 内原生执行）

```
FILE SYSTEM (10/10 PASS):  dd write/read/4KB blocks, cp 4MB, tar, find, ls -R, chmod, symlink, mkdir/rmdir
MEMORY     (6/6 PASS):     dd 64MB copy, memcpy 4MB, mmap sim, page cache, /proc/meminfo, /proc/slabinfo
PROC/CPU   (5/5 PASS):     /proc/cpuinfo, /proc/uptime, /proc/stat, /proc/loadavg, uname
THREAD/PROC(5/5 PASS):     fork, exec, threads, signals, pipes
CLI TOOLS  (14/14 PASS):   grep, sed, awk, sort, wc, cut, uniq, head/tail, echo/printf, test/true, cp/mv, ln, chmod2, expr/seq
COMPRESSION(5/5 PASS):     gzip, bzip2, base64, md5sum, sha256sum
NETWORK    (3/3 PASS):     lo up, /proc/net/tcp, socketpair
MISC       (5/5 PASS):     env, date, sleep, /dev/null rw, /proc/version

RESULTS:  53 PASS    0 FAIL   53 TOTAL
```

## 3. Guest 内用户态 benchmark 冒烟（原生 aarch64）

- `ldm_benchmark --rounds 2--size 16`：完成（Total data 7.7GB，Avg throughput 512.0 MB/s，Mode: LDM-OFF 段正常）
- `ldm_api_bench --rounds 3`：weight_lifecycle / activation_fwd_bwd / cross_domain_share / kv_cache_management / db_buffer_pool 全部输出

## 4. 验证中发现并修复的基础设施问题

1. **guest 内缺 busybox applet 符号链接**：原始 initramfs 仅有 `bin/busybox`，`/bin/sh` 不存在，
   `test_os_safe.sh` 的 `#!/bin/sh` shebang 在 exec 时报 `not found`。
   修复：`busybox --install .` 硬链接安装 370 个 applet（不能用 `--install -s` 软链——其目标为宿主绝对路径，guest 内断链）。
2. **guest 内 `/etc/` 为空**：`wc`/`cut` 两项读 `/etc/passwd` 失败 → FAIL。
   修复：initramfs 补齐 `etc/passwd`、`etc/hostname`、`etc/hosts`。
3. **`dd` applet 缺失**（宿主 busybox 未编译 dd）：复制宿主 `/usr/bin/dd`（仅依赖 libc，initramfs 已具备）进 `/bin/dd`。

以上修复已固化到 `scripts/adapt_arm64_build.sh` 的 `build_initramfs()`，后续重建 initramfs 开箱即用。

## 5. 复现命令

```bash
# 构建（含 applet 硬链接 + /etc 基础文件）
./scripts/adapt_arm64_build.sh

# 手动 guest 验证
qemu-kvm -M virt -cpu cortex-a57 -smp 2 -m 512 -accel tcg \
  -kernel /root/ldm-build-arm64/arch/arm64/boot/Image \
  -initrd /root/ldm-initramfs-bench.cpio.gz \
  -nographic -no-reboot \
  -append "console=ttyAMA0 panic=1 rdinit=/init"
```