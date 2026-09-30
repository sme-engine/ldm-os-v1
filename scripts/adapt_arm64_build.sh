#!/usr/bin/env bash
# =============================================================================
# ldm-os 对 arm64 / aarch64 / Kunpeng920 的适配、构建与验证脚本
#
# 适用场景：在 aarch64 宿主（含华为鲲鹏 920 服务器）上 native 构建带
#           LDM-OS 的 arm64 Linux 内核 + busybox initramfs，并用
#           QEMU TCG 全系统模拟引导验证，全程无需交叉工具链。
#
# 为什么需要本脚本：
#   ldm-os-v1 原始交付形态为 x86_64 UML 内核（arch/um），在 aarch64 宿主
#   native 编译会因 gcc 不支持 -m64 失败；下载 x86_64 交叉工具链在本环境
#   受带宽瓶颈。LDM 核心代码全部位于 mm/ 且无架构耦合，因此改为 native
#   arm64 内核 + QEMU TCG 验证，功能语义完全保留。
#
# 用法：
#   ./scripts/adapt_arm64_build.sh                 # 完整流程：修复+构建+initramfs+验证
#   SKIP_BUILD=1 ./scripts/adapt_arm64_build.sh    # 跳过内核编译（复用输出目录）
#   SKIP_QEMU=1  ./scripts/adapt_arm64_build.sh    # 构建但不跑 QEMU 验证
#
# 环境变量（均可覆盖默认值）：
#   OUT_DIR        内核输出目录            默认 /root/ldm-build-arm64
#   INITRAMFS_DIR  initramfs 临时目录      默认 /root/ldm-initramfs
#   CPIO           initramfs 产物(.gz)     默认 /root/ldm-initramfs.cpio.gz
#   LOG_DIR        验证日志目录            默认 /root
#   JOBS           并行编译数              默认 nproc
#
# 退出码：0=成功；1=环境/构建失败；2=QEMU 验证断言失败
# 详细说明见 DEPLOY_AARCH64_REPORT.md
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# 路径与参数
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL_SRC="$REPO_ROOT/kernel-src"

OUT_DIR="${OUT_DIR:-/root/ldm-build-arm64}"
INITRAMFS_DIR="${INITRAMFS_DIR:-/root/ldm-initramfs}"
CPIO="${CPIO:-/root/ldm-initramfs.cpio.gz}"
LOG_DIR="${LOG_DIR:-/root}"
JOBS="${JOBS:-$(nproc)}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_QEMU="${SKIP_QEMU:-0}"

LOG_FILE="$LOG_DIR/ldm-qemu-final.log"

log()  { printf '\033[1;34m[ldm-arm64]\033[0m %s\n' "$*"; }
info() { printf '\033[1;32m[ldm-arm64]\033[0m %s\n' "$*"; }
die()  { local code=1; [ "${2:-}" ] && code="$2"; printf '\033[1;31m[ldm-arm64]\033[0m ERROR: %s\n' "$1" >&2; exit "$code"; }

# ----------------------------------------------------------------------------
# 1. 平台检测（aarch64 / 鲲鹏920）
# ----------------------------------------------------------------------------
detect_platform() {
  local arch impl part
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64)
      impl="$(awk -F': *' '/^CPU implementer/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
      part="$(awk -F': *' '/^CPU part/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
      case "$impl" in
        0x48)
          # ARM implementer 0x48 = HiSilicon；鲲鹏 920 (TSV110) 常见 part 0xd0b，
          # 虚拟化/早期步进可能显示 0xd02/0xd0c 等，均属 Kunpeng 家族
          case "$part" in
            0xd0b|0xd02|0xd0c|0xd0e)
              PLATFORM_NAME="HiSilicon Kunpeng 920 (aarch64, implementer=$impl part=$part)" ;;
            *)
              PLATFORM_NAME="HiSilicon Kunpeng 系列 (aarch64, implementer=$impl part=$part)" ;;
          esac
          ;;
        *)
          PLATFORM_NAME="aarch64 (vendor implementer=$impl, cpu part=$part)" ;;
      esac
      ;;
    *)
      die "宿主架构为 $arch，非 aarch64/arm64。本脚本用于 aarch64 native 构建；"
          "在 x86_64 环境请改用原始 UML 构建脚本（scripts/build_uml_kernel.sh）。"
      ;;
  esac
  log "检测到平台: $PLATFORM_NAME"
}

check_tools() {
  local missing=()
  for t in gcc make cpio gzip busybox ldd; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if command -v qemu-kvm >/dev/null 2>&1; then
    QEMU_BIN="$(command -v qemu-kvm)"
  elif command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU_BIN="$(command -v qemu-system-aarch64)"
  else
    missing+=("qemu-kvm|qemu-system-aarch64")
  fi
  [ "${#missing[@]}" -eq 0 ] || die "缺少必要工具: ${missing[*]} (请先 yum install 相应软件包)"
  log "工具就绪: gcc=$(gcc -dumpversion), $QEMU_BIN"
}

# ----------------------------------------------------------------------------
# 2. 幂等修复源码（在干净 clone 上也能复现）
# ----------------------------------------------------------------------------
apply_source_fixes() {
  # 2.1 补缺失文件：仓库 checkout 缺 Documentation/Kconfig，内核配置阶段会报错
  if [ ! -f "$KERNEL_SRC/Documentation/Kconfig" ]; then
    touch "$KERNEL_SRC/Documentation/Kconfig"
    log "已补建缺失文件: kernel-src/Documentation/Kconfig"
  fi

  # 2.2 修复 ldm_iommu.c：x86/UML 下 iommu_present(NULL) 可容忍；
  #     但 aarch64 下该内联实现会解引用空指针导致 Oops/panic。
  #     改为传入合法总线类型 &platform_bus_type，无硬件 IOMMU 时自动降级
  #     为软件模拟隔离，行为语义不变。
  #     该修改在源码内以 “ARM64-ADAPT” 标记（见 kernel-src/mm/ldm_iommu.c），
  #     与通用源码（src/mm/ldm_iommu.c 保持 iommu_present(NULL)）区分。
  local iommu_c="$KERNEL_SRC/mm/ldm_iommu.c"
  if grep -q 'ARM64-ADAPT' "$iommu_c"; then
    log "ldm_iommu.c 已包含 aarch64 修复（ARM64-ADAPT 标记），跳过"
  elif grep -q 'iommu_present(NULL)' "$iommu_c"; then
    sed -i \
      -e '/#include <linux\/ldm_os.h>/a #include <linux\/platform_device.h> /* ARM64-ADAPT: see iommu_present() note below */' \
      -e 's/ \* Use iommu_present() with NULL bus to check globally./ * ARM64-ADAPT: on aarch64\/Kunpeng iommu_present() dereferences the\n\t * bus pointer; passing NULL causes a NULL dereference Oops. Pass a\n\t * valid bus type instead; the generic fallback below keeps\n\t * software-simulated isolation active, semantics unchanged elsewhere./' \
      -e 's/iommu_present(NULL)/iommu_present(\&platform_bus_type)/' \
      "$iommu_c"
    log "已修复并标记 ARM64-ADAPT: iommu_present(NULL) -> iommu_present(&platform_bus_type) ($iommu_c)"
  else
    warn "未在 $iommu_c 中找到 iommu_present() 调用，请人工检查"
  fi

  # 2.3 修复 ldm_compat.c：通用树的 ldm_transfer() 在 src/mm/ 与
  #     src/include/ 中均无定义，链接必失败；arm64 构建树统一改用引擎
  #     真实入口 ldm_zerocopy_transfer()，并补 LDM_XFER_SW_FALLBACK。
  #     幂等判定同样以 "ARM64-ADAPT" 标记为准。
  local compat_c="$KERNEL_SRC/mm/ldm_compat.c"
  if grep -q 'ARM64-ADAPT' "$compat_c"; then
    log "ldm_compat.c 已包含 aarch64 修复（ARM64-ADAPT 标记），跳过"
  elif grep -q 'ldm_transfer(' "$compat_c"; then
    perl -0pi -e '
      s/\bldm_transfer\(/ldm_zerocopy_transfer(/g;
      s{(\t \* to optimized software copy\.\n\t \*/)}{$1\n\t/* ARM64-ADAPT: ldm_transfer() -> ldm_zerocopy_transfer() and\n\t * LDM_XFER_SW_FALLBACK. The generic tree calls ldm_transfer(), which\n\t * is not defined anywhere in src/, so the arm64 build resolves to the\n\t * real engine entrypoint declared in ldm_os.h. Same for copy_to/from_user. */}
    ' "$compat_c"
    log "已修复并标记 ARM64-ADAPT: ldm_transfer -> ldm_zerocopy_transfer ($compat_c)"
  else
    warn "未在 $compat_c 中找到 ldm_transfer() 调用，请人工检查"
  fi

  # 2.4 修复 ldm_core.c：ldm_lazy_copy() 声明 COW 区间对应的 VMA 对，
  #     供 aarch64 缺页路径使用；以 "ARM64-ADAPT" 标记幂等。
  local core_c="$KERNEL_SRC/mm/ldm_core.c"
  if grep -q 'ARM64-ADAPT' "$core_c"; then
    log "ldm_core.c 已包含 aarch64 修复（ARM64-ADAPT 标记），跳过"
  elif grep -q 'unsigned long nr_pages, i;' "$core_c"; then
    perl -0pi -e '
      s{\tunsigned long nr_pages, i;\n\t\n}{\tunsigned long nr_pages, i;\n\t/* ARM64-ADAPT: declare the COW VMA pair used by the aarch64 fault path */\n\tstruct vm_area_struct *src_vma, *dst_vma;\n\t\n}
    ' "$core_c"
    log "已修复并标记 ARM64-ADAPT: ldm_lazy_copy VMA 声明 ($core_c)"
  else
    warn "未在 $core_c 中找到 nr_pages 声明，请人工检查"
  fi
}

# ----------------------------------------------------------------------------
# 3. native 构建 arm64 内核（含 LDM_OS）
# ----------------------------------------------------------------------------
build_kernel() {
  [ "$SKIP_BUILD" = "1" ] && { log "SKIP_BUILD=1，跳过内核编译"; return; }
  [ -d "$KERNEL_SRC" ] || die "内核源码目录不存在: $KERNEL_SRC"
  log "构建内核: O=$OUT_DIR ARCH=arm64 JOBS=$JOBS"
  cd "$KERNEL_SRC"
  make O="$OUT_DIR" ARCH=arm64 defconfig >/dev/null
  # LDM_OS 默认 y；DEBUG_FS 供 LDM_OS_DEBUG/debugfs 统计接口使用
  scripts/config --file "$OUT_DIR/.config" \
    -e DEBUG_FS -e LDM_OS_DEBUG -e IKCONFIG -e IKCONFIG_PROC
  make O="$OUT_DIR" ARCH=arm64 olddefconfig >/dev/null
  make O="$OUT_DIR" ARCH=arm64 -j"$JOBS" Image
  [ -f "$OUT_DIR/arch/arm64/boot/Image" ] || die "内核镜像未生成: $OUT_DIR/arch/arm64/boot/Image"
  info "内核镜像: $OUT_DIR/arch/arm64/boot/Image ($(du -h "$OUT_DIR/arch/arm64/boot/Image" | cut -f1))"

  # 确认 LDM 符号确实编入内核
  if ! grep -qE " T ldm_init$| ldm_init$" "$OUT_DIR/System.map" 2>/dev/null; then
    die "System.map 中未找到 ldm_init 符号，CONFIG_LDM_OS 可能未生效"
  fi
  info "LDM 符号已编入内核: $(grep -E ' ldm_init$| ldm_get_stats$| ldm_hooks_init$' "$OUT_DIR/System.map" | wc -l) 个关键符号"
}

# ----------------------------------------------------------------------------
# 4. 构建 busybox initramfs（动态库多路径布局）
# ----------------------------------------------------------------------------
build_initramfs() {
  local bb deps f name
  log "构建 initramfs: $INITRAMFS_DIR -> $CPIO"
  rm -rf "$INITRAMFS_DIR"
  mkdir -p "$INITRAMFS_DIR"/{bin,dev,etc,proc,sys,tmp,mnt,root,lib}

  bb="$(command -v busybox || echo /usr/sbin/busybox)"
  [ -x "$bb" ] || die "未找到 busybox 可执行文件"
  cp -fL "$bb" "$INITRAMFS_DIR/bin/busybox"
  chmod 755 "$INITRAMFS_DIR/bin/busybox"

  # 安装 busybox applet 硬链接（sh/cp/ls/tar/gzip/sed/awk/cut/wc 等 370+ 命令）。
  # 必须用硬链接而非软链：busybox --install -s 生成的链接指向宿主绝对路径，
  # 在 guest initramfs 内是断链；硬链接会被 cpio 记录为 nlink>1，rootfs 解包正确。
  ( cd "$INITRAMFS_DIR/bin" && "$bb" --install . ) >/dev/null 2>&1 || true
  log "busybox applets installed: $(ls "$INITRAMFS_DIR/bin" | wc -l)"

  # 基础 /etc 文件：OS 级测试(test_os_safe.sh)的 wc/cut 等项依赖 /etc/passwd
  printf 'root:x:0:0:root:/root:/bin/sh\n' > "$INITRAMFS_DIR/etc/passwd"
  printf 'guest-ldm\n' > "$INITRAMFS_DIR/etc/hostname"
  printf '127.0.0.1 localhost\n' > "$INITRAMFS_DIR/etc/hosts"
  chmod 644 "$INITRAMFS_DIR/etc/passwd" "$INITRAMFS_DIR/etc/hostname" "$INITRAMFS_DIR/etc/hosts"

  # 依赖收集：ldd 输出可能形如
  #   libm.so.6 => /usr/lib64/libm.so.6 (0x...)
  #   /lib/ld-linux-aarch64.so.1 (0x...)
  deps="$(ldd "$bb" | awk '/=>/ {print $3} /^[[:space:]]*\// {print $1}' | sort -u)"
  [ -n "$deps" ] || die "busybox 无动态依赖（静态链接？仍可继续，但建议确认）"

  # 多路径布局：arm64 动态加载器默认搜索路径随 glibc 构建而异，
  # 覆盖 lib/ lib64/ usr/lib64/ lib/aarch64-linux-gnu/ usr/lib/aarch64-linux-gnu/
  local libdirs=("lib" "lib64" "usr/lib64" "lib/aarch64-linux-gnu" "usr/lib/aarch64-linux-gnu")
  for d in "${libdirs[@]}"; do
    mkdir -p "$INITRAMFS_DIR/$d"
  done
  for f in $deps; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    for d in "${libdirs[@]}"; do
      cp -fL "$f" "$INITRAMFS_DIR/$d/$name" 2>/dev/null || true
    done
  done
  log "已复制动态库: $(for d in "${libdirs[@]}"; do ls "$INITRAMFS_DIR/$d" 2>/dev/null; done | sort -u | tr '\n' ' ')"

  # 生成 init（全部以 /bin/busybox 前缀调用，避免 applet 缺失/ PATH 问题）
  cat > "$INITRAMFS_DIR/init" <<'EOF'
#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox echo "[ldm-os] initramfs init start"
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || /bin/busybox echo "[ldm-os] devtmpfs mount skipped"
/bin/busybox mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || /bin/busybox echo "[ldm-os] debugfs mount failed"
/bin/busybox echo
/bin/busybox echo "================ LDM-OS VERIFICATION ================"
/bin/busybox echo "--- uname ---"
/bin/busybox cat /proc/sys/kernel/ostype
/bin/busybox uname -a
/bin/busybox echo
/bin/busybox echo "--- LDM messages in kernel log ---"
/bin/busybox dmesg | /bin/busybox grep -i -E "LDM|ldm" | /bin/busybox head -20
/bin/busybox echo
/bin/busybox echo "--- LDM symbols in kallsyms ---"
/bin/busybox cat /proc/kallsyms | /bin/busybox grep -i -E "ldm_init$|ldm_hooks_init|ldm_get_stats|ldm_hooks_stats" | /bin/busybox head -10
/bin/busybox echo
/bin/busybox echo "--- LDM-OS debugfs statistics ---"
/bin/busybox cat /sys/kernel/debug/ldm_os/stats 2>/dev/null || /bin/busybox ls -R /sys/kernel/debug/ldm_os 2>/dev/null | /bin/busybox head
/bin/busybox echo "===================================================="
/bin/busybox sleep 1
/bin/busybox echo "[ldm-os] poweroff"
/bin/busybox poweroff -f
EOF
  chmod 755 "$INITRAMFS_DIR/init"

  ( cd "$INITRAMFS_DIR" && find . | cpio -H newc -o --quiet 2>/dev/null | gzip -9 > "$CPIO" )
  info "initramfs: $CPIO ($(du -h "$CPIO" | cut -f1))"
}

# ----------------------------------------------------------------------------
# 5. QEMU TCG 引导验证与断言
# ----------------------------------------------------------------------------
run_qemu_verify() {
  [ "$SKIP_QEMU" = "1" ] && { log "SKIP_QEMU=1，跳过 QEMU 验证"; return; }
  [ -f "$OUT_DIR/arch/arm64/boot/Image" ] || die "缺少内核镜像，请先构建"
  [ -f "$CPIO" ] || die "缺少 initramfs，请先构建"
  mkdir -p "$LOG_DIR"
  log "QEMU TCG 引导验证（约 10-20 秒）..."
  # shellcheck disable=SC2086
  timeout 480 "$QEMU_BIN" -M virt -cpu cortex-a57 -smp 2 -m 512 -accel tcg \
    -kernel "$OUT_DIR/arch/arm64/boot/Image" \
    -initrd "$CPIO" \
    -nographic -no-reboot \
    -append "console=ttyAMA0 panic=1" > "$LOG_FILE" 2>&1 || true

  local ok=1
  grep -q "LDM-OS: initialized successfully" "$LOG_FILE" || { echo "  FAIL: LDM-OS 未初始化成功"; ok=0; }
  grep -q "LDM-OS Statistics" "$LOG_FILE" || { echo "  FAIL: 未读取到 debugfs 统计"; ok=0; }
  grep -q "reboot: Power down" "$LOG_FILE" || { echo "  FAIL: 未正常关机"; ok=0; }
  if grep -qE "Kernel panic|Oops" "$LOG_FILE"; then echo "  FAIL: 存在 panic/Oops"; ok=0; fi

  if [ "$ok" = "1" ]; then
    info "QEMU 验证通过: LDM-OS 初始化 / debugfs 统计 / 干净关机 全部 OK"
    info "验证日志: $LOG_FILE"
  else
    echo "  --- 日志尾部 ---"; tail -20 "$LOG_FILE"
    die "QEMU 验证断言失败" 2
  fi
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
main() {
  log "========== ldm-os arm64/aarch64/Kunpeng920 适配构建开始 =========="
  log "仓库: $REPO_ROOT  日志: $LOG_FILE"
  detect_platform
  check_tools
  apply_source_fixes
  build_kernel
  build_initramfs
  run_qemu_verify
  info "========== 全部完成（Platform: $PLATFORM_NAME） =========="
  info "内核:   $OUT_DIR/arch/arm64/boot/Image"
  info "initrd: $CPIO"
  info "日志:   $LOG_FILE"
}

main "$@"