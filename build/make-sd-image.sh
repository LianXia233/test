#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — Debian 13 刷写包制作脚本（基于现有 OpenWrt eMMC 分区布局）
#
# 【布局基准】以设备当前 OpenWrt 的 GPT 分区为唯一基准（不重建、不重排）：
#   p1 u-boot-env  1 MiB    ← 原样保留
#   p2 factory     2 MiB    ← 原样保留
#   p3 fip         4 MiB    ← 原样保留
#   p4 kernel     30 MiB    ← 复用：写入 H5000M-debian13-kernel.bin（U-Boot 现有 bootm 流程不变）
#   p5 rootfs  ~7.2 GiB     ← 复用：写入 H5000M-debian13-rootfs.bin（ext4，PARTLABEL=rootfs）
#
# 本脚本只生成两个可刷写文件，不创建分区表、不触碰任何块设备：
#   out/H5000M-debian13-kernel.bin  → dd 到 p4（U-Boot 直接 bootm 加载）
#   out/H5000M-debian13-rootfs.bin  → dd 到 p5（或由 scripts/install-emmc.sh 刷写）
#
# 【瘦身模式（默认开启）】刷写包需经 sysupgrade 上传到设备 /tmp（tmpfs 占 RAM），
# 整包必须控制在设备内存可容纳范围（≤600 MiB）。默认执行：
#   1. 清理 apt lists / doc / man / info / 非中英文 locale 翻译（零功能损失）
#   2. 跳过 /boot/Image 冗余副本（p4 FIT 已含同一内核；extlinux 兜底路径保留 DTB）
#   3. 注入 h5000m-grow-rootfs.service：首启 resize2fs 在线扩满 p5（GPT 不动）
#   → rootfs 镜像默认 540 MiB（内容约 423 MiB，使用率 ~80%）
# --no-slim 恢复全量产出（自动估算尺寸），--keep-boot-image 保留 /boot/Image，
# --auto-size 按压缩包内容自动估算（约 +512 MiB 余量，历史行为）。
#
# FIT 镜像说明：与 OpenWrt 一致，内核以 LZMA 压缩打包进 FIT（p4 仅 30 MiB，
# 未压缩 Image 无法容纳）；U-Boot 的 bootm 自动解压并跳转。
#
# RootFS 内 /boot 保留备用引导文件（boot.scr / extlinux.conf / DTB），
# 兼容支持 distro boot（bootflow scan）的 U-Boot 作为兜底路径；主路径仍是 p4 FIT。
# 产出后用 build/make-sysupgrade-tar.sh 封装为 sysupgrade-tar 单文件固件。
#
# 用法：
#   sudo bash build/make-sd-image.sh \
#     --out out \
#     --kernel-dir out/kernel \
#     --rootfs out/rootfs/debian13-arm64-rootfs.tar.zst \
#     [--rootfs-size 540] [--no-slim] [--keep-boot-image] [--auto-size] \
#     [--boot-dir out/boot]
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
SLIM=1                            # 瘦身模式（默认开）：sysupgrade 需整包进 /tmp tmpfs（RAM）
ROOTFS_SIZE_MB="540"              # slim 模式默认 540 MiB（内容 ~423 MiB，使用率 ~80%）；留空 = 自动估算
ROOTFS_SIZE_EXPLICIT=""           # 用户显式传过 --rootfs-size 时置 1
KEEP_BOOT_IMAGE=0                 # /boot/Image 冗余副本（p4 FIT 已含同一内核），默认跳过
FIT_LOAD_ADDR="0x40000000"       # 与官方 OpenWrt FIT 一致（实测 H5000M sysupgrade.bin：Load/Entry = 0x40000000）

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)            OUT_DIR="$2"; shift 2 ;;
    --kernel-dir)     KERNEL_DIR="$2"; shift 2 ;;
    --rootfs)         ROOTFS_TAR="$2"; shift 2 ;;
    --boot-dir)       BOOT_DIR="$2"; shift 2 ;;
    --rootfs-size)    ROOTFS_SIZE_MB="$2"; ROOTFS_SIZE_EXPLICIT=1; shift 2 ;;
    --no-slim)        SLIM=0; shift ;;
    --keep-boot-image) KEEP_BOOT_IMAGE=1; shift ;;
    --auto-size)      ROOTFS_SIZE_MB=""; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

log() { printf '[make-sd-image] %s\n' "$*"; }
die() { printf '[make-sd-image] ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ 瘦身 + 首启扩容注入
# 瘦身：清理对运行零影响的缓存与文档（sysupgrade 整包需进设备 /tmp tmpfs）。
slim_rootfs() {
  local R="$1"
  log "瘦身模式：清理 apt lists / 文档 / 非中英文 locale 翻译"
  rm -rf "$R/var/lib/apt/lists"/* 2>/dev/null || true
  rm -rf "$R/usr/share/doc"/* 2>/dev/null || true
  rm -rf "$R/usr/share/man"/* 2>/dev/null || true
  rm -rf "$R/usr/share/info"/* 2>/dev/null || true
  if [[ -d "$R/usr/share/locale" ]]; then
    find "$R/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
      ! -name 'en*' ! -name 'zh*' ! -name 'C.*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
  fi
}

# 首启自动扩容：镜像小于 p5 分区（~7.2 GiB）时，由 systemd oneshot 单元在首次
# 启动 resize2fs 在线扩满分区（p5 本就是 GPT 全部剩余空间，不触碰分区表）。
inject_grow_service() {
  local R="$1"
  log "注入首启自动扩容服务 h5000m-grow-rootfs"
  install -d -m 0755 "$R/usr/local/sbin" "$R/etc/systemd/system" \
                     "$R/etc/systemd/system/multi-user.target.wants"
  cat > "$R/usr/local/sbin/h5000m-grow-rootfs" <<'GROWEOF'
#!/bin/sh
# 首启将 root 文件系统在线扩容到分区实际大小（PARTLABEL=rootfs / p5）
set -u
DEV="$(findmnt -n -o SOURCE / 2>/dev/null)"
[ -n "$DEV" ] || DEV=/dev/mmcblk0p5
MARKER=/var/lib/h5000m-rootfs-grown
[ -e "$MARKER" ] && exit 0
if command -v resize2fs >/dev/null 2>&1 && [ -b "$DEV" ]; then
    resize2fs "$DEV" && touch "$MARKER" && echo "rootfs grown: $DEV"
else
    echo "grow skipped: resize2fs/$DEV unavailable"
fi
exit 0
GROWEOF
  chmod 0755 "$R/usr/local/sbin/h5000m-grow-rootfs"
  cat > "$R/etc/systemd/system/h5000m-grow-rootfs.service" <<'SVCEOF'
[Unit]
Description=Grow root filesystem to fill partition (first boot)
ConditionPathExists=!/var/lib/h5000m-rootfs-grown
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/h5000m-grow-rootfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
  ln -sf /etc/systemd/system/h5000m-grow-rootfs.service \
         "$R/etc/systemd/system/multi-user.target.wants/h5000m-grow-rootfs.service"
}

# 规范化输入/输出路径为绝对路径：
# - mkimage 在 (cd "$WORK") 子 shell 中展开 "$FIT_OUT"；OUT_DIR 为相对路径时
#   FIT 输出会解析到 $WORK/out/...（父目录不存在）→ mkimage 失败并打印 usage；
# - 其余路径一并绝对化，消除任何 cd 上下文差异。
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
if [[ -d "$KERNEL_DIR" ]]; then KERNEL_DIR="$(cd "$KERNEL_DIR" && pwd)"; fi
if [[ -d "$(dirname "$ROOTFS_TAR")" ]]; then
  ROOTFS_TAR="$(cd "$(dirname "$ROOTFS_TAR")" && pwd)/$(basename "$ROOTFS_TAR")"
fi
if [[ -d "$BOOT_DIR" ]]; then BOOT_DIR="$(cd "$BOOT_DIR" && pwd)"; fi

IMAGE="$KERNEL_DIR/Image"
DTB="$KERNEL_DIR/mt7987a-hiveton-h5000m.dtb"
FIT_OUT="$OUT_DIR/H5000M-debian13-kernel.bin"
ROOTFS_IMG="$OUT_DIR/H5000M-debian13-rootfs.bin"
SIGN_KEY=""            # FIT 签名密钥目录；留空则不签名
SIGN_ARGS=()           # mkimage 附加参数（签名时填充；显式空数组保证 set -u 安全）

[[ -f "$IMAGE" ]] || die "缺少内核 Image：$IMAGE（先运行 build/build-kernel.sh）"
[[ -f "$DTB"   ]] || die "缺少 DTB：$DTB"
[[ -f "$ROOTFS_TAR" ]] || die "缺少 RootFS：$ROOTFS_TAR（先运行 build/build-rootfs.sh）"

# ---------------------------------------------------------------- 工具检测
# mkimage -f 打包 FIT 时会调用外部 dtc 编译 ITS（device-tree-compiler 包）
for tool in mkimage dtc lzma losetup mkfs.ext4 tar zstd; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install u-boot-tools device-tree-compiler xz-utils e2fsprogs tar zstd"
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
        kernel-1 {
            description = "ARM64 OpenWrt-style Linux 6.18 arm64 (Image, LZMA)";
            data = /incbin/("Image.lzma");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "lzma";
            load = <$FIT_LOAD_ADDR>;
            entry = <$FIT_LOAD_ADDR>;
            hash-1 { algo = "crc32"; };
            hash-2 { algo = "sha1"; };
        };

        fdt-1 {
            description = "ARM64 OpenWrt hiveton_h5000m device tree";
            data = /incbin/("mt7987a-hiveton-h5000m.dtb");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            compatible = "hiveton,h5000m";
            hash-1 { algo = "crc32"; };
            hash-2 { algo = "sha1"; };
        };
    };

    configurations {
        default = "config-1";

        config-1 {
            description = "OpenWrt hiveton_h5000m";
            kernel = "kernel-1";
            fdt = "fdt-1";
        };
    };
};
EOF

# Image.lzma 已由上方 lzma 压缩直接输出到 $WORK/Image.lzma（见 IMAGE_LZMA 定义），
# ITS 的 /incbin/() 相对 cwd（cd "$WORK"）解析，无需也不能再复制到自身。
cp -f "$DTB" "$WORK/mt7987a-hiveton-h5000m.dtb"
log "  mkimage 打包 FIT ..."
# 失败时保留 mkimage/dtc 的 stderr 以便诊断（仅屏蔽 stdout 进度噪声）
(
  cd "$WORK"
  mkimage "${SIGN_ARGS[@]}" -f h5000m.its "$FIT_OUT" >/dev/null
) || die "mkimage 打包 FIT 失败（检查上方 dtc/mkimage 输出；需安装 u-boot-tools + device-tree-compiler）"
log "  [OK] $FIT_OUT（$(stat -c %s "$FIT_OUT") 字节）"
dd if="$FIT_OUT" bs=1 count=4 status=none 2>/dev/null | od -An -tx1 | grep -q 'd0 0d fe ed' \
  && log "  [OK] FIT 魔数校验通过" \
  || die "生成的 FIT 魔数错误，mkimage 可能不兼容，请检查 u-boot-tools 版本"

# ---------------------------------------------------------------- 2. 生成 ext4 RootFS 镜像（p5 内容）
# 尺寸决策：slim 模式默认 540 MiB；--no-slim 且未显式指定尺寸时按压缩包内容自动估算
if [[ "$SLIM" -eq 0 && -z "$ROOTFS_SIZE_EXPLICIT" ]]; then
  ROOTFS_SIZE_MB=""
fi
if [[ -z "$ROOTFS_SIZE_MB" ]]; then
  log "未指定 --rootfs-size，按 RootFS 压缩包内容自动估算"
  CONTENT_BYTES="$(tar --use-compress-program=zstd -tvf "$ROOTFS_TAR" | awk '{s+=$3} END {print s+0}')"
  ROOTFS_SIZE_MB="$(( ( CONTENT_BYTES / 1048576 + 512 + 7 ) / 8 * 8 ))"   # 内容 + 512 MiB 余量，8 MiB 对齐
  if (( ROOTFS_SIZE_MB > 7372 )); then
    log "  估算 ${ROOTFS_SIZE_MB} MiB 超过 eMMC p5 上限（7.2 GiB），按 7372 MiB 处理"
    ROOTFS_SIZE_MB=7372
  fi
  log "  内容 ${CONTENT_BYTES} 字节 → RootFS 镜像 ${ROOTFS_SIZE_MB} MiB（含 512 MiB 余量，8 MiB 对齐）"
fi
log "生成 ext4 RootFS 镜像：$ROOTFS_IMG（${ROOTFS_SIZE_MB} MiB，可写入 8G eMMC 的 p5）"
truncate -s "${ROOTFS_SIZE_MB}M" "$ROOTFS_IMG"
mkfs.ext4 -q -F -L rootfs "$ROOTFS_IMG"

LOOP_DEV="$(losetup --find --show "$ROOTFS_IMG")"
MNT_ROOT="$WORK/root"
mkdir -p "$MNT_ROOT"
mount "$LOOP_DEV" "$MNT_ROOT"

log "解压 RootFS（tar.zst）→ 镜像"
tar --numeric-owner --xattrs --acls -I zstd -xf "$ROOTFS_TAR" -C "$MNT_ROOT"

# ---------------------------------------------------------------- 2.5 瘦身 + 首启扩容（默认启用）
if [[ "$SLIM" -eq 1 ]]; then
  slim_rootfs "$MNT_ROOT"
fi
inject_grow_service "$MNT_ROOT"

# 容量水位防护：解压+瘦身后的实际内容超过镜像 92% 时立即失败（避免解压中途 No space left）
USED_MB="$(du -sm --apparent-size "$MNT_ROOT" 2>/dev/null | cut -f1)"
LIMIT_MB=$(( ROOTFS_SIZE_MB * 92 / 100 ))
if (( USED_MB > LIMIT_MB )); then
  die "RootFS 实际内容 ${USED_MB} MiB 超过镜像 ${ROOTFS_SIZE_MB} MiB 的 92% 安全水位（${LIMIT_MB} MiB）。" \
      "请勿在 --no-slim 下使用默认尺寸，或调大 --rootfs-size。"
fi
log "RootFS 内容 ${USED_MB} MiB / 镜像 ${ROOTFS_SIZE_MB} MiB（水位 $(( USED_MB * 100 / ROOTFS_SIZE_MB ))%）"

# ---------------------------------------------------------------- 3. 写入备用引导文件（/boot）
# 主引导路径 = p4 FIT（现有 U-Boot bootm 流程，FIT 内已含同一内核 Image 的 LZMA 压缩包）。
# /boot/Image 冗余副本默认跳过（省 60+ MiB，sysupgrade 内存约束）；--keep-boot-image 恢复。
log "写入 /boot 备用引导文件（distro boot 兜底路径）"
mkdir -p "$MNT_ROOT/boot/extlinux"
if [[ "$KEEP_BOOT_IMAGE" -eq 1 ]]; then
  cp -f "$IMAGE" "$MNT_ROOT/boot/Image"
  log "  /boot/Image 已写入（--keep-boot-image）"
else
  log "  跳过 /boot/Image 冗余副本（p4 FIT 已含同一内核；--keep-boot-image 可恢复）"
fi
cp -f "$DTB"   "$MNT_ROOT/boot/mt7987a-hiveton-h5000m.dtb"

cat > "$MNT_ROOT/boot/extlinux/extlinux.conf" <<EOF
# Hiveton H5000M Debian 13 — 备用引导（主引导为 p4 FIT，由现有 U-Boot bootm 加载）
LABEL H5000M Debian 13
    KERNEL ../Image
    FDT ../mt7987a-hiveton-h5000m.dtb
    APPEND earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8
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
log "封装 sysupgrade-tar 单文件（推荐，sysupgrade -n 一条命令刷写）："
log "  bash build/make-sysupgrade-tar.sh --kernel $FIT_OUT --root $ROOTFS_IMG"
log "分区级刷写方法（在目标设备上执行，保持分区布局不变）："
log "  sudo bash scripts/install-emmc.sh --dev /dev/mmcblk0 \\"
log "    --kernel-fit $FIT_OUT --rootfs-img $ROOTFS_IMG"
ls -lh "$FIT_OUT" "$ROOTFS_IMG"
