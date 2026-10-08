#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 多板 Debian 13 内核构建脚本（MediaTek Filogic）
#
# 基于 ImmortalWrt master（target/linux/mediatek）已验证的 6.18 内核补丁与配置，
# 生成适用于 Debian 13 ARM64 的 Linux 6.18.x 内核：
#   Image / <board>.dtb / modules.tar.zst
#
# 支持板卡见 boards/*.board（当前：h5000m=MT7987A、ap3000m=MT7981B）。
# 板级差异（DTS / DTB / 内核配置片段 / 串口基址 / 关键符号）全部由 boards/<board>.board
# 驱动，本脚本不含任何机型字面量。
#
# 用法：
#   bash build-kernel.sh --board h5000m|ap3000m [--kernel-version 6.18.54]
#                        [--config 文件] [--out 目录] [--jobs N]
#                        [--skip-failed-patches] [--strict]
#                        [--native | --cross] [--no-ccache]
#
# 编译模式（自动判定，可显式覆盖）：
#   native：宿主本身就是 arm64/aarch64（如 ubuntu-24.04-arm runner）→ 直接本地编译，
#           无需交叉工具链，也不需要 qemu 参与（配合 ARM64 runner 可大幅缩短 CI 时长）。
#   cross ：宿主为 x86_64 等 → 使用 aarch64-linux-gnu- 交叉工具链。
# ccache：检测到 ccache 且未传 --no-ccache 时自动启用（CI 配 Cache action 后可跨运行复用）。
#
# 平台：Linux（Windows 请使用 WSL / Git-Bash；脚本内含平台检测与提示）

set -Eeuo pipefail

# ---------------------------------------------------------------- 平台检测
case "$(uname -s)" in
  Linux)   BUILD_PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) BUILD_PLATFORM="windows" ;;
  Darwin)  BUILD_PLATFORM="macos" ;;
  *)       BUILD_PLATFORM="unknown" ;;
esac

if [[ "$BUILD_PLATFORM" != "linux" ]]; then
  echo "[build-kernel] 提示：内核交叉编译需要 Linux 环境。"
  echo "[build-kernel]        Windows 请使用 WSL2，macOS 建议使用 Docker/Linux VM。"
  echo "[build-kernel]        当前平台：$BUILD_PLATFORM（继续尝试，但不保证成功）"
fi

# ---------------------------------------------------------------- 路径（不硬编码）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DTS_DIR="$PROJECT_ROOT/dts"
PATCH_DIR="$PROJECT_ROOT/kernel/patches"

# ---------------------------------------------------------------- 板级加载
# shellcheck source=../boards/board-lib.sh
source "$PROJECT_ROOT/boards/board-lib.sh"

KERNEL_VERSION="6.18.54"
BOARD=""                                   # 必填（--board 或 --config 推导）
CONFIG_FILE=""                             # 缺省 = build/kernel-conf/$BOARD_KERNEL_CONFIG
OUT_DIR="$PROJECT_ROOT/out/kernel"
JOBS="$(nproc 2>/dev/null || echo 2)"
SKIP_FAILED=0
STRICT=0
FORCE_MODE=""      # 空=自动；native=强制本地编译；cross=强制交叉编译
USE_CCACHE=1       # 检测到 ccache 时自动启用（--no-ccache 关闭）

# 补丁层级（OpenWrt/ImmortalWrt 标准顺序）：
#   generic/backport -> generic/pending -> generic/hack -> mediatek
GENERIC_PATCH_DIR="$PROJECT_ROOT/kernel/patches/generic"
PATCH_DIR="$PROJECT_ROOT/kernel/patches"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board)          BOARD="$2"; shift 2 ;;
    --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
    --config)         CONFIG_FILE="$2"; shift 2 ;;
    --out)            OUT_DIR="$2"; shift 2 ;;
    --jobs)           JOBS="$2"; shift 2 ;;
    --skip-failed-patches) SKIP_FAILED=1; shift ;;
    --strict)             STRICT=1; shift ;;
    --native)             FORCE_MODE="native"; shift ;;
    --cross)              FORCE_MODE="cross"; shift ;;
    --no-ccache)          USE_CCACHE=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

# --config 兼容旧用法：未给 --board 时从配置文件名反推板级
# （h5000m-6.18.config → h5000m）。两者都不给则直接报错并列出可选板卡。
if [[ -z "$BOARD" && -n "$CONFIG_FILE" ]]; then
  cfg_base="$(basename "$CONFIG_FILE")"
  cand="${cfg_base%%-*}"
  board_exists "$cand" && BOARD="$cand"
fi
if [[ -z "$BOARD" ]]; then
  echo "[build-kernel] ERROR: 必须用 --board 指定板级。可用：$(board_list | tr '\n' ' ')" >&2
  exit 1
fi
board_load "$BOARD" || exit 1

# 板级源码存在性预检：早失败优于下载内核后再报缺 DTS
[[ -f "$DTS_DIR/$BOARD_DTS" ]] || { echo "[build-kernel] ERROR: 缺少板级 DTS：$DTS_DIR/$BOARD_DTS" >&2; exit 1; }
[[ -f "$DTS_DIR/$BOARD_SOC_DTSI" ]] || { echo "[build-kernel] ERROR: 缺少 SoC dtsi：$DTS_DIR/$BOARD_SOC_DTSI" >&2; exit 1; }

: "${CONFIG_FILE:=$PROJECT_ROOT/build/kernel-conf/$BOARD_KERNEL_CONFIG}"
[[ -f "$CONFIG_FILE" ]] || { echo "[build-kernel] ERROR: 缺少内核配置片段：$CONFIG_FILE" >&2; exit 1; }

# 规范化 OUT_DIR 为绝对路径：
# 下文 modules_install 使用 make -C "$KERNEL_SRC"，make 的工作目录会切换到内核
# 源码树；若 OUT_DIR 为相对路径，INSTALL_MOD_PATH 会被解析进源码树内部
# （$KERNEL_SRC/out/...），导致 $MODULES_ROOT/lib 不存在，
# 收集产物阶段 tar 报错 "tar: lib: Cannot stat: No such file or directory"。
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

KERNEL_MAJOR_MINOR="${KERNEL_VERSION%.*}"          # 6.18
KERNEL_TAR="linux-$KERNEL_VERSION.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/$KERNEL_TAR"
KERNEL_SRC="$OUT_DIR/src/linux-$KERNEL_VERSION"
WORK="$OUT_DIR/work"
MODULES_ROOT="$WORK/modules-root"

mkdir -p "$OUT_DIR" "$WORK" "$MODULES_ROOT"

log() { printf '[build-kernel] %s\n' "$*"; }
die() { printf '[build-kernel] ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 && DOWNLOADER="curl" || true
command -v wget >/dev/null 2>&1 && DOWNLOADER="${DOWNLOADER:-wget}" || true
: "${DOWNLOADER:?需要 curl 或 wget 下载内核源码}"
command -v xz >/dev/null 2>&1 || die "缺少 xz 工具"
command -v bc >/dev/null 2>&1 || die "缺少 bc（内核编译依赖）"

# ---------------------------------------------------------------- 编译模式判定（native / cross）
# native（宿主即 arm64）在 CI 上收益显著：免去交叉工具链的全部调用开销，
# 也便于与 ARM64 runner 上的 RootFS 构建共享同一台机器。
HOST_ARCH="$(uname -m)"
if [[ -n "$FORCE_MODE" ]]; then
  BUILD_MODE="$FORCE_MODE"
elif [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
  BUILD_MODE="native"
else
  BUILD_MODE="cross"
fi

if [[ "$BUILD_MODE" == "native" ]]; then
  CROSS_COMPILE=""
  command -v gcc >/dev/null 2>&1 || die "native 模式缺少 gcc。请安装 build-essential。"
else
  command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || \
    die "未找到 aarch64-linux-gnu-gcc。请安装交叉编译工具链，例如：sudo apt-get install crossbuild-essential-arm64"
  CROSS_COMPILE="aarch64-linux-gnu-"
fi
command -v make >/dev/null 2>&1 || die "缺少 make"

# ccache：命中时把内核编译从数十分钟降到分钟级（CI 通过 Cache action 跨运行复用 CCACHE_DIR）。
# key 由 CI 侧按 内核版本 + 补丁集 + 配置文件 + 本脚本 hash 组成，避免脏命中。
CCACHE_BIN=""
if [[ "$USE_CCACHE" -eq 1 ]] && command -v ccache >/dev/null 2>&1; then
  CCACHE_BIN="ccache"
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
  mkdir -p "$CCACHE_DIR"
fi

# 统一传给 make 的变量：ARCH / CROSS_COMPILE / CC / HOSTCC
MAKE_VARS=(ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE")
if [[ -n "$CCACHE_BIN" ]]; then
  MAKE_VARS+=(CC="$CCACHE_BIN ${CROSS_COMPILE}gcc" HOSTCC="$CCACHE_BIN gcc")
fi

log "编译模式：$BUILD_MODE（宿主 Arch=$HOST_ARCH，并行 -j$JOBS，ccache=${CCACHE_BIN:-关闭}）"
if [[ -n "$CCACHE_BIN" ]]; then
  log "ccache 缓存目录：$CCACHE_DIR"
fi

# ---------------------------------------------------------------- 1. 下载与解压
if [[ -d "$KERNEL_SRC" ]]; then
  log "已存在内核源码目录 $KERNEL_SRC，跳过下载"
else
  log "下载内核 $KERNEL_VERSION：$KERNEL_URL"
  if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fL --retry 3 -o "$OUT_DIR/$KERNEL_TAR" "$KERNEL_URL"
  else
    wget -O "$OUT_DIR/$KERNEL_TAR" "$KERNEL_URL"
  fi
  log "解压内核源码"
  mkdir -p "$(dirname "$KERNEL_SRC")"
  tar -xJf "$OUT_DIR/$KERNEL_TAR" -C "$(dirname "$KERNEL_SRC")"
fi

# ---------------------------------------------------------------- 2. 应用补丁
# 补丁集规模在数百个量级，因此这里刻意做了两件事：
#   1. 不再对每个补丁先跑一次 `git apply --check`。git apply 本身就是原子的
#      （任一文件应用失败则整体不落盘），预检只是把同样的解析做两遍，
#      去掉后这套补丁集能省掉数百次子进程调用。
#   2. 应用结果汇总成一份报告落盘。数百行 [OK] 日志里找那一个 [FAIL] 很痛苦，
#      报告里失败清单单独列出，也便于 CI 归档后直接查看。
log "应用 ImmortalWrt 补丁（backport -> pending -> hack -> mediatek）"
PATCH_FAILED=0
PATCH_APPLIED=0
PATCH_FALLBACK=0
PATCH_FAILED_NAMES=()
FAILED_PATCH_REPORT="$OUT_DIR/patch-report.txt"
apply_patch_series() {
  local series="$1"
  local dir patch name
  local series_applied=0
  local series_failed=0
  for dir in $2; do
    if [[ ! -d "$dir" ]]; then
      log "  [SKIP] $series（目录缺失：$dir）"
      continue
    fi
    for patch in "$dir"/*.patch; do
      if [[ ! -f "$patch" ]]; then
        log "  [SKIP] $series（无补丁文件：$dir）"
        continue
      fi
      name="$(basename "$patch")"
      if git -C "$KERNEL_SRC" apply "$patch" 2>/dev/null; then
        PATCH_APPLIED=$((PATCH_APPLIED + 1))
        series_applied=$((series_applied + 1))
      elif command -v patch >/dev/null 2>&1 \
        && patch -d "$KERNEL_SRC" -p1 --forward --dry-run < "$patch" >/dev/null 2>&1; then
        if patch -d "$KERNEL_SRC" -p1 --forward < "$patch" >/dev/null 2>&1; then
          PATCH_FALLBACK=$((PATCH_FALLBACK + 1))
          series_applied=$((series_applied + 1))
          log "  [OK] $series/$name（patch 回退应用）"
        else
          log "  [FAIL] $series/$name（git apply 与 patch 回退均失败）"
          PATCH_FAILED_NAMES+=("$series/$name")
          PATCH_FAILED=1
          series_failed=$((series_failed + 1))
        fi
      else
        log "  [FAIL] $series/$name（与内核 $KERNEL_VERSION 上下文不匹配，且 patch 回退无法应用）"
        PATCH_FAILED_NAMES+=("$series/$name")
        PATCH_FAILED=1
        series_failed=$((series_failed + 1))
      fi
    done
  done
  log "  -- $series：成功 $series_applied，失败 $series_failed"
}
apply_patch_series backport "$GENERIC_PATCH_DIR/backport"
apply_patch_series pending  "$GENERIC_PATCH_DIR/pending"
apply_patch_series hack     "$GENERIC_PATCH_DIR/hack"
apply_patch_series mediatek "$PATCH_DIR"
{
  echo "内核补丁应用报告"
  echo "内核版本：$KERNEL_VERSION"
  echo "生成时间：$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "git apply 成功：$PATCH_APPLIED"
  echo "patch 回退成功：$PATCH_FALLBACK"
  echo "失败：${#PATCH_FAILED_NAMES[@]}"
  if [[ ${#PATCH_FAILED_NAMES[@]} -gt 0 ]]; then
    echo "失败清单："
    printf '  - %s\n' "${PATCH_FAILED_NAMES[@]}"
  fi
} > "$FAILED_PATCH_REPORT"
log "补丁应用报告：$FAILED_PATCH_REPORT（git apply $PATCH_APPLIED / 回退 $PATCH_FALLBACK / 失败 ${#PATCH_FAILED_NAMES[@]}）"
if [[ "$PATCH_FAILED" -eq 1 ]]; then
  if [[ "$SKIP_FAILED" -eq 1 ]]; then
    log "存在失败补丁，已按 --skip-failed-patches 继续（硬件功能可能不完整）："
    printf '    %s\n' "${PATCH_FAILED_NAMES[@]}"
  else
    die "存在 ${#PATCH_FAILED_NAMES[@]} 个失败补丁：${PATCH_FAILED_NAMES[*]}。请调整 --kernel-version（6.18.x 系列）后重试，或加 --skip-failed-patches 强制继续。"
  fi
fi

# ---------------------------------------------------------------- 3. 复制 DTS 并注册 DTB
# dts/ 下同时存在多块板卡的 DTS/dtsi（mt7987a-hiveton-h5000m.dts + mt7987.dtsi、
# mt7981b-airpi-ap3000m.dts + mt7981b.dtsi）。**全部复制**：DTS 之间不互相 include，
# 复制多余的 dtsi/dts 不产生副作用，却省掉了"新增板卡忘记在此加白名单"的坑。
log "复制 DTS / dtsi 到内核源码（板级：$BOARD → $BOARD_DTS）"
DTS_TARGET="$KERNEL_SRC/arch/arm64/boot/dts/mediatek"
mkdir -p "$DTS_TARGET"
cp -v "$DTS_DIR"/*.dts "$DTS_DIR"/*.dtsi "$DTS_TARGET/" >/dev/null

# OpenWrt/ImmortalWrt 源码文件（mtdsplit / mtk_bmt 等；files-* 目录按内核版本提供）
log "复制 OpenWrt files（generic + mediatek）到内核源码"
cp -a "$PROJECT_ROOT/kernel/files-generic/." "$KERNEL_SRC/"
cp -a "$PROJECT_ROOT/kernel/files-mediatek/." "$KERNEL_SRC/"

# 板级内核源码文件层（kernel/files-boards/<board>/）——只对所属板卡生效。
# 用于放置"只有这块板子需要、且不适合作补丁"的驱动源码：
#   ap3000m → drivers/hwmon/airpi-gpio-fan/（GPIO 软 PWM 风扇，见该目录 Kbuild 注释）
BOARD_FILES_DIR="$PROJECT_ROOT/kernel/files-boards/$BOARD"
if [[ -d "$BOARD_FILES_DIR" ]]; then
  log "叠加板级内核源码层 kernel/files-boards/$BOARD/"
  cp -a "$BOARD_FILES_DIR/." "$KERNEL_SRC/"
else
  log "板级内核源码层 kernel/files-boards/$BOARD/ 不存在，跳过"
fi

# airpi-gpio-fan 是新增目录，drivers/hwmon/Makefile 不会自动递归进来，必须显式
# 追加 obj 行。放在这里而不是 patch：patch 会随内核版本漂移（Makefile 上下文行
# 变动即失配），而一行追加对上下文零依赖，幂等且可重复执行。
HWMON_MAKEFILE="$KERNEL_SRC/drivers/hwmon/Makefile"
if [[ "$BOARD" == "ap3000m" ]]; then
  if ! grep -q "airpi-gpio-fan" "$HWMON_MAKEFILE" 2>/dev/null; then
    printf '\n# AirPi AP3000M GPIO soft-PWM fan (Debian 13 port)\nobj-$(CONFIG_AIRPI_GPIO_FAN) += airpi-gpio-fan/\n' \
      >> "$HWMON_MAKEFILE"
    log "已在 drivers/hwmon/Makefile 注册 airpi-gpio-fan/"
  else
    log "drivers/hwmon/Makefile 已含 airpi-gpio-fan/，跳过"
  fi
  grep -n "airpi-gpio-fan" "$HWMON_MAKEFILE" | sed 's/^/[build-kernel]   /'

  # 【Kconfig 必须同时注册 —— 2026-10-09 CI 实测 root cause】
  # Makefile 的 obj-$(CONFIG_X) 只回答"怎么编"，**不定义符号**。若 Kconfig
  # 树里没有 config X，`make olddefconfig` 会把 .config 里的 CONFIG_X=m
  # 当作未知符号**静默丢弃**（Kconfig 对未知符号不报错），随后 --strict
  # 配置核验报 "CONFIG_AIRPI_GPIO_FAN 未启用" 并终止构建（实测 46s 失败）。
  # 因此在 drivers/hwmon/Kconfig 的 `endif # HWMON` 之前插入 source。
  HWMON_KCONFIG="$KERNEL_SRC/drivers/hwmon/Kconfig"
  if [[ ! -f "$HWMON_KCONFIG" ]]; then
    die "drivers/hwmon/Kconfig 不存在（内核源码布局异常）"
  fi
  if ! grep -q 'airpi-gpio-fan/Kconfig' "$HWMON_KCONFIG"; then
    # 在结束标记 `endif # HWMON` 之前插入，保证 source 位于 menuconfig HWMON 块内。
    # 找不到结束标记时退回文件末尾追加——此时 Kconfig 语法仍合法（顶层 source），
    # 符号照样能被 olddefconfig 识别，只是不挂在 HWMON 菜单下。
    if grep -q '^endif # HWMON$' "$HWMON_KCONFIG"; then
      awk '
        { if ($0 == "endif # HWMON" && !done) {
            print "source \"drivers/hwmon/airpi-gpio-fan/Kconfig\"";
            print "";
            done = 1;
          }
          print }
      ' "$HWMON_KCONFIG" > "$HWMON_KCONFIG.tmp" && mv -f "$HWMON_KCONFIG.tmp" "$HWMON_KCONFIG"
      log "已在 drivers/hwmon/Kconfig 的 'endif # HWMON' 前 source airpi-gpio-fan/Kconfig"
    else
      printf '\nsource "drivers/hwmon/airpi-gpio-fan/Kconfig"\n' >> "$HWMON_KCONFIG"
      log "drivers/hwmon/Kconfig 未见 'endif # HWMON'，已追加 source 至文件末尾"
    fi
  else
    log "drivers/hwmon/Kconfig 已 source airpi-gpio-fan/Kconfig，跳过"
  fi
  grep -n 'airpi-gpio-fan' "$HWMON_KCONFIG" | sed 's/^/[build-kernel]   /'

  [[ -f "$KERNEL_SRC/drivers/hwmon/airpi-gpio-fan/Kbuild" ]] \
    || die "板级源码层未落到 drivers/hwmon/airpi-gpio-fan/（检查 kernel/files-boards/$BOARD/）"
  [[ -f "$KERNEL_SRC/drivers/hwmon/airpi-gpio-fan/Kconfig" ]] \
    || die "驱动 Kconfig 未落到 drivers/hwmon/airpi-gpio-fan/（缺 CONFIG_AIRPI_GPIO_FAN 符号定义会导致 olddefconfig 静默丢弃 =m）"
fi

log "注册本板 DTB 到 arch/arm64/boot/dts/mediatek/Makefile：$BOARD_DTB_FILE"
if ! grep -q "${BOARD_DTB_FILE}\b" "$DTS_TARGET/Makefile"; then
  printf '\n# %s (Debian 13 port)\ndtb-$(CONFIG_ARCH_MEDIATEK) += %s\n' \
    "$BOARD_NAME" "$BOARD_DTB_FILE" >> "$DTS_TARGET/Makefile"
fi
grep -n "$BOARD_DTB_FILE" "$DTS_TARGET/Makefile" | sed 's/^/[build-kernel]   /'

# ---------------------------------------------------------------- 4. 内核配置
log "生成 .config（arm64 defconfig + 增量片段）"
make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" defconfig >/dev/null
cat "$CONFIG_FILE" >> "$KERNEL_SRC/.config"
make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig >/dev/null

log "核验关键配置项（板级：$BOARD / $BOARD_SOC）："
# 通用集：与 SoC 无关的路由器基础能力 + 存储栈 + GPT 分区名 + 挂死可诊断性。
# 说明：
#   root=PARTLABEL=rootfs 依赖 EFI_PARTITION；OVERLAY_FS/SQUASHFS/DEVTMPFS_MOUNT/
#   BLK_DEV_LOOP 是 SquashFS+OverlayFS 引导层的四条腿；ARM64_PSEUDO_NMI 是
#   「CPU 关中断自旋时仍能拿到 per-CPU 回栈」的唯一途径（2026-10-09 静默冻结实测教训）。
REQUIRED_SYMBOLS=(
  CONFIG_ARCH_MEDIATEK CONFIG_NET_MEDIATEK_SOC CONFIG_MEDIATEK_GE_PHY
  CONFIG_REALTEK_PHY CONFIG_MMC_MTK CONFIG_PWM_MEDIATEK CONFIG_SENSORS_PWM_FAN
  CONFIG_USB_XHCI_MTK CONFIG_BRIDGE CONFIG_NF_TABLES CONFIG_NFT_MASQ
  CONFIG_IPV6 CONFIG_EXT4_FS
  # ---- WAN 拨号 / 硬件流卸载 / 5G 模组（回归校验，防换环境重编丢符号）----
  CONFIG_PPPOE CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD
  CONFIG_MTK_NET_PHYLIB
  CONFIG_WWAN CONFIG_USB_NET_QMI_WWAN CONFIG_USB_NET_CDC_MBIM CONFIG_USB_SERIAL_OPTION
  # ---- 存储栈 / GPT 分区名 / 挂死可诊断性 / Wi-Fi 模块化 ----
  CONFIG_EFI_PARTITION CONFIG_OVERLAY_FS CONFIG_SQUASHFS CONFIG_DEVTMPFS_MOUNT
  CONFIG_BLK_DEV_LOOP CONFIG_ARM64_PSEUDO_NMI CONFIG_CFG80211 CONFIG_MAC80211
)

# 板级附加符号：从 boards/<board>.board 的 BOARD_KERNEL_CONFIG 对应 SoC 推导。
# 这些符号名随 SoC 而变（PINCTRL_MT7987 vs PINCTRL_MT7981），故必须板级化，
# 否则换板卡后 build-kernel.sh --strict 会把正确配置误判为缺失而终止构建。
case "$BOARD_SYSUPGRADE_BOARD" in
  hiveton_h5000m)
    REQUIRED_SYMBOLS+=(
      CONFIG_PINCTRL_MT7987 CONFIG_COMMON_CLK_MT7987 CONFIG_COMMON_CLK_MT7987_ETHSYS
      CONFIG_PCS_MTK_LYNXI CONFIG_MEDIATEK_2P5GE_PHY
      CONFIG_MT7996E CONFIG_PCIE_MEDIATEK_GEN3 CONFIG_MTK_LVTS_THERMAL
    ) ;;
  airpi_ap3000m)
    REQUIRED_SYMBOLS+=(
      CONFIG_PINCTRL_MT7981 CONFIG_COMMON_CLK_MT7981 CONFIG_COMMON_CLK_MT7981_ETHSYS
      CONFIG_MT7915E
      # 风扇：软 PWM 走 GPIO 整数接口（GPIOLIB_LEGACY=y 钉死分支），
      # 硬 PWM 走 pwm-fan hwmon。两版硬件都在，缺任一项都会导致风扇不可控。
      CONFIG_GPIOLIB_LEGACY CONFIG_AIRPI_GPIO_FAN CONFIG_SENSORS_PWM_FAN
    ) ;;
  *)
    log "  [WARN] 板级 $BOARD_SYSUPGRADE_BOARD 无专属符号清单，仅校验通用集" ;;
esac

CONFIG_MISSING=0
for sym in "${REQUIRED_SYMBOLS[@]}"; do
  if grep -q "^${sym}=y\|^${sym}=m" "$KERNEL_SRC/.config"; then
    log "  [OK] $sym"
  else
    log "  [WARN] $sym 未启用（补丁未生效或符号名不匹配）"
    CONFIG_MISSING=1
  fi
done
if [[ "$CONFIG_MISSING" -eq 1 ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    die "关键配置项缺失（见上方 WARN）。--strict 模式下终止构建；如确认不需要请去掉 --strict。"
  else
    log "提示：以上 WARN 项可能因内核版本与补丁不匹配导致；加 --strict 可在缺失时终止构建。"
  fi
fi

# ---------------------------------------------------------------- 5. 编译
log "内核 + DTB + 模块并行编译（-j$JOBS）"
make -C "$KERNEL_SRC" -j"$JOBS" "${MAKE_VARS[@]}" Image dtbs modules >"$WORK/build.log" 2>&1 || {
  tail -n 60 "$WORK/build.log" >&2
  die "内核编译失败，日志：$WORK/build.log"
}

log "安装内核模块到 $MODULES_ROOT"
make -C "$KERNEL_SRC" -j"$JOBS" "${MAKE_VARS[@]}" \
  modules_install INSTALL_MOD_PATH="$MODULES_ROOT" INSTALL_MOD_STRIP=1 \
  >"$WORK/modinst.log" 2>&1 || {
  tail -n 60 "$WORK/modinst.log" >&2
  die "内核模块安装失败，日志：$WORK/modinst.log"
}
if [[ ! -d "$MODULES_ROOT/lib/modules" ]]; then
  die "modules_install 未产出 $MODULES_ROOT/lib/modules（请检查 CONFIG_MODULES 是否启用、安装路径是否正确）"
fi

# ---------------------------------------------------------------- 6. 收集产物
log "收集产物（板级：$BOARD / $BOARD_SOC）"
IMAGE="$KERNEL_SRC/arch/arm64/boot/Image"
DTB="$KERNEL_SRC/arch/arm64/boot/dts/mediatek/$BOARD_DTB_FILE"
[[ -f "$IMAGE" ]] || die "Image 未生成"
[[ -f "$DTB" ]]   || die "$BOARD_NAME DTB 未生成（$BOARD_DTB_FILE）"

install -Dm644 "$IMAGE" "$OUT_DIR/Image"
install -Dm644 "$DTB"   "$OUT_DIR/$BOARD_DTB_FILE"
# 真 zstd 压缩（扩展名 .zst 名实相符；RootFS 侧以 tar -I zstd -xf 解压）。
# 走管道 + zstd -T0 多线程：-c -f - 输出到 stdout 由 zstd 并行压缩，
# 相比 tar --zstd（单线程）在百 MB 级 lib/ 上明显更快。
tar -C "$MODULES_ROOT" -cf - lib | zstd -q -T0 -o "$OUT_DIR/modules.tar.zst"
[[ -s "$OUT_DIR/modules.tar.zst" ]] || die "modules.tar.zst 生成失败（空文件）"

# 导出内核真实生成的 .config（olddefconfig 展开后的完整配置）。
# 此前错误地导出了输入片段本身，导致 artifact 中的 config 无法反映真实构建配置。
cp "$KERNEL_SRC/.config" "$OUT_DIR/kernel-config-exported.config"
# SoC 选项快照：文件名带板级，避免两块板卡的产物在 artifact 里互相覆盖
grep -E "^(# )?CONFIG_(ARCH_MEDIATEK|PINCTRL_MT798[17]|COMMON_CLK_MT798[17]|MT79[0-9]+E|MEDIATEK_2P5GE_PHY)" \
  "$KERNEL_SRC/.config" > "$OUT_DIR/kernel-${BOARD}-soc-options.txt" || true
# 兼容旧产物名（H5000M 历史 artifact 名）：同内容再落一份，避免下游脚本改名断裂
if [[ "$BOARD" == "h5000m" ]]; then
  cp -f "$OUT_DIR/kernel-${BOARD}-soc-options.txt" "$OUT_DIR/kernel-mt7987-options.txt"
fi

log "完成。产物："
ls -lh "$OUT_DIR/Image" "$OUT_DIR/$BOARD_DTB_FILE" "$OUT_DIR/modules.tar.zst"

# ccache 统计（便于在 CI 日志里确认命中率，判断缓存是否生效）
if [[ -n "$CCACHE_BIN" ]]; then
  log "ccache 统计："
  "$CCACHE_BIN" -s | sed -n '1,12p' | sed 's/^/  /' || true
fi
