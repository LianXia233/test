#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — Debian 13 RootFS SquashFS 生成（只读基础系统）
#
# 流程：RootFS 树（build/build-rootfs.sh 产出）→ 副本瘦身 → mksquashfs →
#       out/rootfs/rootfs.squashfs
#
# 【为什么 SquashFS】sysupgrade 整包需上传到设备 /tmp（tmpfs 占 RAM）：
#   ext4 固定尺寸镜像（历史 540 MiB / 更早 1.15 GiB）把"空闲空间"也封进固件；
#   SquashFS 只装实际内容并整体压缩（本仓库 514 MiB 树 → zstd 约 120 MiB），
#   p5 的 ext4 在首启扩容后为 4 GiB（2026-10-09 起不再扩满 ~7.24 GiB），成为 OverlayFS 可写层。
#
# 压缩格式（--comp）：
#   zstd（默认）体积略大（实测 ~120 MiB vs xz ~106 MiB），解压快 5-10 倍，
#             对 MT7987A（A53）随机读 + 首启服务冷启动显著更友好；
#             需内核 CONFIG_SQUASHFS_ZSTD=y（本仓库 config 已启用）。
#   xz        体积最小，需内核 CONFIG_SQUASHFS_XZ=y（默认已启用）。
#
# 用法：
#   sudo bash build/make-squashfs.sh --out out \
#     [--rootfs-dir out/rootfs/rootfs] [--tar out/rootfs/debian13-arm64-rootfs.tar.zst] \
#     [--comp zstd|xz] [--no-slim] [--in-place]
#
# 平台：仅 Linux。行尾：本文件为 LF。
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$PROJECT_ROOT/out"
ROOTFS_DIR="$OUT_DIR/rootfs/rootfs"          # 输入：RootFS 树
ROOTFS_TAR=""                                # 可选输入：tar.zst（无树时解包）
COMP="zstd"                                  # zstd | xz
SLIM=1                                       # 瘦身默认开启
IN_PLACE=0                                   # 1 = 直接对输入树瘦身（省一份拷贝）
SQUASH_OUT="$OUT_DIR/rootfs/rootfs.squashfs"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)        OUT_DIR="$2"; SQUASH_OUT="$OUT_DIR/rootfs/rootfs.squashfs"; shift 2 ;;
    --rootfs-dir) ROOTFS_DIR="$2"; shift 2 ;;
    --tar)        ROOTFS_TAR="$2"; shift 2 ;;
    --comp)       COMP="$2"; shift 2 ;;
    --no-slim)    SLIM=0; shift ;;
    --in-place)   IN_PLACE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

log() { printf '[make-squashfs] %s\n' "$*"; }
die() { printf '[make-squashfs] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$COMP" == "zstd" || "$COMP" == "xz" ]] || die "--comp 仅支持 zstd / xz"

# ---------------------------------------------------------------- 工具检测
for tool in mksquashfs unsquashfs; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool。请安装：sudo apt-get install squashfs-tools"
done
[[ $(id -u) -eq 0 ]] || die "请用 sudo 运行（保留 RootFS 属主/设备节点/xattr 需要 root）"

mkdir -p "$OUT_DIR/rootfs"
SQUASH_OUT="$(mkdir -p "$(dirname "$SQUASH_OUT")" && cd "$(dirname "$SQUASH_OUT")" && pwd)/$(basename "$SQUASH_OUT")"

# ---------------------------------------------------------------- 输入准备
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/h5000m-sq.XXXXXX")"
SLIM_DIR=""   # 硬链接副本目录（仅瘦身且非 --in-place 时创建）
cleanup() {
  rm -rf "$TMPDIR_RUN"
  # 只清理副本目录本身；就地模式(--in-place)与纯流式(--no-slim)均无此目录
  [[ -n "${SLIM_DIR:-}" ]] && rm -rf "$SLIM_DIR" || true
}
trap cleanup EXIT

if [[ -n "$ROOTFS_TAR" ]]; then
  [[ -f "$ROOTFS_TAR" ]] || die "找不到 tar.zst：$ROOTFS_TAR"
  log "从 tar.zst 解包到临时目录（--rootfs-dir 未使用）"
  SRC="$TMPDIR_RUN/tree"
  mkdir -p "$SRC"
  tar --numeric-owner --xattrs --acls -I zstd -xf "$ROOTFS_TAR" -C "$SRC"
elif [[ -d "$ROOTFS_DIR" ]]; then
  SRC="$(cd "$ROOTFS_DIR" && pwd)"
else
  die "缺少 RootFS 树：$ROOTFS_DIR（先运行 build/build-rootfs.sh，或用 --tar 指定 tar.zst）"
fi

# ---------------------------------------------------------------- 瘦身（副本默认）
# 仅清理对运行零影响的缓存与文档；保留 apt/dpkg 元数据与全部功能包。
slim_tree() {
  local T="$1"
  log "瘦身：清理 apt lists / 文档 / man / info / 非中英文 locale / 日志缓存"
  rm -rf "$T/var/lib/apt/lists"/* 2>/dev/null || true
  rm -rf "$T/usr/share/doc"/* 2>/dev/null || true
  rm -rf "$T/usr/share/man"/* 2>/dev/null || true
  rm -rf "$T/usr/share/info"/* 2>/dev/null || true
  rm -rf "$T/var/cache/apt"/* "$T/var/cache/debconf"/* "$T/var/log"/* 2>/dev/null || true
  if [[ -d "$T/usr/share/locale" ]]; then
    find "$T/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
      ! -name 'en*' ! -name 'zh*' ! -name 'C.*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
  fi
}

WORK_TREE="$SRC"
if [[ "$SLIM" -eq 1 ]]; then
  if [[ "$IN_PLACE" -eq 1 ]]; then
    log "就地瘦身（--in-place：原树将被直接修改）"
    slim_tree "$WORK_TREE"
  else
    # 硬链接副本：只建目录项与 inode 链接，不复制数据。
    # 相比 cp -a 省掉数百 MiB 的全量读写（分钟级 → 秒级），也省同等磁盘空间。
    # 安全性：slim_tree 全部操作为 rm -rf（解除本副本的链接），不改写文件内容，
    #         因此不会穿透影响原树；若将来引入"清空/截断文件"类清理，须改回 cp -a。
    SLIM_DIR="${SRC%/}.slim.$$"
    if cp -al "$SRC" "$SLIM_DIR" 2>/dev/null; then
      log "硬链接副本（零数据拷贝，原树不受影响）：$SLIM_DIR"
    else
      log "硬链接不可用（跨文件系统？），回退完整复制 cp -a：$SLIM_DIR"
      rm -rf "$SLIM_DIR"
      cp -a "$SRC" "$SLIM_DIR"
    fi
    WORK_TREE="$SLIM_DIR"
    slim_tree "$WORK_TREE"
  fi
fi
TREE_MB=$(du -sm --apparent-size "$WORK_TREE" | cut -f1)
log "SquashFS 输入树：${TREE_MB} MiB"

# ---------------------------------------------------------------- mksquashfs
TIME_ARGS=()
[[ -n "$SOURCE_DATE_EPOCH" ]] && TIME_ARGS=(--mkfs-time "$SOURCE_DATE_EPOCH" --all-time "$SOURCE_DATE_EPOCH")

log "mksquashfs（-comp $COMP -b 256K）..."
rm -f "$SQUASH_OUT"
case "$COMP" in
  zstd) COMP_ARGS=(-comp zstd -Xcompression-level 19 -b 262144) ;;
  xz)   COMP_ARGS=(-comp xz -b 262144) ;;
esac
mksquashfs "$WORK_TREE" "$SQUASH_OUT" "${COMP_ARGS[@]}" \
  -noappend -no-recovery -processors "$(nproc)" "${TIME_ARGS[@]}" -quiet -no-progress
SQ_BYTES=$(stat -c %s "$SQUASH_OUT")
log "SquashFS：$SQUASH_OUT（$SQ_BYTES 字节 ≈ $(( SQ_BYTES / 1024 / 1024 )) MiB）"

# ---------------------------------------------------------------- 自检
log "自检："
SQ_INFO=$(unsquashfs -s "$SQUASH_OUT" 2>/dev/null)
echo "$SQ_INFO" | grep -E 'Compression|Block size' | sed 's/^/  /'
echo "$SQ_INFO" | grep -q "Compression $COMP" || die "压缩格式自检失败：期望 $COMP"
echo "$SQ_INFO" | grep -q 'Block size 262144' || die "块大小自检失败：期望 262144"
TMP_CHECK="$TMPDIR_RUN/check"
mkdir -p "$TMP_CHECK"
unsquashfs -q -d "$TMP_CHECK" -f "$SQUASH_OUT" etc/hostname > /dev/null 2>&1
[[ -f "$TMP_CHECK/etc/hostname" ]] || die "抽样读取失败：etc/hostname 不存在"
cmp "$TMP_CHECK/etc/hostname" "$WORK_TREE/etc/hostname" || die "抽样内容不一致：etc/hostname"
log "  [OK] 抽样文件（etc/hostname）与源树一致"

log "=========================================="
log "SquashFS 生成完成：$SQUASH_OUT"
log "下一步：build/make-sd-image.sh --squashfs $SQUASH_OUT（生成引导层 + sysupgrade）"
