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
#   /boot/                      引导文件：DTB + boot.scr（始终）；extlinux.conf + Image（仅 --keep-boot-image）
#
# 【启动链不变】BootROM → BL2 → FIP(U-Boot) → p4 FIT → kernel（root=PARTLABEL=rootfs）
#             → 挂 p5 引导层 ext4 → /sbin/init 组装 OverlayFS → switch_root → Debian 13。
#             BL2 / U-Boot / FIP / u-boot-env / factory / GPT 全程零改动。
#
# 【内存约束】sysupgrade 整包上传到设备 /tmp（tmpfs 占 RAM），门槛 ≤600 MiB：
#   kernel FIT ~13 MiB + 引导层（SquashFS ~120 MiB + 引导文件）≈ 150 MiB 级；
#   带 --keep-boot-image 时约 210 MiB 级（多一份解压态 Image），仍远低于门槛。
#
# 本脚本只生成两个可刷写文件，不创建分区表、不触碰任何块设备：
#   out/H5000M-debian13-kernel.bin  → dd 到 p4
#   out/H5000M-debian13-rootfs.bin  → dd 到 p5（引导层 ext4 镜像）
#
# 用法：
#   sudo bash build/make-sd-image.sh --out out \
#     --kernel-dir out/kernel --squashfs out/rootfs/rootfs.squashfs [--boot-dir out/boot] \
#     [--extra-mb 128] [--busybox /path/to/busybox] [--mirror https://deb.debian.org/debian] \
#     [--keep-boot-image] [--force-extra-mb]
#
# 【--keep-boot-image】把解压态 Image 另存一份到 p5 引导层 /boot，让 distro boot /
# extlinux 兜底引导（build/../boot/boot.cmd 的 p5 分支、/boot/extlinux/extlinux.conf）
# 真实可用。默认**关闭**：p4 的 FIT 已含同一内核，再存一份约 +60 MiB（见 CHANGELOG
# 2026-10-06"默认跳过 /boot/Image 冗余副本…省 60+ MiB"）。关闭时同时**不写**
# extlinux.conf，以免留下引用不存在文件的配置（那正是 2026-10-09 修掉的 P1 缺陷）。
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
# ext4 元数据 + journal + 默认 5% root 预留的经验开销（相对 payload）。
# 注意：/boot 下实际落盘的引导文件**不**算在这里——2026-10-09 起按真实字节单独计入
# BOOT_FILE_BYTES（见 §3），否则 --keep-boot-image 那 60 MiB 会游离在空间预算之外。
BOOT_FS_OVERHEAD_MB="24"
FORCE_EXTRA_MB=0
# 是否把解压态 Image 一并写入引导层 /boot（供 distro boot / extlinux 兜底引导）。
# 默认 0（省空间，与 CHANGELOG 2026-10-06 的决定一致）；1 时镜像约 +60 MiB。
KEEP_BOOT_IMAGE=0
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
  # 打印文件抬头注释块（第 2 行起，遇首个非注释行停止）——**不要写死行号**：
  # 旧实现 `sed -n '2,30p'` 恰在第 30 行截断，而"用法："段落从第 31 行才开始，
  # 于是 --help 从来不显示调用方法（新增参数在 --help 里同样看不见）。
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)       OUT_DIR="$2"; shift 2 ;;
    --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
    --squashfs)  SQUASHFS="$2"; shift 2 ;;
    --boot-dir)  BOOT_DIR="$2"; shift 2 ;;
    --extra-mb)       EXTRA_MB="$2"; shift 2 ;;
    --force-extra-mb) FORCE_EXTRA_MB=1; shift ;;
    --keep-boot-image) KEEP_BOOT_IMAGE=1; shift ;;
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
IMAGE_BYTES=$(stat -c %s "$IMAGE")

# /boot 兜底引导文件的**真实字节数，必须计入镜像尺寸与空闲预算**：
# 【P1 修复 2026-10-09】旧实现只按 (SquashFS + busybox) 算尺寸，把 DTB/boot.scr 笼统
# 算进 BOOT_FS_OVERHEAD_MB=24。而 --keep-boot-image 要往 /boot 再放一份解压态 Image
# （本平台 ~60 MiB，见 CHANGELOG 2026-10-06"省 60+ MiB"）——既撑大镜像又不进预算，
# 结果是 mkfs.ext4 -d 直接 ENOSPC，或侥幸建成却把空闲压到 errno 28 以下（实机起不来）。
BOOT_FILE_BYTES=0
if [[ -f "$DTB" ]]; then
  BOOT_FILE_BYTES=$(( BOOT_FILE_BYTES + $(stat -c %s "$DTB") ))
fi
if (( KEEP_BOOT_IMAGE == 1 )); then
  BOOT_FILE_BYTES=$(( BOOT_FILE_BYTES + IMAGE_BYTES ))
fi
if [[ -f "$BOOT_DIR/boot.scr" ]]; then
  BOOT_FILE_BYTES=$(( BOOT_FILE_BYTES + $(stat -c %s "$BOOT_DIR/boot.scr") ))
fi

IMG_SIZE_MB=$(( ( (SQ_BYTES + BB_SIZE + BOOT_FILE_BYTES) / 1048576 ) + EXTRA_MB ))
IMG_SIZE_MB=$(( (IMG_SIZE_MB + 7) / 8 * 8 ))   # 8 MiB 对齐

# 引导层空间断言：算出来的镜像在 grow-rootfs 扩容之前必须还剩足够空闲。
# 少了这一步，--extra-mb 24 一类取值会静默产出"能编译、能打包、实机起不来"的镜像。
PAYLOAD_MB=$(( (SQ_BYTES + BB_SIZE + BOOT_FILE_BYTES) / 1048576 + 1 ))
BOOT_FREE_MB=$(( IMG_SIZE_MB - PAYLOAD_MB - BOOT_FS_OVERHEAD_MB ))
if (( FORCE_EXTRA_MB == 0 )); then
  case "$EXTRA_MB" in
    ''|*[!0-9]*) die "--extra-mb 必须是非负整数：$EXTRA_MB" ;;
  esac
  (( EXTRA_MB >= MIN_EXTRA_MB )) || \
    die "--extra-mb=${EXTRA_MB} 低于下限 ${MIN_EXTRA_MB} MiB：grow-rootfs 扩容接手前引导层空闲不足，journal/NetworkManager state 会写满并报 errno 28 起不来。确知后果时用 --force-extra-mb 解除拦阻。"
  (( BOOT_FREE_MB >= MIN_BOOT_FREE_MB )) || \
    die "引导层预计空闲仅 ${BOOT_FREE_MB} MiB（需 ≥ ${MIN_BOOT_FREE_MB} MiB）：请调大 --extra-mb，或去掉 --keep-boot-image（其额外占用 /boot/Image 约 $(( IMAGE_BYTES / 1024 / 1024 )) MiB）。"
fi
log "生成引导层 ext4 镜像：$ROOTFS_IMG"
log "  SquashFS $(( SQ_BYTES / 1024 / 1024 )) MiB + busybox $(( BB_SIZE / 1024 / 1024 )) MiB + /boot 引导文件 $(( BOOT_FILE_BYTES / 1024 / 1024 )) MiB + 余量 ${EXTRA_MB} MiB → ${IMG_SIZE_MB} MiB（8 MiB 对齐）"
log "  预计引导层空闲 ≈ ${BOOT_FREE_MB} MiB（已扣除 ext4 元数据/journal/root 预留 ${BOOT_FS_OVERHEAD_MB} MiB）"
if (( KEEP_BOOT_IMAGE == 1 )); then
  log "  --keep-boot-image 已启用：/boot/Image（$(( IMAGE_BYTES / 1024 / 1024 )) MiB）+ extlinux.conf 将一并落盘"
else
  log "  /boot/Image 未落盘（默认省空间）：p5 兜底引导（boot.scr p5 分支 / extlinux）不可用；需要时加 --keep-boot-image"
fi
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
    echo "!!! H5000M: Overlay 组装失败（$*），进入救援流程 !!!" >&2
    # 【防 OOM 修复 2026-10-06】旧实现无条件重执行 init → 失败后无限循环：
    # 实机实测 437 轮（每轮挂 squashfs 泄漏 kmalloc-4k，约 465MiB）→ t=128s
    # "Kernel panic - not syncing: System is deadlocked on memory"。
    # 用 devtmpfs 计数器限制：本次进入只尝试一次救援，之后一律转串口应急 shell。
    N=0
    if [ -f "$RETRY_FILE" ]; then
        N=$($BB cat "$RETRY_FILE" 2>/dev/null)
        case "$N" in ''|*[!0-9]*) N=0 ;; esac
    fi
    N=$((N + 1))
    echo "$N" > "$RETRY_FILE" 2>/dev/null

    # 清理上一轮残留挂载，并释放上一轮泄漏的 loop 设备。
    # 【挂载点必须用变量，勿写死裸路径 —— P1 修复 2026-10-09】旧实现写死
    # "umount /rmerged"，而正常路径的真实挂载点是 /overlay/merged（$MERGED）：
    # 每轮 umount 都失败，overlay/loop 引用持续累积，反而加剧了它自己注释里那个
    # "437 轮 → deadlocked on memory" 的 OOM 循环。
    # 顺序：先摘 overlay（它同时持有 $MERGED 与 /rrw），再摘 rescue tmpfs，最后摘 /sq，
    # 这样 losetup -D 才不会被"设备仍在使用"挡下。
    for _m in "$MERGED" /rrw /sq; do
        $BB umount "$_m" 2>/dev/null && continue
        $BB umount -l "$_m" 2>/dev/null || true
    done
    $BB losetup -D 2>/dev/null || true

    # 重建只读 Debian 用户空间（若本轮连 squashfs 都没挂上，这一步同样失败 → 转 shell）
    $BB mount -t squashfs -o ro "$SQ" /sq 2>/dev/null || true

    # ---- 救援根：lower=/sq（只读 Debian 用户空间）+ upper/work=tmpfs（RAM 后备）----
    # 【别改回 lowerdir=/ + upperdir=/rrun/upper —— 那个组合 100% 构造不出来】
    #  ① 内核 overlayfs（6.5+）的 ovl_check_overlapping_layers() 直接拒绝
    #     "upper/work 位于任一 lower 层之内"的组合，返回 -EINVAL；旧实现
    #     upperdir=/rrun/upper 而 lowerdir=/，/ 又是一切路径的祖先 → 救援 overlay
    #     必然失败。文档承诺的"失败进入救援模式"在实机上从未成立过。
    #  ② lowerdir=/ 里只有 busybox + 本脚本，没有任何可用 userspace；pivot 后 exec
    #     /sbin/init 又回到本脚本自身 —— 这正是上面 OOM 循环的燃料。
    #  ③ upper 用 tmpfs 而非引导层 ext4：救援场景很可能正是 eMMC 写路径挂死
    #     （本仓库长期跟踪的 "msdc 写挂死"），往 ext4 写只会一起卡死；tmpfs 零落盘。
    #  ④ 只在 N==1 时尝试：$RETRY_FILE 位于 devtmpfs，每次开机归零 → 等价于
    #     "每次开机最多救援一次"；对同一确定性失败重复执行没有意义。
    if [ "$N" -eq 1 ] && $BB grep -qs ' /sq squashfs ' /proc/mounts; then
        $BB mkdir -p /rrw
        if $BB mount -t tmpfs -o mode=0755,size=128m tmpfs /rrw 2>/dev/null; then
            $BB mkdir -p /rrw/upper /rrw/work "$MERGED"
            if $BB mount -t overlay overlay \
                 -o "lowerdir=/sq,upperdir=/rrw/upper,workdir=/rrw/work" "$MERGED"; then
                cd "$MERGED"
                $BB mkdir -p tmpold
                if $BB pivot_root . tmpold; then
                    cd /
                    # pivot 成功后新根是 overlay 合并视图，busybox 只存在于 /tmpold 之下
                    if [ -x /tmpold/usr/bin/busybox ]; then
                        BB=/tmpold/usr/bin/busybox
                    fi
                    $BB mount --move /tmpold/dev /dev 2>/dev/null || true
                    $BB mount --move /tmpold/proc /proc 2>/dev/null || true
                    $BB mount --move /tmpold/sys /sys 2>/dev/null || true
                    echo "!!! H5000M: 救援模式就绪（/ 可写，上层为 tmpfs，重启不保留）!!!" >&2
                    exec "$BB" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /sbin/init
                fi
                echo "!!! 救援 pivot_root 失败，转串口应急 shell !!!" >&2
                cd /
            else
                echo "!!! 救援 overlay 挂载失败（lower=/sq upper=/rrw tmpfs），转串口应急 shell !!!" >&2
            fi
        else
            echo "!!! 救援 tmpfs 挂载失败，转串口应急 shell !!!" >&2
        fi
    else
        echo "!!! 救援前置条件不满足（第 $N 次进入 / SquashFS 是否已挂载见上），转串口应急 shell !!!" >&2
    fi

    # 终局兜底：串口应急 shell（/dev/console 交互，可手动修复）。
    # 【勿改回 exec /sbin/init】那会重新走一遍整套挂载流程（旧实现即如此，构成自循环）。
    echo "!!! 降级为串口应急 shell：可手动 'mount -o remount,rw /' 排查后 'exec /sbin/init' !!!" >&2
    while :; do
        "$BB" sh </dev/console >/dev/console 2>&1
        echo "!!! 应急 shell 退出，5 秒后重新进入（防 PID1 退出引发 panic）!!!" >&2
        $BB sleep 5
    done
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

# /boot 兜底引导文件（主路径为 p4 FIT；distro boot 兜底按需保留 Image/DTB/extlinux/boot.scr）
if [[ -f "$DTB" ]]; then
  cp -f "$DTB" "$STAGE/boot/mt7987a-hiveton-h5000m.dtb"
fi
if [[ -f "$BOOT_DIR/boot.scr" ]]; then
  cp -f "$BOOT_DIR/boot.scr" "$STAGE/boot/boot.scr"
  log "  boot.scr 已写入 /boot（distro boot 兜底；p5 分支依赖 /boot/Image，USB 分支需手工放入）"
fi

# 【P1 修复 2026-10-09】boot.scr 的 p5 分支与 extlinux.conf 都引用 /boot/Image，但全脚本
# 此前**从不**把 Image 放进 $STAGE（只把 FIT 写 p4，而 FIT 不能当 booti 的裸 Image 用），
# 于是这两个"兜底引导"在实机上 100% 以 "File not found: /boot/Image" 收场——
# 文档（docs/debian13-partition-plan.md §7"两套文件均已预置"）声称存在、实机并不存在。
# 处置：按开关决定，**配置与实现必须一致**：
#   开 → 落盘 /boot/Image + 写 extlinux.conf（兜底引导真实可用；镜像约 +60 MiB）
#   关 → 既不落 Image 也不留 extlinux.conf（默认省空间，且不留引用空气的配置）
if (( KEEP_BOOT_IMAGE == 1 )); then
  install -m 0644 "$IMAGE" "$STAGE/boot/Image"
  mkdir -p "$STAGE/boot/extlinux"
  cat > "$STAGE/boot/extlinux/extlinux.conf" <<EOF
# Hiveton H5000M Debian 13 — 备用引导（主引导为 p4 FIT，由现有 U-Boot bootm 加载）
# 本文件仅在 /boot/Image 同时存在时有意义；二者由 make-sd-image.sh --keep-boot-image 一同落盘。
# APPEND 带 rw：与 FIT_BOOTARGS / boot.cmd 三处 cmdline 保持一致（引导层 init 内 remount,rw 为兜底）。
LABEL H5000M Debian 13
    KERNEL ../Image
    FDT ../mt7987a-hiveton-h5000m.dtb
    APPEND earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait rw pci=pcie_bus_perf console=ttyS0,115200n8
EOF
  log "  /boot/Image 已写入（$(( IMAGE_BYTES / 1024 / 1024 )) MiB）+ /boot/extlinux/extlinux.conf 就位"
else
  # 不写 extlinux.conf：extlinux 的 KERNEL 只能是 booti 用的裸 Image，无法指向 p4 的 FIT；
  # 留一个引用不存在文件的配置，只会把"引导失败"伪装成"文件找不到"。
  rmdir "$STAGE/boot/extlinux" 2>/dev/null || true
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

# /boot 兜底引导自检：Image 与 extlinux.conf 必须**同进同退**。
# 2026-10-09 修掉的 P1 缺陷正是二者脱节（写了 extlinux.conf 却没有 Image）。
if (( KEEP_BOOT_IMAGE == 1 )); then
  debugfs -R 'stat /boot/Image' "$ROOTFS_IMG" 2>/dev/null | grep -q "Size: $IMAGE_BYTES" \
    && log "  [OK] /boot/Image 就位（$IMAGE_BYTES 字节，p5 兜底引导可用）" \
    || die "镜像内 /boot/Image 缺失或大小异常（$IMAGE_BYTES 字节）"
  debugfs -R 'stat /boot/extlinux/extlinux.conf' "$ROOTFS_IMG" 2>/dev/null | grep -q 'Size:' \
    && log "  [OK] /boot/extlinux/extlinux.conf 就位" || die "镜像内 extlinux.conf 缺失，兜底引导不可用"
else
  if debugfs -R 'stat /boot/extlinux/extlinux.conf' "$ROOTFS_IMG" 2>/dev/null | grep -q 'Size:'; then
    die "镜像内出现 /boot/extlinux/extlinux.conf 但未落盘 /boot/Image（未加 --keep-boot-image）：该配置必然引用不存在的文件，拒绝产出。"
  fi
  log "  [OK] 未落盘 /boot/Image 与 extlinux.conf（默认省空间，配置与实现一致）"
fi

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
