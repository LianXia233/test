#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M (MT7987A) — Debian 13 刷入脚本（复用现有 OpenWrt 分区布局）
#
# 【核心原则】以设备当前正常运行的 OpenWrt 分区布局 / 启动链为唯一基准：
#   p1 u-boot-env  1 MiB   ← 绝对不动
#   p2 factory     2 MiB   ← 绝对不动
#   p3 fip         4 MiB   ← 绝对不动（BL2 / U-Boot 所在）
#   p4 kernel     30 MiB   ← 复用：写入 Debian FIT 镜像（U-Boot 现有 bootm 流程不变）
#   p5 rootfs  ~7.2 GiB    ← 复用：写入 Debian 13 引导层 ext4（SquashFS + OverlayFS）
#
# 本脚本【绝不】执行以下操作：
#   * 不创建 / 重建 GPT（无 mklabel / mkpart / sgdisk 写操作 / fdisk）
#   * 不修改任何分区表的 Start / End / 名称 / PARTUUID
#   * 不触碰 p1(u-boot-env) / p2(factory) / p3(fip)
#   * 不修改 eMMC Boot Partition / EXT_CSD / RPMB / GP 分区（无 mmc 写操作）
#   * 不修改 U-Boot 环境（u-boot-env 分区保持原样，bootargs 由 DTS chosen 提供）
#
# 启动链保持不变：BootROM → BL2 → FIP(U-Boot) → U-Boot 从 p4 读取 FIT → bootm
#               → Kernel → root=PARTLABEL=rootfs 挂载 p5 → Debian 13
#
# 用法（目标设备：OpenWrt initramfs / Debian live / 已启动的 Debian）：
#   方式一：全新刷写（p4 + p5 整层重写；需在 p4/p5 未挂载的环境执行，如 initramfs/live）：
#     sudo bash scripts/install-emmc.sh \
#       --kernel-fit out/H5000M-debian13-kernel.bin \
#       --rootfs out/rootfs/debian13-arm64-rootfs.tar.zst [--dev /dev/mmcblk0] [--yes]
#     sudo bash scripts/install-emmc.sh \
#       --kernel-fit out/H5000M-debian13-kernel.bin \
#       --rootfs-img out/H5000M-debian13-rootfs.bin [--dev /dev/mmcblk0] [--yes]
#   方式二：运行中在线升级（SquashFS + OverlayFS 架构；保留 /etc /var 等全部持久化数据）：
#     sudo bash scripts/install-emmc.sh \
#       --kernel-fit out/H5000M-debian13-kernel.bin \
#       --rootfs-squashfs out/rootfs/rootfs.squashfs [--dev /dev/mmcblk0] [--yes]
#     仅替换 p5 上的 /squashfs/rootfs.squashfs（引导层 / overlay 数据不动）+ 刷新 p4 FIT，
#     旧版自动备份为 rootfs.squashfs.bak（重启前 mv 回去即可回退）。
#
# 平台：仅 Linux（dd / mkfs.ext4 / losetup / tar 等）。
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
KERNEL_FIT=""                 # p4 内容：FIT 镜像（.fit / .itb）
ROOTFS_TAR=""                 # p5 内容（全新刷写方式一）：rootfs tar.zst
ROOTFS_IMG=""                 # p5 内容（全新刷写方式二）：引导层/ext4 镜像
ROOTFS_SQUASHFS=""            # 在线升级模式：仅替换 p5 上的 SquashFS 文件（保留 overlay 数据）
BACKUP_FULL=""                # 可选：整盘备份文件
BACKUP_P45=""                 # 可选：p4+p5 内容备份文件
ASSUME_YES=0

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)              DEVICE="$2"; shift 2 ;;
    --kernel-fit)       KERNEL_FIT="$2"; shift 2 ;;
    --rootfs)           ROOTFS_TAR="$2"; shift 2 ;;
    --rootfs-img)       ROOTFS_IMG="$2"; shift 2 ;;
    --rootfs-squashfs)  ROOTFS_SQUASHFS="$2"; shift 2 ;;
    --backup-full)      BACKUP_FULL="$2"; shift 2 ;;
    --backup-p45)       BACKUP_P45="$2"; shift 2 ;;
    --yes)              ASSUME_YES=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- 输入校验
[[ -n "$KERNEL_FIT" ]] || { echo "[install-emmc] 必须指定 --kernel-fit（p4 的 FIT 镜像）" >&2; exit 1; }
[[ -f "$KERNEL_FIT" ]] || { echo "[install-emmc] 找不到 FIT：$KERNEL_FIT" >&2; exit 1; }
# 模式判定：--rootfs-squashfs = 运行中在线升级；--rootfs / --rootfs-img = 全新刷写（互斥三选一）
MODE_ONLINE=0
if [[ -n "$ROOTFS_SQUASHFS" ]]; then
  MODE_ONLINE=1
  [[ -z "$ROOTFS_IMG" && -z "$ROOTFS_TAR" ]] || {
    echo "[install-emmc] --rootfs-squashfs 为在线升级模式，不能与 --rootfs / --rootfs-img 同用" >&2; exit 1
  }
  [[ -f "$ROOTFS_SQUASHFS" ]] || { echo "[install-emmc] 找不到 SquashFS：$ROOTFS_SQUASHFS" >&2; exit 1; }
  # SquashFS 魔数校验（小端 "hsqs"）
  head -c 4 "$ROOTFS_SQUASHFS" | grep -q 'hsqs' || {
    echo "[install-emmc] $ROOTFS_SQUASHFS 不是 SquashFS 镜像（魔数 hsqs 不匹配）" >&2; exit 1
  }
else
  if [[ -n "$ROOTFS_IMG" && -n "$ROOTFS_TAR" ]]; then
    echo "[install-emmc] --rootfs-img 与 --rootfs 只能二选一" >&2; exit 1
  fi
  [[ -n "$ROOTFS_IMG" || -n "$ROOTFS_TAR" ]] || {
    echo "[install-emmc] 必须指定 --rootfs（tar.zst）或 --rootfs-img（ext4 镜像），或 --rootfs-squashfs（在线升级）" >&2; exit 1
  }
  if [[ -n "$ROOTFS_IMG" ]]; then
    [[ -f "$ROOTFS_IMG" ]] || { echo "[install-emmc] 找不到 ext4 镜像：$ROOTFS_IMG" >&2; exit 1; }
  fi
  if [[ -n "$ROOTFS_TAR" ]]; then
    [[ -f "$ROOTFS_TAR" ]] || { echo "[install-emmc] 找不到 rootfs：$ROOTFS_TAR" >&2; exit 1; }
  fi
fi
[[ -b "$DEVICE" ]] || { echo "[install-emmc] $DEVICE 不是块设备。请用 --dev 指定 eMMC（如 /dev/mmcblk0）。" >&2; exit 1; }

log() { printf '[install-emmc] %s\n' "$*"; }
die() { printf '[install-emmc] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 工具检测
for tool in dd mkfs.ext4 sgdisk; do
  command -v "$tool" >/dev/null 2>&1 || \
    die "缺少 $tool。请安装：sudo apt-get install gdisk e2fsprogs"
done
if [[ -n "$ROOTFS_TAR" ]]; then
  for tool in tar zstd losetup; do
    command -v "$tool" >/dev/null 2>&1 || \
      die "缺少 $tool（使用 tar.zst rootfs 需要）。请安装：sudo apt-get install tar zstd"
  done
fi

# ---------------------------------------------------------------- 1. 校验现有分区布局（只读）
# 使用 sgdisk 只读校验，绝不写入。
log "读取 $DEVICE 现有 GPT 分区表（只读校验）："
sgdisk -p "$DEVICE" >&2 || die "无法读取 $DEVICE 分区表，中止（绝不在未知布局上写入）。"

# 解析分区表为数组
mapfile -t PTLINES < <(sgdisk -p "$DEVICE" 2>/dev/null)
N_PART=0
declare -A PART_NUM PART_LABEL PART_SIZE PART_START PART_END
for line in "${PTLINES[@]}"; do
  # sgdisk -p 输出行形如：   4      16384    77823  30720   kernel
  [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+(.*)$ ]] || continue
  num="${BASH_REMATCH[1]}"; start="${BASH_REMATCH[2]}"; end="${BASH_REMATCH[3]}"
  size="${BASH_REMATCH[4]}"; label="$(echo "${BASH_REMATCH[5]}" | xargs)"
  PART_NUM[$num]="$num"; PART_START[$num]="$start"; PART_END[$num]="$end"
  PART_SIZE[$num]="$size"; PART_LABEL[$num]="$label"
  if (( num > N_PART )); then N_PART=$num; fi
done

# 校验 H5000M 原厂 GPT 布局。只检查存在 p4/p5 不够安全：任何带 5 个分区的
# 磁盘都可能被误当成目标设备，后续 dd/mkfs 会造成不可逆数据破坏。
(( N_PART >= 5 )) || die "分区数量不足 5（当前 $N_PART）。拒绝在非 H5000M 原厂布局上刷写。"
expect_part() {
  local num="$1" label="$2" start="$3" end="$4"
  [[ "${PART_LABEL[$num]:-}" == "$label" ]] || \
    die "p$num PARTLABEL 应为 '$label'，实际为 '${PART_LABEL[$num]:-（空）}'。拒绝刷写。"
  [[ "${PART_START[$num]:-}" == "$start" ]] || \
    die "p$num 起始扇区应为 $start，实际为 '${PART_START[$num]:-（空）}'。拒绝刷写。"
  if [[ -n "$end" && "${PART_END[$num]:-}" != "$end" ]]; then
    die "p$num 结束扇区应为 $end，实际为 '${PART_END[$num]:-（空）}'。拒绝刷写。"
  fi
}
expect_part 1 "u-boot-env" 2048 4095
expect_part 2 "factory"    4096 8191
expect_part 3 "fip"         8192 16383
expect_part 4 "kernel"     16384 77823
expect_part 5 "rootfs"     77824 ""

# 校验关键分区大小符合预期（p4 kernel 30MiB，p5 rootfs 至少 1GiB）
P4_SIZE_BYTES=$(( ${PART_SIZE[4]:-0} * 512 ))
P5_SIZE_BYTES=$(( ${PART_SIZE[5]:-0} * 512 ))
(( P4_SIZE_BYTES == 30 * 1024 * 1024 )) || die "p4 大小不是预期的 30 MiB（实际 $(( P4_SIZE_BYTES / 1024 / 1024 )) MiB）。拒绝刷写。"
(( P5_SIZE_BYTES >= 1024 * 1024 * 1024 )) || die "p5 小于 1 GiB（实际 $(( P5_SIZE_BYTES / 1024 / 1024 )) MiB）。拒绝刷写。"
log "p4 kernel 分区大小：$(( P4_SIZE_BYTES / 1024 / 1024 )) MiB（START=${PART_START[4]} END=${PART_END[4]}）"
log "p5 rootfs 分区大小：$(( P5_SIZE_BYTES / 1024 / 1024 )) MiB（START=${PART_START[5]} END=${PART_END[5]}）"

FIT_SIZE_BYTES=$(stat -c %s "$KERNEL_FIT")
(( FIT_SIZE_BYTES <= P4_SIZE_BYTES )) || \
  die "FIT 镜像（$(( FIT_SIZE_BYTES / 1024 / 1024 )) MiB）大于 p4 分区（$(( P4_SIZE_BYTES / 1024 / 1024 )) MiB）。"

LABEL_P4="${PART_LABEL[4]:-}"
LABEL_P5="${PART_LABEL[5]:-}"
log "p4 PARTLABEL = '${LABEL_P4:-（空）}'，p5 PARTLABEL = '${LABEL_P5:-（空）}'"

# 检查 p4/p5 是否被挂载（全新刷写必须在未挂载状态下进行；在线升级模式 p5 即运行中的 root，跳过检查）
for pn in 4 5; do
  if [[ "$MODE_ONLINE" -eq 1 && "$pn" -eq 5 ]]; then
    continue   # 在线升级：p5 是运行中系统的引导层，经引导层路径（/tmpold）替换文件，不整盘写
  fi
  devp=""
  [[ -b "${DEVICE}p${pn}" ]] && devp="${DEVICE}p${pn}"
  [[ -b "${DEVICE}${pn}" ]] && devp="${DEVICE}${pn}"
  if [[ -n "$devp" ]] && grep -q "^$(readlink -f "$devp")\|$(basename "$devp") " /proc/mounts 2>/dev/null; then
    die "$devp 已被挂载（设备正在运行或分区被占用）。请在 OpenWrt initramfs / Debian live 环境中执行，或使用 --rootfs-squashfs 在线升级模式。"
  fi
done

# ---------------------------------------------------------------- 2. 危险操作确认
log "----------------------------------------"
if [[ "$MODE_ONLINE" -eq 1 ]]; then
  log "【在线升级模式】仅做以下两步（OverlayFS 持久化数据 /etc /var /opt 全部保留）："
  log "  p4  ${DEVICE}p4  (kernel)                 ← 刷新 FIT 镜像"
  log "  p5  ${DEVICE}p5  引导层 /squashfs/rootfs.squashfs ← 原子替换（旧版备份为 .bak）"
  log "  GPT / p1 / p2 / p3 / 引导层其余内容 / overlay 数据：不变"
else
  log "将【仅】写入以下两个分区，其余区域（GPT / p1 / p2 / p3 / eMMC 硬件配置）保持不变："
  log "  p4  ${DEVICE}p4  (kernel, ${PART_LABEL[4]:-})  ← FIT 镜像"
  log "  p5  ${DEVICE}p5  (rootfs, ${PART_LABEL[5]:-})  ← Debian 13 引导层 ext4（SquashFS + OverlayFS）"
  log "  注意：p5 整层重写 = 恢复出厂（overlay 内的旧配置不保留）；需保留配置请用 --rootfs-squashfs 在线升级。"
fi
log "----------------------------------------"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "输入 yes 确认刷写：" answer
  [[ "$answer" == "yes" ]] || die "已取消。"
fi

# ---------------------------------------------------------------- 3. 可选备份（先备份后写入）
if [[ -n "$BACKUP_FULL" ]]; then
  log "整盘备份 $DEVICE → $BACKUP_FULL（dd，仅备份可读区域；不写入任何东西）..."
  dd if="$DEVICE" of="$BACKUP_FULL" bs=4M conv=fsync status=progress
fi
if [[ -n "$BACKUP_P45" ]]; then
  log "备份 p4 / p5 原始内容 → $BACKUP_P45.p4.img / $BACKUP_P45.p5.img ..."
  P4_DEV_BK=""; [[ -b "${DEVICE}p4" ]] && P4_DEV_BK="${DEVICE}p4" || P4_DEV_BK="${DEVICE}4"
  P5_DEV_BK=""; [[ -b "${DEVICE}p5" ]] && P5_DEV_BK="${DEVICE}p5" || P5_DEV_BK="${DEVICE}5"
  dd if="$P4_DEV_BK" of="$BACKUP_P45.p4.img" bs=4M conv=fsync status=progress
  dd if="$P5_DEV_BK" of="$BACKUP_P45.p5.img" bs=4M conv=fsync status=progress
  log "备份完成：$BACKUP_P45.p4.img / $BACKUP_P45.p5.img"
fi

# ---------------------------------------------------------------- 4. 写入 p4（kernel，FIT 镜像）
P4_DEV=""
[[ -b "${DEVICE}p4" ]] && P4_DEV="${DEVICE}p4"
[[ -b "${DEVICE}4" ]] && P4_DEV="${DEVICE}4"
[[ -n "$P4_DEV" ]] || die "无法定位 ${DEVICE}p4 / ${DEVICE}4 分区设备节点。"
log "写入 p4（$P4_DEV）：FIT 镜像（$FIT_SIZE_BYTES 字节）"
dd if="$KERNEL_FIT" of="$P4_DEV" bs=1M conv=fsync status=progress

# ---------------------------------------------------------------- 5. 写入 p5（rootfs）
P5_DEV=""
[[ -b "${DEVICE}p5" ]] && P5_DEV="${DEVICE}p5"
[[ -b "${DEVICE}5" ]] && P5_DEV="${DEVICE}5"
[[ -n "$P5_DEV" ]] || die "无法定位 ${DEVICE}p5 / ${DEVICE}5 分区设备节点。"

if [[ "$MODE_ONLINE" -eq 1 ]]; then
  # ---------------- 在线升级：仅替换引导层上的 SquashFS 文件 ----------------
  BOOT_LAYER=""
  for cand in /tmpold /mnt/p5-boot /media/p5-boot; do
    [[ -d "$cand/squashfs" && -f "$cand/squashfs/rootfs.squashfs" ]] && { BOOT_LAYER="$cand"; break; }
  done
  [[ -n "$BOOT_LAYER" ]] || die "未找到引导层路径（/tmpold/squashfs）。
本机当前不是 SquashFS + OverlayFS 运行架构（旧版 ext4 系统请用 --rootfs-img 全新刷写，或在串口/initramfs 环境执行）。"
  SQ_TARGET="$BOOT_LAYER/squashfs/rootfs.squashfs"
  SQ_NEW="$SQ_TARGET.new"
  SQ_BAK="$SQ_TARGET.bak"
  SQ_SIZE=$(stat -c %s "$ROOTFS_SQUASHFS")
  P5_FREE_KB=$(df -k "$BOOT_LAYER" | awk 'NR==2 {print $4}')
  (( SQ_SIZE / 1024 + 1024 < P5_FREE_KB )) || die "p5 引导层剩余空间不足（需 $(( SQ_SIZE / 1024 / 1024 )) MiB，剩 $(( P5_FREE_KB / 1024 )) MiB）"
  log "替换 $SQ_TARGET（新 $(( SQ_SIZE / 1024 / 1024 )) MiB；运行中系统仍使用旧 inode，安全）"
  cp -f "$ROOTFS_SQUASHFS" "$SQ_NEW"
  head -c 4 "$SQ_NEW" | grep -q 'hsqs' || die "写入后的 new 文件魔数异常，已中止（原系统未受影响）"
  rm -f "$SQ_BAK"
  mv -f "$SQ_TARGET" "$SQ_BAK"     # 旧版备份（回退：mv rootfs.squashfs.bak rootfs.squashfs）
  mv -f "$SQ_NEW" "$SQ_TARGET"     # 原子替换
  sync
  log "  [OK] SquashFS 已替换；旧版备份：$SQ_BAK（确认新版可用后可删除）"
  log "  [OK] overlay 数据（/etc /var /opt）未做任何改动，重启后保留"
else
  if [[ -n "$ROOTFS_IMG" ]]; then
    # 方式一：直接写入引导层 ext4 镜像
    log "写入 p5（$P5_DEV）：引导层 ext4 镜像（$(stat -c %s "$ROOTFS_IMG") 字节）"
    dd if="$ROOTFS_IMG" of="$P5_DEV" bs=1M conv=fsync status=progress
  else
    # 方式二：格式化后解压 tar.zst
    log "格式化 p5（$P5_DEV）：mkfs.ext4（不修改 GPT，PARTLABEL=rootfs 保留）"
    mkfs.ext4 -q -F -L rootfs "$P5_DEV"
    log "挂载并解压 rootfs tar.zst → $P5_DEV"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/h5000m-emmc.XXXXXX")"
    MNT_ROOT="$WORK/root"
    mkdir -p "$MNT_ROOT"
    cleanup() {
      umount "$MNT_ROOT" 2>/dev/null || true
      rm -rf "$WORK"
    }
    trap cleanup EXIT
    mount "$P5_DEV" "$MNT_ROOT"
    tar --numeric-owner --xattrs --acls -I zstd -xf "$ROOTFS_TAR" -C "$MNT_ROOT"
    sync
    umount "$MNT_ROOT"
    trap - EXIT
    rm -rf "$WORK"
  fi
fi

# ---------------------------------------------------------------- 6. 校验
log "校验 p4（回读 FIT 头）..."
dd if="$P4_DEV" bs=1 count=4 status=none 2>/dev/null | od -An -tx1 | grep -q 'd0 0d fe ed' \
  && log "  [OK] p4 FIT 魔数正确" \
  || log "  [WARN] p4 未检测到 FIT 魔数（0xd00dfeed），请确认 --kernel-fit 是合法的 FIT/ITB 镜像"

if [[ "$MODE_ONLINE" -eq 1 ]]; then
  log "校验 p5（在线模式：回读替换后的 SquashFS 魔数）..."
  head -c 4 "$SQ_TARGET" | grep -q 'hsqs' \
    && log "  [OK] 替换后的 rootfs.squashfs 魔数正确" \
    || log "  [WARN] 替换后文件魔数异常；如启动失败可用 $SQ_BAK 回退"
else
  log "校验 p5（e2fsck 快速检查）..."
  E2FSCK_OUT=$(e2fsck -fn "${P5_DEV}" 2>&1 || true)
  if echo "$E2FSCK_OUT" | grep -qE 'clean|PASSED|0 filesystems' 2>/dev/null; then
    log "  [OK] p5 ext4 文件系统检查通过"
  else
    log "  [WARN] p5 文件系统检查输出如下（仅供参考）："
    log "        $E2FSCK_OUT"
  fi
fi

sync
if [[ "$MODE_ONLINE" -eq 1 ]]; then
  log "完成。在线升级就绪：重启后引导层 init 将挂载新版 SquashFS（overlay 配置保留）。"
  log "回退方法（重启前执行）：mv $SQ_BAK $SQ_TARGET"
else
  log "完成。p4 / p5 已刷入 Debian 13，启动链（U-Boot / GPT / p1-p3 / eMMC 硬件配置）未做任何修改。"
  log "请重启设备，观察串口（115200n8）输出是否正常引导到 Debian。"
fi
