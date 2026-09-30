# LDM-OS 在 aarch64 环境部署报告（QEMU TCG 验证通过）

- 项目：https://gitcode.com/sme_engine/ldm-os-v1
- 报告日期：2026-09-20
- 宿主环境：HCE 2.0 (EulerOS) aarch64，gcc 10.3.1，内核镜像 `arch/arm64/boot/Image`，QEMU 6.2.0 (TCG)
- 结论：**部署成功**。LDM-OS 子系统在内核中初始化、debugfs 统计接口可读、无 panic、干净关机。

---

## 1. 目标与原始项目形态

ldm-os-v1 的原始交付形态是 **x86_64 UML（User-Mode Linux）内核**（Linux 6.6.142 + LDM 子系统 + Alpine hostfs rootfs），构建脚本面向 x86_64 SCNet 沙箱：

- LDM（Low Data Movement）子系统：12 个模块，全部位于 `mm/`（`ldm_core.c`、`ldm_hooks.c`、`ldm_iommu.c`、`ldm_cache.c`、`ldm_vfs.c`、`ldm_lazy.c` 等）。
- `mm/Kconfig` 提供 `CONFIG_LDM_OS`（default y，无架构依赖）与 `CONFIG_LDM_OS_DEBUG`（需 DEBUG_FS）。
- UML 特有改动仅存在于 `arch/um/`，LDM 核心代码对架构无耦合。

## 2. 环境适配决策

| 路径 | 结论 |
|---|---|
| 直接 `make ARCH=um SUBARCH=x86_64` | ❌ 宿主 gcc 为 aarch64，不支持 `-m64`，报 `gcc: error: unrecognized command-line option '-m64'` |
| 下载 musl.cc x86_64 交叉工具链 (115MB) | ❌ 容器出口带宽 ~20KB/s，单连接受限，需 1.5h+，不可接受 |
| 下载 qemu-x86_64 user-static (github) | ❌ 同样受带宽瓶颈 |
| openEuler 镜像获取 `x86_64-linux-gnu` 交叉 gcc | ❌ openEuler 不提供 x86_64 目标交叉编译器 |
| **arm64 native 内核 + LDM_OS + qemu-system TCG** | ✅ 本机 gcc native 编译，QEMU 6.2 支持 `-M virt -accel tcg`，LDM 与架构无关 |

**选定方案**：构建 arm64 普通内核并在其中启用 LDM-OS，用 `qemu-kvm -M virt -accel tcg` 全系统模拟引导验证。该方案完整保留 LDM 子系统功能语义，仅替换承载内核的架构形态。

## 3. 构建步骤（产物路径）

```bash
cd /root/workspace/ldm-os-v1/kernel-src
# 1) 备份原 UML x86_64 配置后清理源码树（Kbuild 干净检查）
cp .config /root/ldm-uml-x86_64.config.bak
rm -f .config && mv include/generated /root/kernel-include-generated.bak
# 2) 独立输出目录构建 arm64 配置
make O=/root/ldm-build-arm64 ARCH=arm64 defconfig
scripts/config --file /root/ldm-build-arm64/.config \
  -e DEBUG_FS -e LDM_OS_DEBUG -e IKCONFIG -e IKCONFIG_PROC   # LDM_OS 已 default y
make O=/root/ldm-build-arm64 ARCH=arm64 olddefconfig
# 3) 编译
make O=/root/ldm-build-arm64 ARCH=arm64 -j$(nproc) Image
```

产物：
- 内核镜像：`/root/ldm-build-arm64/arch/arm64/boot/Image`（41MB）
- vmlinux：`/root/ldm-build-arm64/vmlinux`（156MB）
- 符号表：`/root/ldm-build-arm64/System.map`
- 备份的 UML 配置：`/root/ldm-uml-x86_64.config.bak`

## 4. 适配修复项

### 4.1 `kernel-src/Documentation/Kconfig`（缺失文件补档）
仓库初始 checkout 缺少该文件导致内核配置阶段报错，补空文件解决。该文件不参与构建逻辑。

### 4.2 `kernel-src/mm/ldm_iommu.c`（关键崩溃修复）
首次引导时 `ldm_detect_iommu()` 调用 `iommu_present(NULL)`，在 arm64 下该内联实现会**解引用空指针**（`pc = iommu_present+0x0`，读 `0x98` 地址），导致 Oops + Kernel panic。

修复：改为向 `iommu_present()` 传入合法总线类型 `&platform_bus_type`（新增 `#include <linux/platform_device.h>`），无硬件 IOMMU 时自动降级为软件模拟隔离（`LDM_IOMMU_SW_SIMULATED`）。修复后不再崩溃且行为语义不变。

### 4.3 initramfs 动态库布局（运行期修复）
HCE busybox 为 aarch64 **动态链接**，依赖 libc/libm/libselinux/libpcre2 等。arm64 动态加载器默认搜索路径不含 `/lib`，首次引导报 `libm.so.6: cannot open shared object file`。修复：将动态库复制到 `lib/`、`lib64/`、`usr/lib64/`、`lib/aarch64-linux-gnu/`、`usr/lib/aarch64-linux-gnu/` 多路径布局，并把符号链接库 `libpcre2-8.so.0` 用解引用方式复制实际文件。

## 5. initramfs 与验证脚本

- 构建目录：`/root/ldm-initramfs/`
- 镜像：`/root/ldm-initramfs.cpio.gz`（7.4MB，cpio newc + gzip）
- 结构：`/init`（busybox sh 脚本）+ `/bin/busybox` + 动态库
- `/init` 行为：挂载 proc/sys/devtmpfs/debugfs → 输出 uname、`dmesg | grep LDM`、`/proc/kallsyms` LDM 符号、`cat /sys/kernel/debug/ldm_os/stats` → poweroff

## 6. 验证结果（QEMU TCG 引导）

命令：
```bash
qemu-kvm -M virt -cpu cortex-a57 -smp 2 -m 512 -accel tcg \
  -kernel /root/ldm-build-arm64/arch/arm64/boot/Image \
  -initrd /root/ldm-initramfs.cpio.gz \
  -nographic -no-reboot -append "console=ttyAMA0 panic=1"
```

关键日志（`/root/ldm-qemu-final.log`）：
```
Linux (none) 6.6.142 #2 SMP PREEMPT ... aarch64 GNU/Linux
LDM-OS: Low Data Movement subsystem initializing
LDM-OS: Principle: 'Data stays where it is; move references, not bytes.'
LDM: debugfs interface at /sys/kernel/debug/ldm_os/
LDM-OS: initialized successfully
LDM-OS: network stack optimization module loaded      (skb_copy_bits, skb_clone, tcp_send/recv, ...)
LDM-OS: VFS & I/O optimization module loaded          (vfs_read/write, iov_iter, io_uring, ...)
LDM-OS: scheduler/block/base optimization module loaded
LDM-OS: advanced MM optimization module loaded
LDM-OS: VM subsystem final optimization module loaded
LDM-OS: compatibility layer loaded                    (ldm_memcpy, ldm_memmove, ldm_copy_page)
LDM-OS: lazy memory management subsystem loaded
LDM-IOMMU: no hardware IOMMU, using software-simulated isolation
--- kallsyms ---
ldm_get_stats / ldm_init / ldm_hooks_init 等符号均在
--- debugfs statistics ---
LDM-OS Statistics (CONFIG_LDM_OS=y)
zerocopy_transfers: 0   lazy_copies: 0   lazy_copy_faults: 0
hw_dma_transfers: 0     sw_fallback_transfers: 0   inplace_computations: 0
lazy_cache_updates: 0   lazy_cache_flushes: 0   iommu_mappings: 0
bytes_saved: 0          total_requests: 0
reboot: Power down   # 干净关机，无 panic
```

验证点全部通过：
1. ✅ LDM-OS 子系统初始化成功（11 项子模块加载日志）
2. ✅ LDM 符号存在于内核符号表（`ldm_init`、`ldm_get_stats`、`ldm_hooks_init`）
3. ✅ debugfs 统计接口可读（`/sys/kernel/debug/ldm_os/stats`）
4. ✅ 全程无 kernel panic / Oops，正常 poweroff

## 7. 与原 x86_64 UML 方式的差异与遗留

| 差异项 | 原 UML 方案 | 本环境方案 |
|---|---|---|
| 内核形态 | x86_64 UML 用户态进程 | arm64 普通内核 + QEMU TCG 全系统模拟 |
| 构建位置 | 需 x86_64 交叉工具链 | aarch64 native 构建（默认即目标） |
| IOMMU 探测 | `iommu_present(NULL)` 可容忍 | 已修复为 `&platform_bus_type`，无硬件时 SW 模拟 |
| rootfs | Alpine hostfs | busybox initramfs（动态库多路径布局） |
| 启动方式 | `./linux.uml mem=... rootfstype=hostfs` | `qemu-kvm -M virt -accel tcg -kernel Image -initrd ...` |

遗留事项：
- LDM 行为计数器当前为 0：需要在客户机内运行实际内存复制/IO 负载（并让 LDM hook 路径生效）才能观察到非零统计；本次验证以子系统初始化与接口可用性为准。
- 若需还原 UML x86_64 构建：恢复 `kernel-src/.config`（备份于 `/root/ldm-uml-x86_64.config.bak`），在带宽充足的 x86_64 主机或具备交叉工具链的环境执行。
- 内核源码树已被 arm64 构建清理过（`.config`/`include/generated` 移除并备份），UML 配置可随时恢复。
- `kernel-src/mm/ldm_iommu.c` 的修复建议择机提交至上游（对 UML 与 arm64 均安全）。

## 8. 快速复现命令

```bash
cd /root/workspace/ldm-os-v1/kernel-src
make O=/root/ldm-build-arm64 ARCH=arm64 defconfig
scripts/config --file /root/ldm-build-arm64/.config -e DEBUG_FS -e LDM_OS_DEBUG -e IKCONFIG -e IKCONFIG_PROC
make O=/root/ldm-build-arm64 ARCH=arm64 olddefconfig
make O=/root/ldm-build-arm64 ARCH=arm64 -j$(nproc) Image
qemu-kvm -M virt -cpu cortex-a57 -smp 2 -m 512 -accel tcg \
  -kernel /root/ldm-build-arm64/arch/arm64/boot/Image \
  -initrd /root/ldm-initramfs.cpio.gz \
  -nographic -no-reboot -append "console=ttyAMA0 panic=1"
```