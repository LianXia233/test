#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — Debian 13 刷写包制作脚本（SquashFS + OverlayFS，复用现有 eMMC 分区布局）
#
# 【布局基准】以设备当前 OpenWrt 的 GPT 分区为唯一基准（不重建、不重排）：
#   p1 u-boot-env  1 MiB    ← 原样保留
#   p2 factory     2 MiB    ← 原样保留
#   p3 fip         4 MiB    ← 原样保留
#   p4 kernel     30 MiB    ← 复用：写入 H5000M-debian13-kernel.bin（U-Boot 现有 bootm 流程不变）
#   p5 rootfs  ~7.2 GiB     ← 复用：写入 H5000M-debian13-rootfs.bin（引导层 ext4，PARTLABEL=rootfs）
#
# 【p5 内容 = 引导层 ext4】（取代旧方案的整分区 ext4 Debian rootfs）：
#   /sbin/init                  引导脚本（busybox）：挂 SquashFS → 组装 OverlayFS → pivot_root → systemd
#   /usr/bin/busybox            静态 busybox（Debian busybox-static arm64 提取）
#   /squashfs/rootfs.squashfs   Debian 13 只读基础系统（SquashFS，zstd 压缩）
#   /overlay/{upper,work,merged} OverlayFS upper/work/挂载点（p5 剩余空间 = 持久化数据）
#   /boot/                      备用引导文件（DTB / extlinux.conf / boot.scr）
#
# 【启动链不变】BootROM → BL2 → FIP(U-Boot) → p4 FIT → kernel（root=PARTLABEL=rootfs）
#             → 挂 p5 引导层 ext4 → /sbin/init 组装 OverlayFS → switch_root → Debian 13。
#             BL2 / U-Boot / FIP / u-boot-env / factory / GPT 全程零改动。
#
# 【内存约束】sysupgrade 整包上传到设备 /tmp（tmpfs 占 RAM），门槛 ≤600 MiB：
#   kernel FIT ~13 MiB + 引导层（SquashFS ~120 MiB + 引导文件）≈ 150 MiB 级。
#
# 本脚本只生成两个可刷写文件，不创建分区表、不触碰任何块设备：
#   out/H5000M-debian13-kernel.bin  → dd 到 p4
#   out/H5000M-debian13-rootfs.bin  → dd 到 p5（引导层 ext4 镜像）
#
# 用法：
#   sudo bash build/make-sd-image.sh --out out \
#     --kernel-dir out/kernel --squashfs out/rootfs/rootfs.squashfs [--boot-dir out/boot] \
#     [--extra-mb 24] [--busybox /path/to/busybox] [--mirror http://deb.debian.org/debian]
#
# 平台：仅 Linux。行尾：本文件为 LF。
set -Eeuo pipefail

# ---------------------------------------------------------------- 平台检测
case "$(uname -s)" in
  Linux)   BUILD_PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) BUILD_PLATFORM="windows" ;;
  Darwin)  BUILD_PLATFORM="macos" ;;
  *)       BUILD_PLATFORM="unknown" ;;
esac
if [[ "$BUILD_PLATFORM" != "linux" ]]; then
  echo "[make-sd-image] 错误：本脚本仅支持 Linux（mkfs.ext4 -d）。Windows 请使用 WSL2。"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$PROJECT_ROOT/out"
KERNEL_DIR="$OUT_DIR/kernel"
SQUASHFS="$OUT_DIR/rootfs/rootfs.squashfs"
BOOT_DIR="$OUT_DIR/boot"
EXTRA_MB="24"                     # 引导层除 SquashFS 外的余量（busybox + DTB + ext4 元数据 + 缓冲）
BUSYBOX_LOCAL=""                  # 本地 busybox（arm64 静态）路径；空则从 Debian 下载
MIRROR="http://deb.debian.org/debian"
FIT_LOAD_ADDR="0x40000000"       # 与官方 OpenWrt FIT 一致（实测 H5000M sysupgrade.bin：Load/Entry = 0x40000000）

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)       OUT_DIR="$2"; shift 2 ;;
    --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
    --squashfs)  SQUASHFS="$2"; shift 2 ;;
    --boot-dir)  BOOT_DIR="$2"; shift 2 ;;
    --extra-mb)  EXTRA_MB="$2"; shift 2 ;;
    --busybox)   BUSYBOX_LOCAL="$2"; shift 2 ;;
    --mirror)    MIRROR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

log() { printf '[make-sd-image] %s\n' "$*"; }
die() { printf '[make-sd-image] ERROR: %s\n' "$*" >&2; exit 1; }

# 规范化路径为绝对路径（mkimage 在 (cd "$WORK") 子 shell 中展开相对路径会解析错）
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
if [[ -d "$KERNEL_DIR" ]]; then KERNEL_DIR="$(cd "$KERNEL_DIR" && pwd)"; fi
if [[ -d "$(dirname "$SQUASHFS")" ]]; then
  SQUASHFS="$(cd "$(dirname "$SQUASHFS")" && pwd)/$(basename "$SQUASHFS")"
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
[[ -f "$SQUASHFS" ]] || die "缺少 SquashFS：$SQUASHFS（先运行 build/make-squashfs.sh）"

# ---------------------------------------------------------------- 工具检测
# mkimage -f 打包 FIT 时会调用外部 dtc 编译 ITS（device-tree-compiler 包）
for tool in mkimage dtc lzma mkfs.ext4 e2fsck debugfs; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install u-boot-tools device-tree-compiler xz-utils e2fsprogs"
done
if [[ $(id -u) -ne 0 ]]; then
  echo "[make-sd-image] 需要 root 权限（mkfs.ext4 -d 保留属主/设备节点/xattr）。请用 sudo 运行。" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/h5000m-img.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ================================================================ 1. 生成 FIT 镜像（p4 内容）
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

cp -f "$DTB" "$WORK/mt7987a-hiveton-h5000m.dtb"
log "  mkimage 打包 FIT ..."
(
  cd "$WORK"
  mkimage "${SIGN_ARGS[@]}" -f h5000m.its "$FIT_OUT" >/dev/null
) || die "mkimage 打包 FIT 失败（检查上方 dtc/mkimage 输出；需安装 u-boot-tools + device-tree-compiler）"
log "  [OK] $FIT_OUT（$(stat -c %s "$FIT_OUT") 字节）"
dd if="$FIT_OUT" bs=1 count=4 status=none 2>/dev/null | od -An -tx1 | grep -q 'd0 0d fe ed' \
  && log "  [OK] FIT 魔数校验通过" \
  || die "生成的 FIT 魔数错误，mkimage 可能不兼容，请检查 u-boot-tools 版本"

# ================================================================ 2. 获取 busybox（arm64 静态）
BB_CACHE_DIR="$OUT_DIR/rootfs/.cache"
BUSYBOX_BIN="$WORK/busybox"
if [[ -n "$BUSYBOX_LOCAL" ]]; then
  [[ -f "$BUSYBOX_LOCAL" ]] || die "找不到 --busybox：$BUSYBOX_LOCAL"
  cp -f "$BUSYBOX_LOCAL" "$BUSYBOX_BIN"
  log "busybox：使用本地 $BUSYBOX_LOCAL"
else
  CACHE_DEB="$BB_CACHE_DIR/busybox-static_arm64.deb"
  CACHE_BIN="$BB_CACHE_DIR/busybox"
  if [[ -f "$CACHE_BIN" ]]; then
    cp -f "$CACHE_BIN" "$BUSYBOX_BIN"
    log "busybox：使用缓存 $CACHE_BIN"
  else
    log "busybox：从 Debian trixie 下载 busybox-static（arm64 静态，~2 MiB）"
    # 注意：不能用 "curl | xz | awk" 管道解析。awk 匹配后 exit 会关闭下游管道，
    # 使 xz / curl 收到 SIGPIPE（curl 退出码 23），在 set -Eeuo pipefail 下直接终止脚本。
    # 改为：先完整落盘 → 解压到文件 → awk 读文件，彻底规避 SIGPIPE。
    PKG_XZ="$WORK/Packages.xz"
    curl -sfL -o "$PKG_XZ" "$MIRROR/dists/trixie/main/binary-arm64/Packages.xz" \
      || die "下载 Packages.xz 失败：$MIRROR/dists/trixie/main/binary-arm64/Packages.xz"
    xz -dc "$PKG_XZ" > "$WORK/Packages" \
      || die "解压 Packages.xz 失败（检查 xz-utils 是否安装）"
    REL="$(awk '/^Package: busybox-static$/{f=1} f && /^Filename:/{print $2; exit}' "$WORK/Packages")"
    [[ -n "$REL" ]] || die "无法从 $MIRROR 解析 busybox-static 包路径（检查网络/镜像）"
    mkdir -p "$BB_CACHE_DIR"
    curl -sfL -o "$CACHE_DEB" "$MIRROR/$REL" || die "下载失败：$MIRROR/$REL"
    dpkg-deb -x "$CACHE_DEB" "$WORK/bb-extract"
    BB_CAND="$(find "$WORK/bb-extract" -type f -name busybox | head -1)"
    [[ -n "$BB_CAND" ]] || die "busybox-static.deb 内未找到 busybox 二进制"
    cp -f "$BB_CAND" "$BUSYBOX_BIN"
    cp -f "$BUSYBOX_BIN" "$CACHE_BIN"   # 缓存供后续构建复用
  fi
fi
BB_SIZE=$(stat -c %s "$BUSYBOX_BIN")
log "  busybox：$BB_SIZE 字节（静态 arm64）"

# ================================================================ 3. 构建引导层 staging（p5 内容）
STAGE="$WORK/stage"
SQ_BYTES=$(stat -c %s "$SQUASHFS")
IMG_SIZE_MB=$(( ( (SQ_BYTES + BB_SIZE) / 1048576 ) + EXTRA_MB ))
IMG_SIZE_MB=$(( (IMG_SIZE_MB + 7) / 8 * 8 ))   # 8 MiB 对齐
log "生成引导层 ext4 镜像：$ROOTFS_IMG"
log "  SquashFS $(( SQ_BYTES / 1024 / 1024 )) MiB + busybox $(( BB_SIZE / 1024 / 1024 )) MiB + 余量 ${EXTRA_MB} MiB → ${IMG_SIZE_MB} MiB（8 MiB 对齐）"

mkdir -p "$STAGE"/{sbin,bin,usr/bin,squashfs,boot/extlinux,sq,tmp,dev,proc,sys,etc,overlay/upper,overlay/work,overlay/merged}
install -m 0755 "$BUSYBOX_BIN" "$STAGE/usr/bin/busybox"
cp -f "$SQUASHFS" "$STAGE/squashfs/rootfs.squashfs"

# 引导层 init：挂 SquashFS → 组装 OverlayFS → pivot_root → 交棒 systemd
# （沙箱已验证：busybox applet 齐备；pivot_root 序列真机等价模拟通过）
cat > "$STAGE/sbin/init" <<'INIT_EOF'
#!/usr/bin/busybox sh
# H5000M (MT7987A) Debian 13 引导层 init —— SquashFS + OverlayFS 组装
# 内核已按 cmdline root=PARTLABEL=rootfs 挂载 p5（本引导层 ext4）为 /。
# 职责：挂 squashfs → 组装 overlay → pivot_root → 交棒 systemd。
set -u
BB=/usr/bin/busybox
$BB mkdir -p /dev /proc /sys /tmp /sq /overlay/upper /overlay/work /overlay/merged
$BB mount -t proc proc /proc 2>/dev/null || true
$BB mount -t sysfs sysfs /sys 2>/dev/null || true
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null || true   # 已挂载（DEVTMPFS_MOUNT）则忽略
SQ=/squashfs/rootfs.squashfs
MERGED=/overlay/merged
overlay_fail() {
    echo "!!! H5000M: Overlay 组装失败（$*），进入只读救援模式（无持久化）!!!" >&2
    $BB mkdir -p /rrun/upper /rrun/work /rmerged
    $BB mount -t overlay overlay -o lowerdir=/,upperdir=/rrun/upper,workdir=/rrun/work /rmerged 2>/dev/null || {
        echo "!!! 救援 overlay 失败：仅只读根，需串口 / U-Boot 重刷 !!!" >&2
        exec "$BB" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /sbin/init
    }
    cd /rmerged
    $BB mkdir -p tmpold
    $BB pivot_root . tmpold 2>/dev/null || true
    cd /
    $BB mount --move /tmpold/dev /dev 2>/dev/null || true
    $BB mount --move /tmpold/proc /proc 2>/dev/null || true
    $BB mount --move /tmpold/sys /sys 2>/dev/null || true
    exec "$BB" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /sbin/init
}
$BB mount -t squashfs -o ro "$SQ" /sq || overlay_fail "squashfs 挂载失败"
$BB mount -t overlay overlay \
    -o "lowerdir=/sq,upperdir=/overlay/upper,workdir=/overlay/work" "$MERGED" \
    || overlay_fail "overlay 挂载失败"
cd "$MERGED"
$BB mkdir -p tmpold
$BB pivot_root . tmpold || overlay_fail "pivot_root 失败"
cd /
$BB mount --move /tmpold/dev /dev 2>/dev/null || true
$BB mount --move /tmpold/proc /proc 2>/dev/null || true
$BB mount --move /tmpold/sys /sys 2>/dev/null || true
exec "$BB" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /sbin/init
INIT_EOF
chmod 0755 "$STAGE/sbin/init"

cat > "$STAGE/etc/fstab" <<'FSTAB_EOF'
# Hiveton H5000M — SquashFS + OverlayFS 布局
# 根文件系统 = overlay（lower=/sq 只读 SquashFS，upper/work=p5 引导层 /overlay），
# 由引导层 /sbin/init 在内核挂载 p5 后组装；此文件仅作布局说明，无运行时挂载项。
FSTAB_EOF

# /boot 兜底引导文件（主路径为 p4 FIT；distro boot 兜底保留 DTB/extlinux/boot.scr）
if [[ -f "$DTB" ]]; then
  cp -f "$DTB" "$STAGE/boot/mt7987a-hiveton-h5000m.dtb"
fi
cat > "$STAGE/boot/extlinux/extlinux.conf" <<EOF
# Hiveton H5000M Debian 13 — 备用引导（主引导为 p4 FIT，由现有 U-Boot bootm 加载）
LABEL H5000M Debian 13
    KERNEL ../Image
    FDT ../mt7987a-hiveton-h5000m.dtb
    APPEND earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8
EOF
if [[ -f "$BOOT_DIR/boot.scr" ]]; then
  cp -f "$BOOT_DIR/boot.scr" "$STAGE/boot/boot.scr"
  log "  boot.scr 已写入 /boot（U-Boot distro boot 兜底）"
fi

truncate -s "${IMG_SIZE_MB}M" "$ROOTFS_IMG"
mkfs.ext4 -q -F -L rootfs -d "$STAGE" "$ROOTFS_IMG"

# 镜像自检（免挂载：debugfs 读取 + e2fsck）
log "校验引导层镜像："
e2fsck -fn "$ROOTFS_IMG" >/dev/null && log "  [OK] e2fsck 检查通过" || die "e2fsck 未通过"
debugfs -R 'stat /sbin/init' "$ROOTFS_IMG" 2>/dev/null | grep -q 'Size:' \
  && log "  [OK] /sbin/init 就位" || die "镜像内 /sbin/init 缺失"
debugfs -R 'stat /squashfs/rootfs.squashfs' "$ROOTFS_IMG" 2>/dev/null | grep -q "Size: $SQ_BYTES" \
  && log "  [OK] /squashfs/rootfs.squashfs 就位（$SQ_BYTES 字节）" || die "镜像内 squashfs 文件异常"
debugfs -R 'stat /usr/bin/busybox' "$ROOTFS_IMG" 2>/dev/null | grep -q "Size: $BB_SIZE" \
  && log "  [OK] /usr/bin/busybox 就位（$BB_SIZE 字节）" || die "镜像内 busybox 异常"

# ================================================================ 4. 输出
log "=========================================="
log "刷写包生成完成："
log "  p4 ← $FIT_OUT（FIT 内核）"
log "  p5 ← $ROOTFS_IMG（引导层 ext4：init + busybox + SquashFS + overlay 目录）"
log "首启：/sbin/init 组装 OverlayFS → 首启扩容服务把 p5 扩满（~7.2 GiB，供 /etc /var 持久化）"
log "封装 sysupgrade-tar 单文件（推荐）："
log "  bash build/make-sysupgrade-tar.sh --kernel $FIT_OUT --root $ROOTFS_IMG"
log "分区级刷写方法（在目标设备上执行，保持分区布局不变）："
log "  sudo bash scripts/install-emmc.sh --dev /dev/mmcblk0 \\"
log "    --kernel-fit $FIT_OUT --rootfs-img $ROOTFS_IMG"
ls -lh "$FIT_OUT" "$ROOTFS_IMG"
