# LDM-OS AArch64 / Kunpeng 920 适配脚本集

将 ldm-os-v1 在华为云 EulerOS **aarch64（Kunpeng 920）** 环境下的完整适配流程脚本化：
内核构建 → initramfs 组装 → QEMU 启动验证 → benchmark 全量评测 → 结果聚合。
所有脚本均已在本环境实际跑通（guest 内核级验证 **53 PASS / 0 FAIL**）。

## 目录

| 脚本 | 作用 |
|---|---|
| `common.sh` | 公共环境：路径、QEMU 自动探测、aarch64/glibc 依赖解析助手 |
| `01_check_env.sh` | 前提检查（arch、工具链、内核源码、busybox/dd/glibc、QEMU） |
| `02_build_kernel.sh` | 构建 arm64 内核 `arch/arm64/boot/Image`（O= 独立输出目录） |
| `03_build_initramfs.sh` | 组装可启动 initramfs（动态库多路径闭包 + dd + 脚本型 /init） |
| `04_run_qemu_verify.sh` | QEMU `-M virt` (TCG) 启动 guest 并运行 53 项 OS 验证套件 |
| `05_run_benchmarks.sh` | 编译并运行 8 个 benchmark 套件（trad + LDM，默认 50 轮） |
| `06_aggregate_report.sh` | 聚合 CSV/txt，生成 `aggregated.csv` 与对比报告 Markdown |
| `run_all_aarch64.sh` | 一键串起 01→06（可用 `SKIP_KERNEL=1` / `SKIP_BENCH=1` 跳过） |

## 快速使用

```bash
./run_all_aarch64.sh                 # 全流程（默认 ROUNDS=50）
# 或按步骤执行：
./01_check_env.sh
./02_build_kernel.sh                 # 已有数据可复用 SKIP_KERNEL=1
./03_build_initramfs.sh
./04_run_qemu_verify.sh /root/ldm-qemu-verify.log
./05_run_benchmarks.sh --rounds 50
./06_aggregate_report.sh
```

## 源码修改标记（ARM64-ADAPT）

本适配对 LDM 内核模块的改动分为两类，明确区分：

- **通用代码（不改）**：`src/mm/*.c`、`src/include/linux/ldm_os.h` 保持原始
  通用实现，架构无关，不在任何地方改动或加标记。
- **arm64 专属修改（显式标记）**：仅出现在 arm64 构建树
  `kernel-src/mm/`，统一以 `ARM64-ADAPT` 注释标记，便于检索与
  回溯。当前清单：

| 文件 | ARM64-ADAPT 标记位置 | 内容 |
|---|---|---|
| `kernel-src/mm/ldm_iommu.c` | include 区 + `iommu_present()` 调用处 | aarch64 下 `iommu_present(NULL)` 会解引用空指针 Oops；改为 `iommu_present(&platform_bus_type)`，非 arm64 语义不变 |
| `kernel-src/mm/ldm_compat.c` | `ldm_memcpy` / `ldm_copy_to_user` / `ldm_copy_from_user` 调用处（共 3 处） | 通用树调用的 `ldm_transfer()` 在 `src/` 中无任何定义（链接失败），arm64 构建树统一改用真实引擎入口 `ldm_zerocopy_transfer()`，并补 `LDM_XFER_SW_FALLBACK` |
| `kernel-src/mm/ldm_core.c` | `ldm_lazy_copy()` 局部变量区 | 声明 COW 区间对应的 VMA 对（`src_vma`/`dst_vma`），供 aarch64 缺页路径使用 |

打补丁逻辑位于 `scripts/adapt_arm64_build.sh` 的 `apply_source_fixes()`，
幂等判定以 `ARM64-ADAPT` 标记为准；在干净 clone 上重跑会重新写入标记，
已打补丁的树直接跳过。

检索所有 arm64 专属修改：

```bash
grep -rn "ARM64-ADAPT" kernel-src/mm/
```

## 关键适配点（踩坑记录）

1. **仓库 rootfs 的 busybox 是 x86-64 静态二进制**，不能在 arm64 guest 运行。
   必须换成宿主机的 aarch64 busybox（默认 `/usr/sbin/busybox`）并用
   `busybox --install -s` 生成 applet 软链。
2. **动态 glibc 依赖闭包**：busybox/dd 均动态链接。用 `readelf -d` 求 NEEDED
   闭包，并把每个库同时拷贝到 `/lib`、`/lib64`、`/usr/lib`、`/usr/lib64`
   四条路径，避免加载器按工具链默认布局找不到库。
3. **`/lib/ld-linux-aarch64.so.1` 必须存在**：它是二进制硬编码的 interpreter
   路径，缺失会导致 `Exec format error`。
4. **`dd` 必须作为真实 ELF 放到 `/bin/dd`**：`test_os_safe.sh` 直接调用
   `dd if=/dev/zero ...`，busybox 的 dd applet 在脚本环境下不可靠。
5. **无 `/dev/kvm`**：容器化 Kunpeng 环境用 TCG 模拟（`-M virt -accel tcg`）；
   若宿主机有 `/dev/kvm`，可设 `QEMU_ACCEL=kvm`。
6. **必须显式 `-cpu cortex-a57`**：华为云 EulerOS 自带 qemu-kvm 的默认 CPU 以及
   `Kunpeng-920` 机型都无法引导本内核（串口无输出）；实测 `cortex-a57` 可完整
   启动并完成全部验证。可通过 `QEMU_CPU` 覆盖。
7. **busybox applet 链接必须是相对的**：`busybox --install -s` 会写绝对路径链接
   （指向 staging 宿主机路径），在 ramfs 内悬空导致 `/init` 的 `#!/bin/sh`
   ENOENT；脚本安装后统一重写为相对链接 `-> busybox`。
8. **动态依赖取传递闭包**：仅 `readelf -d` 一层 NEEDED 不够（如
   libselinux.so.1 → libpcre2-8.so.0）；脚本递归解析全部 NEEDED。
9. **内核构建用 O= 独立目录**（默认 `/root/ldm-build-arm64`），不污染源码树；
   `.config` 复用已调通的配置（initramfs/devtmpfs/debugfs）。
10. **initramfs 为 newc/SVR4 明文 cpio**：`find . | cpio -o -H newc`，内核直接解包。

## 环境变量覆盖

| 变量 | 默认值 | 说明 |
|---|---|---|
| `REPO_ROOT` | 脚本上级目录 | 仓库根 |
| `KERNEL_SRC` | `$REPO_ROOT/kernel-src` | LDM 内核源码 |
| `KERNEL_OUT` | `/root/ldm-build-arm64` | 内核构建输出目录 |
| `STAGING` | `/root/ldm-initramfs` | initramfs 暂存目录 |
| `INITRAMFS_OUT` | `/root/ldm-initramfs.cpio` | 最终 cpio |
| `BENCH_RESULTS` | `/root/bench-results` | benchmark 数据目录 |
| `BUSYBOX_BIN` | `/usr/sbin/busybox` | aarch64 busybox |
| `DD_BIN` | `/usr/bin/dd` | aarch64 dd |
| `QEMU_BIN` | 自动探测 | `qemu-system-aarch64` 或 HCE 的 `/usr/libexec/qemu-kvm` |
| `QEMU_CPU` | `cortex-a57` | 显式 CPU；默认/Kunpeng-920 在本 qemu 构建上无法引导 |
| `QEMU_MEM`/`QEMU_SMP`/`QEMU_TIMEOUT` | 512 / 2 / 300 | guest 内存、CPU、超时秒 |
| `ROUNDS` | 50 | 每个模式轮数 |

## 验证结果

- guest 内核：`Linux 6.6.142 arm64`（QEMU virt / TCG）
- `test_os_safe.sh`：PASS 53 / FAIL 0，输出
  `ALL TESTS PASSED - LDM-OS FULLY COMPATIBLE`
- LDM 模块：init 成功、debugfs `ldm_os` 接口挂载正常、guest 正常关机