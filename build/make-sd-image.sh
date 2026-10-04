#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — Debian 13 刷写包制作脚本（基于现有 OpenWrt eMMC 分区布局）
#
# 【布局基准】以设备当前 OpenWrt 的 GPT 分区为唯一基准（不重建、不重排）：
#   p1 u-boot-env  1 MiB    ← 原样保留
#   p2 factory     2 MiB    ← 原样保留
#   p3 fip         4 MiB    ← 原样保留
#   p4 kernel     30 MiB    ← 复用：写入 h5000m-kernel.fit（U-Boot 现有 bootm 流程不变）
#   p5 rootfs  ~7.2 GiB     ← 复用：写入 h5000m-rootfs.ext4.img（ext4，PARTLABEL=rootfs）
#
# 本脚本只生成两个可刷写文件，不创建分区表、不触碰任何块设备：
#   out/h5000m-kernel.fit    → dd 到 p4（U-Boot 直接 bootm 加载）
#   out/h5000m-rootfs.ext4.img → dd 到 p5（或由 scripts/install-emmc.sh 刷写）
#
# FIT 镜像说明：与 OpenWrt 一致，内核以 LZMA 压缩打包进 FIT（p4 仅 30 MiB，
# 未压缩 Image 无法容纳）；U-Boot 的 bootm 自动解压并跳转。
#
# RootFS 内 /boot 同时放入备用引导文件（boot.scr / extlinux.conf / Image / DTB），
# 兼容支持 distro boot（bootflow scan）的 U-Boot 作为兜底路径；主路径仍是 p4 FIT。
#
# 用法：
#   sudo bash build/make-sd-image.sh \
#     --out out \
#     --kernel-dir out/kernel \
#     --rootfs out/rootfs/debian13-arm64-rootfs.tar.zst \
#     [--rootfs-size 4096] [--boot-dir out/boot]
#
# 平台：仅 Linux（losetup / mount / mkfs.ext4 需要 root）。
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
  echo "[make-sd-image] 错误：本脚本仅支持 Linux（losetup / mount / mkfs）。Windows 请使用 WSL2。"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$PROJECT_ROOT/out"
KERNEL_DIR="$OUT_DIR/kernel"
ROOTFS_TAR="$OUT_DIR/rootfs/debian13-arm64-rootfs.tar.zst"
BOOT_DIR="$OUT_DIR/boot"
ROOTFS_SIZE_MB="4096"            # ext4 镜像大小（默认 4 GiB，可写入 8G eMMC 的 p5）
FIT_LOAD_ADDR="0x46000000"       # 与 Filogic U-Boot kernel_addr_r 一致

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)          OUT_DIR="$2"; shift 2 ;;
    --kernel-dir)   KERNEL_DIR="$2"; shift 2 ;;
    --rootfs)       ROOTFS_TAR="$2"; shift 2 ;;
    --boot-dir)     BOOT_DIR="$2"; shift 2 ;;
    --rootfs-size)  ROOTFS_SIZE_MB="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

IMAGE="$KERNEL_DIR/Image"
DTB="$KERNEL_DIR/mt7987a-hiveton-h5000m.dtb"
FIT_OUT="$OUT_DIR/h5000m-kernel.fit"
ROOTFS_IMG="$OUT_DIR/h5000m-rootfs.ext4.img"

[[ -f "$IMAGE" ]] || die "缺少内核 Image：$IMAGE（先运行 build/build-kernel.sh）"
[[ -f "$DTB"   ]] || die "缺少 DTB：$DTB"
[[ -f "$ROOTFS_TAR" ]] || die "缺少 RootFS：$ROOTFS_TAR（先运行 build/build-rootfs.sh）"

log() { printf '[make-sd-image] %s\n' "$*"; }
die() { printf '[make-sd-image] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 工具检测
for tool in mkimage lzma losetup mkfs.ext4 tar zstd; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install u-boot-tools xz-utils e2fsprogs tar zstd"
done
if [[ $(id -u) -ne 0 ]]; then
  echo "[make-sd-image] 需要 root 权限（losetup / mount / mkfs）。请用 sudo 运行。" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/h5000m-img.XXXXXX")"
cleanup() {
  if [[ -n "${LOOP_DEV:-}" ]]; then
    umount "$MNT_ROOT" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 生成 FIT 镜像（p4 内容）
log "生成 FIT 镜像：$FIT_OUT"
log "  内核：$IMAGE（LZMA 压缩）"
log "  DTB ：$DTB"
log "  load/entry：$FIT_LOAD_ADDR"

IMAGE_LZMA="$WORK/Image.lzma"
lzma -9 -f -c "$IMAGE" > "$IMAGE_LZMA" 2>/dev/null
IMAGE_LZMA_SIZE=$(stat -c %s "$IMAGE_LZMA")
log "  Image 压缩后：$(( IMAGE_LZMA_SIZE / 1024 / 1024 )) MiB（p4 分区 30 MiB）"
(( IMAGE_LZMA_SIZE < 28 * 1024 * 1024 )) || \
  die "压缩后内核超过 28 MiB，无法放入 30 MiB 的 p4 kernel 分区。请精简内核配置。"

cat > "$WORK/h5000m.its" <<EOF
/dts-v1/;

/ {
    description = "Hiveton H5000M Debian 13 (Trixie) kernel";
    #address-cells = <1>;

    images {
        kernel@1 {
            description = "Linux 6.18 arm64 (Image, LZMA)";
            data = /incbin/("Image.lzma");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "lzma";
            load = <$FIT_LOAD_ADDR>;
            entry = <$FIT_LOAD_ADDR>;
            hash@1 { algo = "crc32"; };
        };

        fdt@1 {
            description = "Hiveton H5000M device tree";
            data = /incbin/("mt7987a-hiveton-h5000m.dtb");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            compatible = "hiveton,h5000m";
            hash@1 { algo = "crc32"; };
        };
    };

    configurations {
        default = "conf@h5000m";

        conf@h5000m {
            description = "Hiveton H5000M Debian 13";
            kernel = "kernel@1";
            fdt = "fdt@1";
        };
    };
};
EOF

cp -f "$IMAGE_LZMA" "$WORK/Image.lzma"
cp -f "$DTB" "$WORK/mt7987a-hiveton-h5000m.dtb"
log "  mkimage 打包 FIT ..."
mkimage -f "$WORK/h5000m.its" "$FIT_OUT" >/dev/null 2>&1 || die "mkimage 打包 FIT 失败（请安装 u-boot-tools）"
log "  [OK] $FIT_OUT（$(stat -c %s "$FIT_OUT") 字节）"
dd if="$FIT_OUT" bs=1 count=4 status=none 2>/dev/null | od -An -tx1 | grep -q 'd0 0d fe ed' \
  && log "  [OK] FIT 魔数校验通过" \
  || die "生成的 FIT 魔数错误，mkimage 可能不兼容，请检查 u-boot-tools 版本"

# ---------------------------------------------------------------- 2. 生成 ext4 RootFS 镜像（p5 内容）
log "生成 ext4 RootFS 镜像：$ROOTFS_IMG（${ROOTFS_SIZE_MB} MiB，可写入 8G eMMC 的 p5）"
truncate -s "${ROOTFS_SIZE_MB}Mi" "$ROOTFS_IMG"
mkfs.ext4 -q -F -L rootfs "$ROOTFS_IMG"

LOOP_DEV="$(losetup --find --show "$ROOTFS_IMG")"
MNT_ROOT="$WORK/root"
mkdir -p "$MNT_ROOT"
mount "$LOOP_DEV" "$MNT_ROOT"

log "解压 RootFS（tar.zst）→ 镜像"
tar --numeric-owner --xattrs --acls -I zstd -xf "$ROOTFS_TAR" -C "$MNT_ROOT"

# ---------------------------------------------------------------- 3. 写入备用引导文件（/boot）
# 主引导路径 = p4 FIT（现有 U-Boot bootm 流程）。
# 以下备用文件供支持 distro boot（bootflow scan / extlinux）的 U-Boot 兜底使用。
log "写入 /boot 备用引导文件（distro boot 兜底路径）"
mkdir -p "$MNT_ROOT/boot/extlinux"
cp -f "$IMAGE" "$MNT_ROOT/boot/Image"
cp -f "$DTB"   "$MNT_ROOT/boot/mt7987a-hiveton-h5000m.dtb"

cat > "$MNT_ROOT/boot/extlinux/extlinux.conf" <<EOF
# Hiveton H5000M Debian 13 — 备用引导（主引导为 p4 FIT，由现有 U-Boot bootm 加载）
LABEL H5000M Debian 13
    KERNEL ../Image
    FDT ../mt7987a-hiveton-h5000m.dtb
    APPEND root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8
EOF

if [[ -f "$BOOT_DIR/boot.scr" ]]; then
  cp -f "$BOOT_DIR/boot.scr" "$MNT_ROOT/boot/boot.scr"
  log "  boot.scr 已写入 /boot（U-Boot distro boot 将优先执行）"
fi

sync
umount "$MNT_ROOT"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

log "校验 ext4 镜像："
e2fsck -fn "$ROOTFS_IMG" >/dev/null 2>&1 && log "  [OK] 文件系统检查通过" || log "  [WARN] 检查未完全通过（可忽略，刷入后由 e2fsck 修复）"

# ---------------------------------------------------------------- 4. 输出
log "=========================================="
log "刷写包生成完成："
log "  p4 ← $FIT_OUT"
log "  p5 ← $ROOTFS_IMG"
log "刷写方法（在目标设备上执行，保持分区布局不变）："
log "  sudo bash scripts/install-emmc.sh --dev /dev/mmcblk0 \\"
log "    --kernel-fit $FIT_OUT --rootfs-img $ROOTFS_IMG"
ls -lh "$FIT_OUT" "$ROOTFS_IMG"
