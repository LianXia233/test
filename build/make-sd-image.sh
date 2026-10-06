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
#     [--extra-mb 24] [--busybox /path/to/busybox] [--mirror https://deb.debian.org/debian]
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
# 引导层除 SquashFS 外的余量（busybox + DTB + boot 文件 + ext4 journal/元数据 + OverlayFS 缓冲）。
#
# 【为什么必须是 128 而不是 24 —— 实机启动失败根因之一，勿随意调小】
# 启动时序是：内核挂 p5 引导层 → /sbin/init 组装 OverlayFS → pivot_root → systemd →
#             h5000m-grow-rootfs.service 才执行 resize2fs 把 ext4 扩到 p5 实际大小（~7.2 GiB）。
# 也就是说 systemd 冷启动阶段，OverlayFS 的 upper/work 只能落在**引导层镜像内**这点空间上；
# 在 grow-rootfs 完成前，/var/log/journal、NetworkManager state、随机种子、tmp 等全部写这里。
# EXTRA_MB=24 时实测引导层 152 MiB 仅剩 **2.8 MiB** 空闲（journal + 5% root 预留吃掉大半），
# 内核直接报 "overlayfs: failed to create directory /overlay/work/work (errno: 28)" 并降级为
# 只读挂载，随后 pivot_root 失败 → 系统起不来（QEMU 已复现，与实机现象一致）。
# EXTRA_MB=128 时引导层 256 MiB、空闲 **100.2 MiB**，足以支撑到 grow-rootfs 扩容接手。
# 代价：sysupgrade 由 ~164 MiB 增至 ~270 MiB，仍在设备 /tmp(tmpfs) ≤600 MiB 门槛内。
EXTRA_MB="128"
# 【引导层空间下限 —— 实测依据见上方 EXTRA_MB 注释】
# grow-rootfs 扩容接手之前，冷启动阶段的 journal / NM state / tmp 全写在引导层里。
# --extra-mb 可以调，但不能调到让"引导层空闲"低于 MIN_BOOT_FREE_MB，否则
# 就会重现 errno 28 起不来。确知自己在做什么时用 --force-extra-mb 解除拦阻。
MIN_EXTRA_MB="96"
MIN_BOOT_FREE_MB="64"
# ext4 元数据 + journal + 默认 5% root 预留的经验开销（相对 payload）
BOOT_FS_OVERHEAD_MB="24"
FORCE_EXTRA_MB=0
BUSYBOX_LOCAL=""                  # 本地 busybox（arm64 静态）路径；空则从 Debian 下载
MIRROR="https://deb.debian.org/debian"
# FIT 内核 load/entry 必须用 0x46000000，不能照抄官方的 0x40000000：
# 板上 U-Boot（bl-mt798x，mt7987_airpi_h5000m_defconfig）TEXT_BASE=0x41e00000 且
# POSITION_INDEPENDENT，bootm_load_os 用 lmb_alloc_mem 要求
# [0x40000000, 0x40000000+解压尺寸) 整段空闲，窗口仅 30MiB；
# 本方案 LZMA 内核解压后 35~45MiB 必越界（报 Unable to allocate memory
# 0x40000000 for loading OS）。官方内核解压后仅 14.5MiB 故可同值。
# 0x46000000 与 U-Boot 自身区（0x41e00000+）、FIT 暂存区（0x60000000）均无冲突，
# 且为 2MB 对齐，满足 arm64 Image 装载对齐要求。
FIT_LOAD_ADDR="0x46000000"
# 【内嵌 bootargs，2026-10-06】OpenWrt 构建的 DTB 在 /chosen 内嵌了 bootargs
# （r31 产物实锤：earlycon=... root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf，
# 无 rw、无 console=ttyS0——实机串口 cmdline 与之逐字符一致）。若不覆写，
# 内核 cmdline 永远缺 rw（p5 ro 挂载 → init 只能靠 remount 兜底）且缺
# console=ttyS0（earlycon 交接后串口无输出）。此处打包时用 fdtput 覆写为
# 自包含、确定性的 cmdline（与参考仓库 ctr54188/h5000m-debian 同思路）。
# 注意：U-Boot env 的 bootargs 行为未知（可能覆写 fdt chosen），故 init 内
# remount,rw 兜底仍必须保留（双保险）。
FIT_BOOTARGS="${FIT_BOOTARGS:-console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait rw pci=pcie_bus_perf}"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)       OUT_DIR="$2"; shift 2 ;;
    --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
    --squashfs)  SQUASHFS="$2"; shift 2 ;;
    --boot-dir)  BOOT_DIR="$2"; shift 2 ;;
    --extra-mb)       EXTRA_MB="$2"; shift 2 ;;
    --force-extra-mb) FORCE_EXTRA_MB=1; shift ;;
    --busybox)   BUSYBOX_LOCAL="$2"; shift 2 ;;
    --mirror)    MIRROR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

log() { printf '[make-sd-image] %s\n' "$*"; }
die() { printf '[make-sd-image] ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$MIRROR" == https://* ]] || die "Debian mirror 必须使用 HTTPS：$MIRROR"

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
for tool in mkimage dtc fdtput fdtget lzma mkfs.ext4 e2fsck debugfs; do
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
# 覆写 DTB /chosen/bootargs：OpenWrt 原生 DTB 内嵌的 cmdline 缺 rw 与
# console=ttyS0（见 FIT_BOOTARGS 注释）。覆写后回读校验，失败即终止。
log "  覆写 /chosen/bootargs（fdtput）..."
fdtput -t s "$WORK/mt7987a-hiveton-h5000m.dtb" /chosen bootargs "$FIT_BOOTARGS" \
  || die "fdtput 覆写 bootargs 失败（device-tree-compiler 包）"
EMBEDDED="$(fdtget -t s "$WORK/mt7987a-hiveton-h5000m.dtb" /chosen bootargs 2>/dev/null || true)"
[[ "$EMBEDDED" == "$FIT_BOOTARGS" ]] \
  || die "bootargs 覆写校验失败：期望 [$FIT_BOOTARGS] 实际 [$EMBEDDED]"
log "  [OK] 内嵌 bootargs：$EMBEDDED"
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
# busybox 有效性校验：必须是足够大的 ELF（arm64 静态真身约 1.9 MiB）。
# 【根因修复，勿删】Debian trixie busybox-static_1.37.0-6+b9 包内有两个同名文件：
#   * usr/bin/busybox                                —— 真身（arm64 静态 ELF，~1.9 MiB）
#   * usr/share/initramfs-tools/conf-hooks.d/busybox —— 16 字节文本（内容 BUSYBOXDIR=/bin）
# find 不保证遍历顺序，曾把后者当二进制装入引导层 → 实机 /sbin/init（busybox 脚本）
# 的 shebang 指向无效 busybox → exec 失败 ENOEXEC(error -8) → "No working init
# found" panic（2026-10-06 实机串口 + CI 日志双重实锤）。禁止取"第一个命中"。
bb_is_valid() {
  [[ -f "$1" ]] || return 1
  [[ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] || return 1
  [[ "$(stat -c %s "$1")" -ge 512000 ]] || return 1
  return 0
}
BUSYBOX_BIN="$WORK/busybox"
if [[ -n "$BUSYBOX_LOCAL" ]]; then
  [[ -f "$BUSYBOX_LOCAL" ]] || die "找不到 --busybox：$BUSYBOX_LOCAL"
  cp -f "$BUSYBOX_LOCAL" "$BUSYBOX_BIN"
  log "busybox：使用本地 $BUSYBOX_LOCAL"
else
  CACHE_DEB="$BB_CACHE_DIR/busybox-static_arm64.deb"
  CACHE_BIN="$BB_CACHE_DIR/busybox"
  if bb_is_valid "$CACHE_BIN"; then
    cp -f "$CACHE_BIN" "$BUSYBOX_BIN"
    log "busybox：使用缓存 $CACHE_BIN"
  else
    rm -f "$CACHE_BIN"   # 缓存可能是坏文件（如 16 字节文本），删掉重下
    log "busybox：从 Debian trixie 下载 busybox-static（arm64 静态，~2 MiB）"
    # SIGPIPE 陷阱（务必保留）：本脚本使用 set -Eeuo pipefail。若 awk 命中目标即 exit，
    # 上游 curl/xz 会在写完前被关闭管道写入端而收到 SIGPIPE，整条流水线返回非 0 并被
    # set -e 捕获 —— 表现为"日志停在『下载 busybox-static』后静默退出"，极易误判为网络问题。
    # 规避：①curl 单独落盘（不进管道）；②awk 命中后清标志并读完输入，不提前关闭管道。
    PKG_XZ="$WORK/Packages.xz"
    curl -sfL -o "$PKG_XZ" "$MIRROR/dists/trixie/main/binary-arm64/Packages.xz" \
      || die "下载 Packages.xz 失败：$MIRROR/dists/trixie/main/binary-arm64/Packages.xz"
    REL="$(xz -dk -c "$PKG_XZ" | awk '/^Package: busybox-static$/{f=1} f && /^Filename:/{print $2; f=0}')"
    [[ -n "$REL" ]] || die "无法从 $MIRROR 解析 busybox-static 包路径（检查网络/镜像）"
    mkdir -p "$BB_CACHE_DIR"
    curl -sfL -o "$CACHE_DEB" "$MIRROR/$REL" || die "下载失败：$MIRROR/$REL"
    dpkg-deb -x "$CACHE_DEB" "$WORK/bb-extract"
    # 同理避免 head -1 提前关闭管道（pipefail 下的第二类 SIGPIPE 来源）
    # 候选筛选必须按「ELF 魔数 + 最小体积」，不能取第一个命中（见上方根因说明）
    BB_CAND=""
    mapfile -t BB_ALL < <(find "$WORK/bb-extract" -type f -name busybox)
    for cand in "${BB_ALL[@]}"; do
      if bb_is_valid "$cand"; then BB_CAND="$cand"; break; fi
    done
    [[ -n "$BB_CAND" ]] || die "busybox-static.deb 内未找到有效 busybox ELF（需 magic 7f454c46 且 >=512000B；conf-hooks.d/busybox 为 16 字节文本会被排除）"
    log "busybox：选中 $BB_CAND"
    cp -f "$BB_CAND" "$BUSYBOX_BIN"
    cp -f "$BUSYBOX_BIN" "$CACHE_BIN"   # 缓存供后续构建复用
  fi
fi
bb_is_valid "$BUSYBOX_BIN" || die "busybox 校验失败：$BUSYBOX_BIN 不是有效 arm64 ELF（拒绝装入引导层，避免实机 ENOEXEC panic）"
BB_SIZE=$(stat -c %s "$BUSYBOX_BIN")
log "  busybox：$BB_SIZE 字节（静态 arm64）"

# ================================================================ 3. 构建引导层 staging（p5 内容）
STAGE="$WORK/stage"
SQ_BYTES=$(stat -c %s "$SQUASHFS")
IMG_SIZE_MB=$(( ( (SQ_BYTES + BB_SIZE) / 1048576 ) + EXTRA_MB ))
IMG_SIZE_MB=$(( (IMG_SIZE_MB + 7) / 8 * 8 ))   # 8 MiB 对齐

# 引导层空间断言：算出来的镜像在 grow-rootfs 扩容之前必须还剩足够空闲。
# 少了这一步，--extra-mb 24 一类取值会静默产出"能编译、能打包、实机起不来"的镜像。
PAYLOAD_MB=$(( (SQ_BYTES + BB_SIZE) / 1048576 + 1 ))
BOOT_FREE_MB=$(( IMG_SIZE_MB - PAYLOAD_MB - BOOT_FS_OVERHEAD_MB ))
if (( FORCE_EXTRA_MB == 0 )); then
  case "$EXTRA_MB" in
    ''|*[!0-9]*) die "--extra-mb 必须是非负整数：$EXTRA_MB" ;;
  esac
  (( EXTRA_MB >= MIN_EXTRA_MB )) || \
    die "--extra-mb=${EXTRA_MB} 低于下限 ${MIN_EXTRA_MB} MiB：grow-rootfs 扩容前引导层空闲不足，"
  (( BOOT_FREE_MB >= MIN_BOOT_FREE_MB )) || \
    die "引导层预计空闲仅 ${BOOT_FREE_MB} MiB（需 ≥ ${MIN_BOOT_FREE_MB} MiB）："
fi
log "生成引导层 ext4 镜像：$ROOTFS_IMG"
log "  SquashFS $(( SQ_BYTES / 1024 / 1024 )) MiB + busybox $(( BB_SIZE / 1024 / 1024 )) MiB + 余量 ${EXTRA_MB} MiB → ${IMG_SIZE_MB} MiB（8 MiB 对齐）"
log "  预计引导层空闲 ≈ ${BOOT_FREE_MB} MiB（已扣除 ext4 元数据/journal/root 预留 ${BOOT_FS_OVERHEAD_MB} MiB）"
if (( FORCE_EXTRA_MB == 1 )); then
  log "  警告：--force-extra-mb 已启用，跳过空间下限校验"
fi

mkdir -p "$STAGE"/{sbin,bin,usr/bin,squashfs,boot/extlinux,sq,tmp,dev,proc,sys,etc,overlay/upper,overlay/work,overlay/merged}
install -m 0755 "$BUSYBOX_BIN" "$STAGE/usr/bin/busybox"
cp -f "$SQUASHFS" "$STAGE/squashfs/rootfs.squashfs"

# 引导层 init：挂 SquashFS → 组装 OverlayFS → pivot_root → 交棒 systemd
# （沙箱已验证：busybox applet 齐备；pivot_root 序列真机等价模拟通过）
cat > "$STAGE/sbin/init" <<'INIT_EOF'
#!/usr/bin/busybox sh
# H5000M (MT7987A) Debian 13 引导层 init —— SquashFS + OverlayFS 组装
# 内核已按 cmdline root=PARTLABEL=rootfs 挂载 p5（本引导层 ext4）为 /。
# 职责：remount rw → 挂 squashfs → 组装 overlay → pivot_root → 交棒 systemd。
set -u
BB=/usr/bin/busybox
RETRY_FILE=/dev/.h5000m_rescue_count   # devtmpfs 恒可写：root 只读时也能做救援计数
$BB mkdir -p /dev /proc /sys /tmp /sq /overlay/upper /overlay/work /overlay/merged
$BB mount -t proc proc /proc 2>/dev/null || true
$BB mount -t sysfs sysfs /sys 2>/dev/null || true
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null || true   # 已挂载（DEVTMPFS_MOUNT）则忽略
# 【根因修复 2026-10-06，勿删】厂商 U-Boot env 默认 bootargs 不含 rw（实测串口：
# "Kernel command line: ... root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf"），
# 内核把 p5 以 ro 挂载 → /overlay/upper 不可写 → overlay mount EINVAL
# （实机日志："overlay: filesystem on /overlay/upper is read-only"）。
# 显式 remount 为 rw（幂等：本就 rw 时为 no-op）。多写几个变体兜底不同 busybox/内核行为。
$BB mount -o remount,rw / 2>/dev/null \
    || $BB mount -o remount,rw /dev/root / 2>/dev/null \
    || $BB mount -n -o remount,rw / 2>/dev/null \
    || echo "!!! H5000M: 根文件系统 remount,rw 失败（cmdline 可能含 ro），继续尝试 overlay !!!" >&2
SQ=/squashfs/rootfs.squashfs
MERGED=/overlay/merged
overlay_fail() {
    echo "!!! H5000M: Overlay 组装失败（$*），进入只读救援模式（无持久化）!!!" >&2
    # 【防 OOM 修复 2026-10-06】旧实现无条件重执行 init → 失败后无限循环：
    # 实机实测 437 轮（每轮挂 squashfs 泄漏 kmalloc-4k，约 465MiB）→ t=128s
    # "Kernel panic - not syncing: System is deadlocked on memory"。
    # 用 devtmpfs 计数器限重试 3 次；超限降级为串口应急 shell（可交互修复）。
    N=0
    if [ -f "$RETRY_FILE" ]; then
        N=$($BB cat "$RETRY_FILE" 2>/dev/null)
        case "$N" in ''|*[!0-9]*) N=0 ;; esac
    fi
    N=$((N + 1))
    echo "$N" > "$RETRY_FILE" 2>/dev/null
    if [ "$N" -ge 3 ]; then
        echo "!!! 救援已重试 $N 次，停止自动重试（防 OOM 循环）!!!" >&2
        echo "!!! 降级为串口应急 shell：可手动 'mount -o remount,rw /' 排查后 'exec /sbin/init' !!!" >&2
        while :; do
            "$BB" sh </dev/console >/dev/console 2>&1
            echo "!!! 应急 shell 退出，5 秒后重新进入（防 PID1 退出引发 panic）!!!" >&2
            $BB sleep 5
        done
    fi
    # 重试前清理上一轮挂载，减缓 loop/squashfs 缓存泄漏
    $BB umount /rmerged 2>/dev/null || true
    $BB umount /sq 2>/dev/null || true
    $BB losetup -D 2>/dev/null || true
    $BB mkdir -p /rrun/upper /rrun/work /rmerged
    $BB mount -t overlay overlay -o lowerdir=/,upperdir=/rrun/upper,workdir=/rrun/work /rmerged 2>/dev/null || {
        echo "!!! 救援 overlay 失败：仅只读根，需串口 / U-Boot 重刷 !!!" >&2
        exec "$BB" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /sbin/init
    }
    cd /rmerged
    $BB mkdir -p tmpold
    $BB pivot_root . tmpold 2>/dev/null || true
    cd /
    # 同上：救援路径 pivot 成功后 busybox 也要改经 /tmpold 引用；
    # 若 pivot 本身失败（仍在引导层根）则沿用原路径。
    if [ -x /tmpold/usr/bin/busybox ]; then
        BB=/tmpold/usr/bin/busybox
    fi
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
# 【关键】pivot_root 之后，当前根目录已切换为 OverlayFS 合并视图，其中并不包含
# /usr/bin/busybox —— busybox 只存在于引导层 ext4，此刻已被移动到 /tmpold 之下。
# 若继续沿用 $BB（相对新根的路径），后续每条 busybox 调用都会 "not found"，
# 最终 exec 失败 → init 退出 → "Attempted to kill init!" 内核 panic
# （该缺陷已在 QEMU 真实复现，累及实机无法启动，切勿删除下面这行）。
BB=/tmpold/usr/bin/busybox
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
