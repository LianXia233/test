#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M (MT7987A) — Debian 13 内核构建脚本
#
# 基于 ImmortalWrt master（target/linux/mediatek）已验证的 6.18 内核补丁与配置，
# 生成适用于 Debian 13 ARM64 的 Linux 6.18.x 内核：
#   Image / mt7987a-hiveton-h5000m.dtb / modules.tar.zst
#
# 用法：
#   bash build-kernel.sh [--kernel-version 6.18.54] [--config 文件]
#                        [--out 目录] [--jobs N]
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

KERNEL_VERSION="6.18.54"
CONFIG_FILE="$PROJECT_ROOT/build/kernel-conf/h5000m-6.18.config"
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
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
log "应用 ImmortalWrt 补丁（backport -> pending -> hack -> mediatek）"
PATCH_FAILED=0
apply_patch_series() {
  local series="$1"
  local dir patch name
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
      if git -C "$KERNEL_SRC" apply --check "$patch" 2>/dev/null; then
        git -C "$KERNEL_SRC" apply "$patch"
        log "  [OK] $series/$name"
      elif command -v patch >/dev/null 2>&1 \
        && patch -d "$KERNEL_SRC" -p1 --forward --dry-run < "$patch" >/dev/null 2>&1; then
        patch -d "$KERNEL_SRC" -p1 --forward < "$patch" >/dev/null
        log "  [OK] $series/$name（git apply 失败，patch 回退应用成功）"
      else
        log "  [FAIL] $series/$name（与内核 $KERNEL_VERSION 上下文不匹配，且 patch 回退无法应用）"
        PATCH_FAILED=1
      fi
    done
  done
}
apply_patch_series backport "$GENERIC_PATCH_DIR/backport"
apply_patch_series pending  "$GENERIC_PATCH_DIR/pending"
apply_patch_series hack     "$GENERIC_PATCH_DIR/hack"
apply_patch_series mediatek "$PATCH_DIR"
if [[ "$PATCH_FAILED" -eq 1 ]]; then
  if [[ "$SKIP_FAILED" -eq 1 ]]; then
    log "存在失败补丁，已按 --skip-failed-patches 继续（硬件功能可能不完整）"
  else
    die "存在失败补丁。请调整 --kernel-version（6.18.x 系列）后重试，或加 --skip-failed-patches 强制继续。"
  fi
fi

# ---------------------------------------------------------------- 3. 复制 DTS 并注册 DTB
log "复制 H5000M DTS / dtsi 到内核源码"
DTS_TARGET="$KERNEL_SRC/arch/arm64/boot/dts/mediatek"
mkdir -p "$DTS_TARGET"
cp -v "$DTS_DIR"/*.dts "$DTS_DIR"/*.dtsi "$DTS_TARGET/" >/dev/null

# OpenWrt/ImmortalWrt 源码文件（mtdsplit / mtk_bmt 等；files-* 目录按内核版本提供）
log "复制 OpenWrt files（generic + mediatek）到内核源码"
cp -a "$PROJECT_ROOT/kernel/files-generic/." "$KERNEL_SRC/"
cp -a "$PROJECT_ROOT/kernel/files-mediatek/." "$KERNEL_SRC/"

log "注册 H5000M DTB 到 arch/arm64/boot/dts/mediatek/Makefile"
if ! grep -q "mt7987a-hiveton-h5000m.dtb" "$DTS_TARGET/Makefile"; then
  printf '\n# Hiveton H5000M (Debian 13 port)\ndtb-$(CONFIG_ARCH_MEDIATEK) += mt7987a-hiveton-h5000m.dtb\n' >> "$DTS_TARGET/Makefile"
fi

# ---------------------------------------------------------------- 4. 内核配置
log "生成 .config（arm64 defconfig + 增量片段）"
make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" defconfig >/dev/null
cat "$CONFIG_FILE" >> "$KERNEL_SRC/.config"
make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig >/dev/null

log "核验关键配置项："
REQUIRED_SYMBOLS=(
  CONFIG_ARCH_MEDIATEK CONFIG_PINCTRL_MT7987 CONFIG_COMMON_CLK_MT7987
  CONFIG_COMMON_CLK_MT7987_ETHSYS CONFIG_NET_MEDIATEK_SOC CONFIG_MEDIATEK_GE_PHY
  CONFIG_REALTEK_PHY CONFIG_PCS_MTK_LYNXI CONFIG_MT76_CORE CONFIG_MT7996E
  CONFIG_MMC_MTK CONFIG_PCIE_MEDIATEK_GEN3 CONFIG_PWM_MEDIATEK CONFIG_SENSORS_PWM_FAN
  CONFIG_MTK_LVTS_THERMAL CONFIG_USB_XHCI_MTK CONFIG_BRIDGE CONFIG_NF_TABLES
  CONFIG_NFT_MASQ CONFIG_IPV6 CONFIG_EXT4_FS
  # ---- WAN 拨号 / 硬件流卸载 / 2.5G PHY / 5G 模组（回归校验，防换环境重编丢符号）----
  CONFIG_PPPOE CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD
  CONFIG_MEDIATEK_2P5GE_PHY CONFIG_MTK_NET_PHYLIB
  CONFIG_WWAN CONFIG_USB_NET_QMI_WWAN CONFIG_USB_NET_CDC_MBIM CONFIG_USB_SERIAL_OPTION
)
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
log "收集产物"
IMAGE="$KERNEL_SRC/arch/arm64/boot/Image"
DTB="$KERNEL_SRC/arch/arm64/boot/dts/mediatek/mt7987a-hiveton-h5000m.dtb"
[[ -f "$IMAGE" ]] || die "Image 未生成"
[[ -f "$DTB" ]]   || die "H5000M DTB 未生成"

install -Dm644 "$IMAGE" "$OUT_DIR/Image"
install -Dm644 "$DTB"   "$OUT_DIR/mt7987a-hiveton-h5000m.dtb"
# 真 zstd 压缩（扩展名 .zst 名实相符；RootFS 侧以 tar -I zstd -xf 解压）。
# 走管道 + zstd -T0 多线程：-c -f - 输出到 stdout 由 zstd 并行压缩，
# 相比 tar --zstd（单线程）在百 MB 级 lib/ 上明显更快。
tar -C "$MODULES_ROOT" -cf - lib | zstd -q -T0 -o "$OUT_DIR/modules.tar.zst"
[[ -s "$OUT_DIR/modules.tar.zst" ]] || die "modules.tar.zst 生成失败（空文件）"

cp "$CONFIG_FILE" "$OUT_DIR/kernel-config-exported.config"
grep -E '^(# )?CONFIG_(ARCH_MEDIATEK|PINCTRL_MT7987|COMMON_CLK_MT7987)' "$KERNEL_SRC/.config" \
  > "$OUT_DIR/kernel-mt7987-options.txt" || true

log "完成。产物："
ls -lh "$OUT_DIR/Image" "$OUT_DIR/mt7987a-hiveton-h5000m.dtb" "$OUT_DIR/modules.tar.zst"

# ccache 统计（便于在 CI 日志里确认命中率，判断缓存是否生效）
if [[ -n "$CCACHE_BIN" ]]; then
  log "ccache 统计："
  "$CCACHE_BIN" -s | sed -n '1,12p' | sed 's/^/  /' || true
fi
