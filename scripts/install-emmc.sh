#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 多板 Debian 13 刷入脚本（复用现有 OpenWrt 分区布局）
#
# 支持板卡见 boards/*.board（当前：h5000m=MT7987A、ap3000m=MT7981B）。
# 用 --board 选择板级；**GPT 布局校验值（p1~p5 的 label / 起始扇区 / p4 大小）
# 全部来自板级卡片**，与实机不符即拒绝刷写（fail-safe，绝不盲刷）。
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
#     sudo bash scripts/install-emmc.sh --board h5000m|ap3000m \
#       --kernel-fit out/<BOARD_UPPER>-debian13-kernel.bin \
#       --rootfs out/rootfs/debian13-arm64-rootfs.tar.zst [--dev /dev/mmcblk0] [--yes]
#     sudo bash scripts/install-emmc.sh --board h5000m|ap3000m \
#       --kernel-fit out/<BOARD_UPPER>-debian13-kernel.bin \
#       --rootfs-img out/<BOARD_UPPER>-debian13-rootfs.bin [--dev /dev/mmcblk0] [--yes] [--no-grow]
#     （--rootfs-img 路径默认在写盘后**离线扩容** p5 到分区实际大小，见下方"离线扩容"说明；
#       加 --no-grow 可跳过，改由首启 router-grow-rootfs.service 兜底。）
#   方式二：运行中在线升级（SquashFS + OverlayFS 架构；保留 /etc /var 等全部持久化数据）：
#     sudo bash scripts/install-emmc.sh --board h5000m|ap3000m \
#       --kernel-fit out/<BOARD_UPPER>-debian13-kernel.bin \
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

# ---------------------------------------------------------------- 板级加载
# shellcheck source=../boards/board-lib.sh
source "$PROJECT_ROOT/boards/board-lib.sh"

BOARD=""
DEVICE="/dev/mmcblk0"
KERNEL_FIT=""                 # p4 内容：FIT 镜像（.fit / .itb）
ROOTFS_TAR=""                 # p5 内容（全新刷写方式一）：rootfs tar.zst
ROOTFS_IMG=""                 # p5 内容（全新刷写方式二）：引导层/ext4 镜像
ROOTFS_SQUASHFS=""            # 在线升级模式：仅替换 p5 上的 SquashFS 文件（保留 overlay 数据）
BACKUP_FULL=""                # 可选：整盘备份文件
BACKUP_P45=""                 # 可选：p4+p5 内容备份文件
ASSUME_YES=0
NO_GROW=0                     # --no-grow：跳过写盘后的 p5 离线扩容（改由首启兜底）

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board)            BOARD="$2"; shift 2 ;;
    --dev)              DEVICE="$2"; shift 2 ;;
    --kernel-fit)       KERNEL_FIT="$2"; shift 2 ;;
    --rootfs)           ROOTFS_TAR="$2"; shift 2 ;;
    --rootfs-img)       ROOTFS_IMG="$2"; shift 2 ;;
    --rootfs-squashfs)  ROOTFS_SQUASHFS="$2"; shift 2 ;;
    --backup-full)      BACKUP_FULL="$2"; shift 2 ;;
    --backup-p45)       BACKUP_P45="$2"; shift 2 ;;
    --yes)              ASSUME_YES=1; shift ;;
    --no-grow)          NO_GROW=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- 板级解析
# --board 未给时从 --kernel-fit 的文件名反推（<BOARD_UPPER>-debian13-kernel.bin）。
# 刷写是破坏性操作，**推断失败一律拒绝**，绝不"猜一个板级继续跑"。
if [[ -z "$BOARD" && -n "$KERNEL_FIT" ]]; then
  kf_base="$(basename "$KERNEL_FIT")"
  for b in $(board_list); do
    board_load "$b" >/dev/null 2>&1 || continue
    if [[ "$kf_base" == "$BOARD_FIT_OUT" ]]; then BOARD="$b"; break; fi
  done
fi
[[ -n "$BOARD" ]] || {
  echo "[install-emmc] 必须用 --board 指定板级（可用：$(board_list | tr '\n' ' '))。" >&2
  echo "[install-emmc] 板级决定 GPT 布局校验值与 DTB 名，刷写属破坏性操作，不做推断。" >&2
  exit 1
}
board_load "$BOARD" || exit 1
# 恢复默认：若未显式传 --kernel-fit，用板级默认产物名
: "${KERNEL_FIT:=$PROJECT_ROOT/out/$BOARD_FIT_OUT}"

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

# 解析分区表为数组。
#
# 【2026-10-09 修复：原正则在该设备上 100% 解析失败，刷入通道会在写盘前直接中止】
# 原实现用一条正则要求 Size 列是纯整数：
#     ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+(.*)$
# 但 `sgdisk -p` 的 Size 列是**人类可读**值，含小数点与单位：
#     Number  Start (sector)    End (sector)  Size       Code  Name
#        4           22528           83967   30.0 MiB   8300  kernel
# 第 4 组 `[0-9]+` 后面要紧跟空白，在 `.` 处必然失配（回溯也无法成功）→ 每一行都 `continue`
# → N_PART=0 → 下方 die「分区数量不足 5（当前 0）」。即只要 Size 列带小数点，脚本就永远
# 无法进入写盘阶段（属 fail-safe，不会损坏设备，但文档承诺的刷入通道实际不可用）。
# 即便放宽正则也不应使用该列：它是显示值而非扇区数（原注释假设的 61440 与真实输出不符），
# 且第 5 组会把 Code 与 Name 一起吞掉（PART_LABEL 变成 "8300 kernel"），expect_part 仍会 die。
#
# 现改为与显示格式无关的做法：
#   * 只取 Number / Start / End 三个**纯数字**列；
#   * 扇区数一律由 `End - Start + 1` 推导（不再读 Size 列，因此 `sgdisk` 版本差异无影响）；
#   * 分区名取 Name 列起的全部内容（Name 允许含空格）。**Name 的起始列会漂移**：
#     Size 列是显示值时占两列（`30.0` + `MiB`），是纯扇区数时只占一列（`61440`），
#     因此不能用固定的 $7，而要按「第 5 列是否为容量单位」动态判定；取不到则 label 为空
#     → expect_part die，属 fail-safe。
N_PART=0
declare -A PART_NUM PART_LABEL PART_SIZE PART_START PART_END
while read -r num start end label; do
  [[ -n "$num" && -n "$start" && -n "$end" ]] || continue
  PART_NUM[$num]="$num"; PART_START[$num]="$start"; PART_END[$num]="$end"
  PART_SIZE[$num]=$(( end - start + 1 ))
  PART_LABEL[$num]="$label"
  if (( num > N_PART )); then N_PART=$num; fi
done < <(sgdisk -p "$DEVICE" 2>/dev/null | awk '
  # 表体行：前三个字段为纯数字，其后是 Size [单位] / Code / Name
  /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]/ {
    name_start = ($5 ~ /^(B|KB|KiB|MB|MiB|GB|GiB|TB|TiB|PB|PiB|EB|EiB|bytes|sectors)$/) ? 7 : 6;
    label = "";
    for (i = name_start; i <= NF; i++) label = (label == "") ? $i : label " " $i;
    printf "%s %s %s %s\n", $1, $2, $3, label;
  }')

if (( N_PART == 0 )); then
  die "无法从 'sgdisk -p $DEVICE' 解析出任何分区行。请人工确认分区表输出格式后再刷写。"
fi

# 校验 $BOARD_NAME 原厂 GPT 布局。只检查存在 p4/p5 不够安全：任何带 5 个分区的
# 磁盘都可能被误当成目标设备，后续 dd/mkfs 会造成不可逆数据破坏。
#
# 【多板化】p1~p3 是所有板卡共用的 u-boot-env/factory/fip 布局（ImmortalWrt Filogic
# 标准），p4/p5 的 label 与起始扇区取自板级卡片（BOARD_P4_LABEL / BOARD_P4_SECTORS_START /
# BOARD_P5_SECTORS_START）；p4 大小断言用 BOARD_P4_SIZE_MIB。换板卡只需改 .board 卡，
# 本脚本不含任何机型常量。
(( N_PART >= BOARD_PART_COUNT )) || \
  die "分区数量不足 $BOARD_PART_COUNT（当前 $N_PART）。拒绝在非 $BOARD_NAME 原厂布局上刷写。"
expect_part() {
  local num="$1" label="$2" start="$3" end="$4"
  [[ "${PART_LABEL[$num]:-}" == "$label" ]] || \
    die "p$num PARTLABEL 应为 '$label'，实际为 '${PART_LABEL[$num]:-（空）}'（板级 $BOARD）。拒绝刷写。"
  [[ "${PART_START[$num]:-}" == "$start" ]] || \
    die "p$num 起始扇区应为 $start，实际为 '${PART_START[$num]:-（空）}'（板级 $BOARD）。拒绝刷写。"
  if [[ -n "$end" && "${PART_END[$num]:-}" != "$end" ]]; then
    die "p$num 结束扇区应为 $end，实际为 '${PART_END[$num]:-（空）}'（板级 $BOARD）。拒绝刷写。"
  fi
}
# p1~p3：与板卡无关的共性布局（ImmortalWrt Filogic 标准），保持硬编码。
expect_part 1 "u-boot-env" 8192 10239
expect_part 2 "factory"   10240 14335
expect_part 3 "fip"       14336 22527
# p4/p5：板级布局
expect_part 4 "$BOARD_P4_LABEL" "$BOARD_P4_SECTORS_START" "$BOARD_P4_SECTORS_END"
expect_part 5 "${BOARD_P5_LABEL:-rootfs}" "$BOARD_P5_SECTORS_START" ""

# 校验关键分区大小符合预期（p4 = BOARD_P4_SIZE_MIB，p5 至少 1GiB）
P4_SIZE_BYTES=$(( ${PART_SIZE[4]:-0} * 512 ))
P5_SIZE_BYTES=$(( ${PART_SIZE[5]:-0} * 512 ))
(( P4_SIZE_BYTES == BOARD_P4_SIZE_MIB * 1024 * 1024 )) || \
  die "p4 大小不是预期的 ${BOARD_P4_SIZE_MIB} MiB（实际 $(( P4_SIZE_BYTES / 1024 / 1024 )) MiB）。拒绝刷写。"
(( P5_SIZE_BYTES >= 1024 * 1024 * 1024 )) || die "p5 小于 1 GiB（实际 $(( P5_SIZE_BYTES / 1024 / 1024 )) MiB）。拒绝刷写。"
log "板级：$BOARD / $BOARD_NAME（$BOARD_SOC）"
log "p4 $BOARD_P4_LABEL 分区大小：$(( P4_SIZE_BYTES / 1024 / 1024 )) MiB（START=${PART_START[4]} END=${PART_END[4]}）"
log "p5 ${BOARD_P5_LABEL:-rootfs} 分区大小：$(( P5_SIZE_BYTES / 1024 / 1024 )) MiB（START=${PART_START[5]} END=${PART_END[5]}）"

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
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/${BOARD}-emmc.XXXXXX")"
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

# ---------------------------------------------------------------- 5b. p5 离线扩容
# 【为什么必须在这里做】此刻 p5 **未挂载**：/overlay 与 loop(SquashFS) 都不存在，
# 是整条刷写链上唯一能安全做大范围 ext4 扩容的时刻；写坏了人还站在 shell 里，可重试。
#
# 背景（2026-10-09 实机串口实证）：此前扩容只在首启由 router-grow-rootfs.service
# 在**运行中的根文件系统**上执行 —— 那是这台设备上最重的一次 eMMC 写操作。在
# 该服务首次真正执行（CHANGELOG 2026-10-06 明确记录它此前从未被 enable）的固件上，
# 串口在 t≈10s 出现静默内核级冻结：CPU 0/1/3 的 softirq 计数冻结、CPU3 定时器停摆、
# `Sending NMI` 取不到任何 per-CPU 回栈，系统永远到不了 multi-user.target；
# 与本项目长期跟踪的「msdc 写挂死」特征一致。
# 把扩容前移到刷写时，正常刷写的设备就**完全不再需要**运行中的兜底扩容。
#
# 只读读取 ext4 容量（字节）；任何异常都返回空串——诊断信息不能把刷写流程带崩。
fs_bytes_readonly() {
  command -v dumpe2fs >/dev/null 2>&1 || return 0
  dumpe2fs -h "$1" 2>/dev/null | awk -F: '
    /^Block count/{gsub(/ /,"",$2);c=$2}
    /^Block size/ {gsub(/ /,"",$2);s=$2}
    END{if(c!=""&&s!="")print c*s}' || true
}

if [[ "$MODE_ONLINE" -eq 1 ]]; then
  log "p5 扩容：在线升级模式跳过（ext4 容量未变，仅替换 SquashFS 文件）"
elif [[ -z "$ROOTFS_IMG" ]]; then
  log "p5 扩容：mkfs.ext4 已按分区全尺寸创建文件系统，无需扩容"
elif (( NO_GROW == 1 )); then
  log "p5 扩容：已按 --no-grow 跳过。首启将由 router-grow-rootfs.service 兜底扩容"
  log "          （注意：该路径会在运行中的根文件系统上做全区 resize，本设备有 msdc 写挂死风险）"
else
  command -v resize2fs >/dev/null 2>&1 || \
    die "缺少 resize2fs（离线扩容 p5 需要）。请安装 e2fsprogs（sudo apt-get install e2fsprogs），或加 --no-grow 跳过。"
  # 离线扩容的硬前提：p5 绝不能处于挂载状态
  if findmnt -rn -S "$P5_DEV" >/dev/null 2>&1 || grep -qE "^${P5_DEV}[[:space:]]" /proc/mounts 2>/dev/null; then
    die "$P5_DEV 仍处于挂载状态，拒绝扩容（离线扩容必须在未挂载时进行）。请先 umount 后重试。"
  fi
  # dd 之后内核页缓存可能仍持有 p5 的旧扇区；先冲刷缓冲区，让 resize2fs 读到新超级块。
  if command -v blockdev >/dev/null 2>&1; then blockdev --flushbufs "$P5_DEV" 2>/dev/null || true; fi

  P5_DEV_BYTES=$(( ${PART_SIZE[5]:-0} * 512 ))
  FS_BYTES="$(fs_bytes_readonly "$P5_DEV" || true)"
  log "p5 离线扩容：resize2fs $P5_DEV（p5 未挂载）"
  if [[ -n "$FS_BYTES" ]]; then
    log "  扩容前：文件系统 ${FS_BYTES} 字节 / p5 分区 ${P5_DEV_BYTES} 字节"
  fi
  resize2fs "$P5_DEV" || die "p5 离线扩容失败（resize2fs 非 0 退出）。启动链未被改动，可安全重试。"

  FS_BYTES_AFTER="$(fs_bytes_readonly "$P5_DEV" || true)"
  if [[ -n "$FS_BYTES_AFTER" ]]; then
    # 允许不足一个块组（128 MiB）的零头：resize2fs 扩到最后可能填不满最后一个块组。
    if (( FS_BYTES_AFTER + 134217728 >= P5_DEV_BYTES )); then
      log "  [OK] p5 已扩满：文件系统 ${FS_BYTES_AFTER} 字节"
    else
      log "  [WARN] 扩容后文件系统为 ${FS_BYTES_AFTER} 字节，明显小于 p5（${P5_DEV_BYTES} 字节），请复核"
    fi
  fi
  sync
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
