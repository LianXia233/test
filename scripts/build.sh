#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — Debian 13 一键构建（内核 + RootFS + SquashFS + 刷写包）
#
# 刷写包 = H5000M-debian13-kernel.bin（→ p4 kernel 分区）+ H5000M-debian13-rootfs.bin（→ p5 rootfs 分区，
# 引导层 ext4：/sbin/init + busybox + rootfs.squashfs + overlay），完全复用设备现有 OpenWrt
# 分区布局与启动链（不创建 / 不重建分区表）。
#
# 用法：
#   sudo bash scripts/build.sh \
#     --out /path/to/out \
#     --hostname h5000m-debian \
#     [--kernel-version 6.18.54] \
#     [--admin-password xxx] [--root-password xxx]
#
# 选项：
#   --skip-kernel   跳过内核构建（使用已有 --kernel-dir 或 out/kernel）
#   --skip-rootfs   跳过 RootFS 构建（使用已有 out/rootfs）
#   --no-image      不生成刷写包
#
# 平台：内核/rootfs/镜像构建均需 Linux（Windows 请用 WSL2，macOS 用 Docker/Linux VM）。

set -Eeuo pipefail

# ---------------------------------------------------------------- 平台检测
case "$(uname -s)" in
  Linux)   BUILD_PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) BUILD_PLATFORM="windows" ;;
  Darwin)  BUILD_PLATFORM="macos" ;;
  *)       BUILD_PLATFORM="unknown" ;;
esac
if [[ "$BUILD_PLATFORM" != "linux" ]]; then
  echo "[build] 错误：本脚本仅支持 Linux（debootstrap/loop 设备均依赖 Linux）。"
  echo "[build] Windows 请使用 WSL2，macOS 建议使用 Docker/Linux VM。"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$PROJECT_ROOT/out"
KERNEL_DIR="$OUT_DIR/kernel"
HOSTNAME="h5000m-debian"
KERNEL_VERSION="6.18.54"
ADMIN_PASSWORD=""
ROOT_PASSWORD=""
SKIP_KERNEL=0
SKIP_ROOTFS=0
NO_IMAGE=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)             OUT_DIR="$2"; shift 2 ;;
    --hostname)        HOSTNAME="$2"; shift 2 ;;
    --kernel-version)  KERNEL_VERSION="$2"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="$2"; shift 2 ;;
    --root-password)   ROOT_PASSWORD="$2"; shift 2 ;;
    --skip-kernel)     SKIP_KERNEL=1; shift ;;
    --skip-rootfs)     SKIP_ROOTFS=1; shift ;;
    --no-image)        NO_IMAGE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

KERNEL_DIR="$OUT_DIR/kernel"
mkdir -p "$OUT_DIR"
log() { printf '[build] %s\n' "$*"; }
die() { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. 内核
if [[ "$SKIP_KERNEL" -eq 0 ]]; then
  log "== 步骤 1/4：构建 Linux 内核 =="
  bash "$PROJECT_ROOT/build/build-kernel.sh" \
    --kernel-version "$KERNEL_VERSION" \
    --config "$PROJECT_ROOT/build/kernel-conf/h5000m-6.18.config" \
    --out "$KERNEL_DIR" \
    --strict
else
  log "== 步骤 1/4：跳过内核构建（使用 $KERNEL_DIR）=="
  for f in Image mt7987a-hiveton-h5000m.dtb modules.tar.zst; do
    [[ -f "$KERNEL_DIR/$f" ]] || die "缺少内核产物 $KERNEL_DIR/$f（--skip-kernel 需要完整产物）"
  done
fi

# ---------------------------------------------------------------- 1.5 mt5700（RootFS 前置依赖）
if [[ "$SKIP_ROOTFS" -eq 0 ]]; then
  log "== 步骤 1.5/4：交叉编译 luci-app-mt5700 at-webserver（Debian 分支）=="
  bash "$PROJECT_ROOT/build/build-mt5700.sh" --out "$OUT_DIR"
fi

# ---------------------------------------------------------------- 2. RootFS
ROOTFS_ARGS=(--out "$OUT_DIR" --hostname "$HOSTNAME" --kernel-dir "$KERNEL_DIR" --mt5700-dir "$OUT_DIR/mt5700")
[[ -n "$ADMIN_PASSWORD" ]] && ROOTFS_ARGS+=(--admin-password "$ADMIN_PASSWORD")
[[ -n "$ROOT_PASSWORD"  ]] && ROOTFS_ARGS+=(--root-password "$ROOT_PASSWORD")

if [[ "$SKIP_ROOTFS" -eq 0 ]]; then
  log "== 步骤 2/4：构建 Debian 13 RootFS（树，不打 tar.zst）=="
  bash "$PROJECT_ROOT/build/build-rootfs.sh" "${ROOTFS_ARGS[@]}" --skip-tar
else
  log "== 步骤 2/4：跳过 RootFS 构建 =="
  [[ -d "$OUT_DIR/rootfs/rootfs" ]] || \
    die "缺少 $OUT_DIR/rootfs/rootfs（--skip-rootfs 需要已有 RootFS 树）"
fi

# ---------------------------------------------------------------- 2.5 SquashFS（只读基础系统）
SQUASHFS_FILE="$OUT_DIR/rootfs/rootfs.squashfs"
if [[ "$SKIP_ROOTFS" -eq 1 && -f "$SQUASHFS_FILE" ]]; then
  log "== 步骤 2.5/4：跳过 SquashFS 生成（使用已有 $SQUASHFS_FILE）=="
else
  log "== 步骤 2.5/4：生成只读基础系统 SquashFS（zstd，含瘦身）=="
  sudo bash "$PROJECT_ROOT/build/make-squashfs.sh" \
    --out "$OUT_DIR" \
    --rootfs-dir "$OUT_DIR/rootfs/rootfs"
fi

# ---------------------------------------------------------------- 3. 刷写包（FIT + 引导层 ext4 镜像）
if [[ "$NO_IMAGE" -eq 0 ]]; then
  log "== 步骤 3/4：生成刷写包（H5000M-debian13-kernel.bin + H5000M-debian13-rootfs.bin）=="
  bash "$PROJECT_ROOT/build/make-sd-image.sh" \
    --out "$OUT_DIR" \
    --kernel-dir "$KERNEL_DIR" \
    --squashfs "$SQUASHFS_FILE" \
    --boot-dir "$OUT_DIR/boot"
else
  log "== 步骤 3/4：跳过刷写包生成（--no-image）=="
fi

log "全部完成。产物："
ls -lh "$KERNEL_DIR/Image" "$KERNEL_DIR/mt7987a-hiveton-h5000m.dtb" "$KERNEL_DIR/modules.tar.zst" \
  "$SQUASHFS_FILE" "$OUT_DIR/H5000M-debian13-kernel.bin" "$OUT_DIR/H5000M-debian13-rootfs.bin" 2>/dev/null || true
[[ -f "$OUT_DIR/rootfs/initial-credentials.txt" ]] && \
  log "初始凭据：$OUT_DIR/rootfs/initial-credentials.txt（chmod 600）"
