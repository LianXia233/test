#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — SD / USB 启动镜像制作脚本
#
# 说明：H5000M 的 DTS 仅定义了 eMMC（mmc0，non-removable），无 SD 卡槽。
#       本脚本生成通用 GPT 磁盘镜像，可写入 USB 盘（若原厂 U-Boot 支持 USB 启动）
#       或用于 eMMC 直接安装（需先备份原 eMMC）。
#
# 分区布局（GPT）：
#   p1  64MiB  vfat   LABEL=H5000MBOOT  分区名 boot    -> Image / dtb / extlinux
#   p2  剩余   ext4   LABEL=H5000MROOT  分区名 rootfs  -> Debian 13 rootfs
#
# 内核 root=PARTLABEL=rootfs（与 H5000M DTS bootargs 一致）。
#
# 用法：
#   sudo bash build/make-sd-image.sh --out /path/to/out --img h5000m-debian13-sd.img
#   sudo dd if=h5000m-debian13-sd.img of=/dev/sdX bs=4M conv=fsync status=progress
#   # 或直接写入：
#   sudo bash build/make-sd-image.sh --out /path/to/out --dev /dev/sdX
#
# 平台：仅 Linux（loop / parted / mkfs）。

set -Eeuo pipefail

case "$(uname -s)" in
  Linux)   BUILD_PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) BUILD_PLATFORM="windows" ;;
  Darwin)  BUILD_PLATFORM="macos" ;;
  *)       BUILD_PLATFORM="unknown" ;;
esac
if [[ "$BUILD_PLATFORM" != "linux" ]]; then
  echo "[make-sd-image] 错误：本脚本仅支持 Linux。Windows 请使用 WSL2。"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$PROJECT_ROOT/out"
ROOTFS_TAR="$OUT_DIR/rootfs/debian13-arm64-rootfs.tar.zst"
IMG_FILE=""
DEVICE=""
IMG_SIZE_MB="2048"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)   OUT_DIR="$2"; shift 2 ;;
    --rootfs) ROOTFS_TAR="$2"; shift 2 ;;
    --img)   IMG_FILE="$2"; shift 2 ;;
    --dev)   DEVICE="$2"; shift 2 ;;
    --size)  IMG_SIZE_MB="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$IMG_FILE" || -n "$DEVICE" ]] || { usage; exit 1; }
[[ -f "$ROOTFS_TAR" ]] || die "缺少 RootFS：$ROOTFS_TAR"

for tool in parted mkfs.vfat mkfs.ext4 losetup zstd rsync; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install parted dosfstools e2fsprogs zstd rsync"
done

log() { printf '[make-sd-image] %s\n' "$*"; }
die() { printf '[make-sd-image] ERROR: %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/h5000m-img.XXXXXX")"
cleanup() {
  if [[ -n "${LOOP_DEV:-}" && -e "${LOOP_DEV}p1" ]]; then
    umount "${LOOP_DEV}p1" 2>/dev/null || true
    umount "${LOOP_DEV}p2" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
  [[ -n "${MNT_BOOT:-}" ]] && umount "$MNT_BOOT" 2>/dev/null || true
  [[ -n "${MNT_ROOT:-}" ]] && umount "$MNT_ROOT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

TARGET_DEV=""
if [[ -n "$DEVICE" ]]; then
  TARGET_DEV="$DEVICE"
  log "警告：将覆盖 $DEVICE 的全部数据！"
  log "请再次确认后继续（Ctrl-C 取消）。"
  sleep 3
  [[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV 不是块设备"
else
  TARGET_DEV="$OUT_DIR/$IMG_FILE"
  [[ "$IMG_FILE" == /* ]] && TARGET_DEV="$IMG_FILE"
  log "创建镜像文件 $TARGET_DEV（${IMG_SIZE_MB}MiB）"
  truncate -s "${IMG_SIZE_MB}Mi" "$TARGET_DEV"
fi

log "分区（GPT：boot 64MiB vfat / rootfs 剩余 ext4）"
parted -s "$TARGET_DEV" mklabel gpt
parted -s "$TARGET_DEV" mkpart boot 1MiB 65MiB
parted -s "$TARGET_DEV" mkpart rootfs 65MiB 100%
parted -s "$TARGET_DEV" name 1 boot
parted -s "$TARGET_DEV" name 2 rootfs
parted -s "$TARGET_DEV" set 1 boot on

# 建立可写设备的 loop 映射
if [[ -n "$DEVICE" ]]; then
  # 直写块设备：兼容 sdX（p1）与 nvme/mmcblk（p1 或 1）分区命名
  LOOP_DEV="$TARGET_DEV"
  if [[ -b "${TARGET_DEV}p1" ]]; then
    P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
  elif [[ -b "${TARGET_DEV}1" ]]; then
    P1="${TARGET_DEV}1"; P2="${TARGET_DEV}2"
  else
    die "无法定位 $TARGET_DEV 的分区（已创建 p1/p2）"
  fi
  # 内核重新读取分区表
  partprobe "$TARGET_DEV" 2>/dev/null || blockdev --rereadpt "$TARGET_DEV" 2>/dev/null || true
  sleep 1
else
  LOOP_DEV="$(losetup --find --show --partscan "$TARGET_DEV")"
  P1="${LOOP_DEV}p1"
  P2="${LOOP_DEV}p2"
  partprobe "$LOOP_DEV" 2>/dev/null || true
  sleep 1
fi

log "格式化：boot=vfat(H5000MBOOT)，rootfs=ext4(H5000MROOT)"
mkfs.vfat -n H5000MBOOT "$P1" >/dev/null
mkfs.ext4 -q -L H5000MROOT "$P2"

MNT_BOOT="$WORK/boot"
MNT_ROOT="$WORK/root"
mkdir -p "$MNT_BOOT" "$MNT_ROOT"

log "挂载并填充"
mount "$P1" "$MNT_BOOT"
mount "$P2" "$MNT_ROOT"

log "解压 rootfs 到 $MNT_ROOT"
tar --numeric-owner --xattrs --acls -xJf "$ROOTFS_TAR" -C "$MNT_ROOT"

log "复制启动文件到 boot 分区"
if [[ -d "$MNT_ROOT/boot" ]]; then
  cp -a "$MNT_ROOT/boot"/. "$MNT_BOOT/"
  # 清理 rootfs 内 boot 副本中的大镜像（保留 extlinux 配置与 fstab 挂载点）
  rm -f "$MNT_ROOT/boot/Image" "$MNT_ROOT/boot/mt7987a-hiveton-h5000m.dtb" || true
fi
# boot.scr（U-Boot 脚本）：优先于 extlinux 的兼容引导入口（boot/boot.cmd 编译产物）
BOOT_OUT="$OUT_DIR/boot"
if [[ -f "$BOOT_OUT/boot.scr" ]]; then
  cp -f "$BOOT_OUT/boot.scr" "$MNT_BOOT/boot.scr"
  cp -f "$BOOT_OUT/boot.cmd" "$MNT_BOOT/boot.cmd" 2>/dev/null || true
elif command -v mkimage >/dev/null 2>&1 && [[ -f "$PROJECT_ROOT/boot/boot.cmd" ]]; then
  log "生成 boot.scr（u-boot-tools）"
  mkimage -A arm64 -O linux -T script -C none -n "H5000M Debian 13 boot" \
    -d "$PROJECT_ROOT/boot/boot.cmd" "$MNT_BOOT/boot.scr" >/dev/null
fi

log "确保 boot 分区可启动文件齐全"
[[ -f "$MNT_BOOT/Image" ]] || die "boot 分区缺少 Image"
[[ -f "$MNT_BOOT/mt7987a-hiveton-h5000m.dtb" ]] || die "boot 分区缺少 DTB"
if [[ -f "$MNT_BOOT/boot.scr" ]]; then
  log "boot.scr 已就位：兼容 ImmortalWrt/OpenWrt Filogic U-Boot 自动引导"
elif [[ -f "$MNT_BOOT/extlinux/extlinux.conf" ]]; then
  log "警告：未找到 boot.scr，依赖 U-Boot 的 distro boot（extlinux）支持"
else
  log "警告：boot 分区无 boot.scr 也无 extlinux.conf，U-Boot 可能无法自动引导"
fi

sync
umount "$MNT_BOOT"; MNT_BOOT=""
umount "$MNT_ROOT"; MNT_ROOT=""

if [[ -n "$DEVICE" ]]; then
  log "完成。已写入 $DEVICE"
else
  losetup -d "$LOOP_DEV"; LOOP_DEV=""
  log "压缩镜像..."
  gzip -k -f "$TARGET_DEV"
  log "完成。镜像：$TARGET_DEV（约 ${IMG_SIZE_MB}MiB）"
  log "写入 USB 盘示例：sudo dd if=$TARGET_DEV of=/dev/sdX bs=4M conv=fsync status=progress"
fi
