#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M (MT7987A) — eMMC 刷入脚本（兼容当前 U-Boot 启动）
#
# 将 Debian 13 rootfs 与启动文件写入设备 eMMC：
#   分区 1  boot    64MiB  vfat  LABEL=H5000MBOOT  -> Image / DTB / boot.scr / extlinux
#   分区 2  rootfs  剩余   ext4  LABEL=H5000MROOT  -> Debian rootfs（root=PARTLABEL=rootfs）
#
# 在目标设备上运行（Debian live / OpenWrt initramfs / 已启动的 Debian），
# 也可以直接在已刷入 eMMC 的 Debian 中升级系统。U-Boot 无需改动：
# 只要把 boot.scr 放到 boot 分区，Filogic 系列 U-Boot 会自动加载。
#
# 用法：
#   sudo bash scripts/install-emmc.sh --rootfs out/rootfs/debian13-arm64-rootfs.tar.zst \
#       --boot-dir out/boot --kernel-dir out/kernel [--dev /dev/mmcblk0] [--yes]
#
# 平台：仅 Linux（parted / mkfs / tar 等）。
# 行尾：本文件为 LF。

set -Eeuo pipefail

# ---------------------------------------------------------------- 平台检测
case "$(uname -s)" in
  Linux)   BUILD_PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) BUILD_PLATFORM="windows" ;;
  Darwin)  BUILD_PLATFORM="macos" ;;
  *)       BUILD_PLATFORM="unknown" ;;
esac
if [[ "$BUILD_PLATFORM" != "linux" ]]; then
  echo "[install-emmc] 错误：eMMC 刷入仅支持在 Linux 上运行（目标设备环境）。"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE="/dev/mmcblk0"
ROOTFS_TAR=""
BOOT_DIR="$PROJECT_ROOT/out/boot"
KERNEL_DIR="$PROJECT_ROOT/out/kernel"
ASSUME_YES=0
BACKUP_FILE=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)       DEVICE="$2"; shift 2 ;;
    --rootfs)    ROOTFS_TAR="$2"; shift 2 ;;
    --boot-dir)  BOOT_DIR="$2"; shift 2 ;;
    --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
    --backup)    BACKUP_FILE="$2"; shift 2 ;;
    --yes)       ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$ROOTFS_TAR" ]] || { echo "[install-emmc] 必须指定 --rootfs（rootfs tar.zst）" >&2; exit 1; }
[[ -f "$ROOTFS_TAR" ]] || { echo "[install-emmc] 找不到 rootfs：$ROOTFS_TAR" >&2; exit 1; }
[[ -b "$DEVICE" ]] || { echo "[install-emmc] $DEVICE 不是块设备。请用 --dev 指定 eMMC 设备（如 /dev/mmcblk0）。" >&2; exit 1; }

log() { printf '[install-emmc] %s\n' "$*"; }
die() { printf '[install-emmc] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 工具检测
for tool in parted mkfs.vfat mkfs.ext4 zstd tar rsync; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install parted dosfstools e2fsprogs zstd rsync"
done

# ---------------------------------------------------------------- 危险操作确认
log "即将擦除并重写：$DEVICE"
log "设备信息：$(lsblk -dno NAME,SIZE,MODEL "$DEVICE" 2>/dev/null || echo '（无法读取）')"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "继续将丢失 $DEVICE 上全部数据，输入 yes 继续：" answer
  [[ "$answer" == "yes" ]] || die "已取消。"
fi

# 可选备份整盘
if [[ -n "$BACKUP_FILE" ]]; then
  log "备份 $DEVICE 到 $BACKUP_FILE（dd 全盘）..."
  dd if="$DEVICE" of="$BACKUP_FILE" bs=4M conv=fsync status=progress
fi

# ---------------------------------------------------------------- 分区
log "分区（GPT：boot 64MiB vfat / rootfs 剩余 ext4）"
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart boot 1MiB 65MiB
parted -s "$DEVICE" mkpart rootfs 65MiB 100%
parted -s "$DEVICE" name 1 boot
parted -s "$DEVICE" name 2 rootfs
parted -s "$DEVICE" set 1 boot on
partprobe "$DEVICE" 2>/dev/null || blockdev --rereadpt "$DEVICE" 2>/dev/null || true
sleep 2

# 兼容分区命名（mmcblk0p1 / mmcblk0p1 与 sdX1 等）
if [[ -b "${DEVICE}p1" ]]; then
  P1="${DEVICE}p1"; P2="${DEVICE}p2"
elif [[ -b "${DEVICE}1" ]]; then
  P1="${DEVICE}1"; P2="${DEVICE}2"
else
  die "无法定位 $DEVICE 的分区（已创建 p1/p2）"
fi

log "格式化：boot=vfat(H5000MBOOT)，rootfs=ext4(H5000MROOT)"
mkfs.vfat -n H5000MBOOT "$P1" >/dev/null
mkfs.ext4 -q -L H5000MROOT "$P2"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/h5000m-emmc.XXXXXX")"
MNT_BOOT="$WORK/boot"
MNT_ROOT="$WORK/root"
mkdir -p "$MNT_BOOT" "$MNT_ROOT"
cleanup() {
  umount "$MNT_BOOT" 2>/dev/null || true
  umount "$MNT_ROOT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mount "$P1" "$MNT_BOOT"
mount "$P2" "$MNT_ROOT"

# ---------------------------------------------------------------- rootfs
log "解压 rootfs 到 $P2"
tar --numeric-owner --xattrs --acls -xJf "$ROOTFS_TAR" -C "$MNT_ROOT"

# ---------------------------------------------------------------- boot 文件
log "写入 boot 分区启动文件"
BOOT_FILES_SRC=()
[[ -d "$BOOT_DIR" ]] && BOOT_FILES_SRC+=("$BOOT_DIR"/.)
[[ -d "$KERNEL_DIR" ]] && KERNEL_FILES=(Image mt7987a-hiveton-h5000m.dtb) || KERNEL_FILES=()
for f in "${KERNEL_FILES[@]}"; do
  [[ -f "$KERNEL_DIR/$f" ]] && cp -f "$KERNEL_DIR/$f" "$MNT_BOOT/"
done
if [[ ${#BOOT_FILES_SRC[@]} -gt 0 ]]; then
  cp -a "${BOOT_FILES_SRC[@]}" "$MNT_BOOT/" 2>/dev/null || true
fi
# 若 rootfs 内 boot 目录已有内核产物，一并取出（build-rootfs.sh 写入 /boot）
if [[ -d "$MNT_ROOT/boot" ]]; then
  cp -f "$MNT_ROOT/boot/Image" "$MNT_BOOT/" 2>/dev/null || true
  cp -f "$MNT_ROOT/boot/mt7987a-hiveton-h5000m.dtb" "$MNT_BOOT/" 2>/dev/null || true
fi

# 核验
[[ -f "$MNT_BOOT/Image" ]] || die "boot 分区缺少 Image"
[[ -f "$MNT_BOOT/mt7987a-hiveton-h5000m.dtb" ]] || die "boot 分区缺少 DTB"
if [[ -f "$MNT_BOOT/boot.scr" ]]; then
  log "boot.scr 已就位：U-Boot 将自动加载（兼容 ImmortalWrt/OpenWrt Filogic U-Boot）"
elif [[ -f "$MNT_BOOT/extlinux/extlinux.conf" ]]; then
  log "警告：未找到 boot.scr，依赖 U-Boot 的 distro boot（extlinux）支持"
else
  log "警告：boot 分区无 boot.scr 也无 extlinux.conf，U-Boot 可能无法自动引导"
fi

sync
umount "$MNT_BOOT"
umount "$MNT_ROOT"

# ---------------------------------------------------------------- U-Boot 环境（可选）
if command -v fw_setenv >/dev/null 2>&1; then
  log "检测到 fw_setenv，设置 U-Boot 启动环境（bootcmd 优先 boot.scr）..."
  fw_setenv bootcmd 'if load mmc 0:1 ${scriptaddr} boot.scr; then source ${scriptaddr}; fi; run distro_bootcmd' \
    2>/dev/null || log "警告：fw_setenv 设置失败（U-Boot env 分区可能不存在），忽略"
  fw_setenv scriptaddr 0x47000000 2>/dev/null || true
  fw_setenv bootargs "root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8" \
    2>/dev/null || true
else
  log "未检测到 fw_setenv（u-boot-tools），跳过 U-Boot 环境变量设置。"
  log "提示：若 U-Boot 未自动加载 boot.scr，可在 U-Boot 控制台手动执行："
  log "      load mmc 0:1 \${scriptaddr} boot.scr; source \${scriptaddr}"
fi

log "完成。$DEVICE 已刷入 Debian 13（root=PARTLABEL=rootfs）。"
log "可从 eMMC 重新启动设备，U-Boot 会自动引导（或参考上方手动引导命令）。"
