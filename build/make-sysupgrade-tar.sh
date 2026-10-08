#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 多板 OpenWrt sysupgrade-tar 单文件固件打包
#
# 产物 out/<BOARD_UPPER>-debian13-sysupgrade.bin 为 OpenWrt 标准 sysupgrade-tar 格式
#（与官方 sysupgrade.bin 同构，已对照参考镜像逐字节验证结构）：
#
#   sysupgrade-<board>/            ← board 取自 boards/<board>.board 的 BOARD_SYSUPGRADE_BOARD
#   ├── CONTROL   "BOARD=<board>\n"            ← 板名匹配校验（防刷错设备）
#   ├── kernel    FIT 镜像                      ← sysupgrade 自动 dd 到 p4 kernel
#   └── root      引导层 ext4 镜像              ← sysupgrade 自动 dd 到 p5 rootfs
#                 （引导层 = init + busybox + SquashFS 只读根 + OverlayFS 目录；
#                   首启自动组装 overlay 并扩满 p5 供持久化）
#
# 刷写（目标设备运行 OpenWrt/ImmortalWrt 时，一条命令完成 p4+p5 写入并重启）：
#   sysupgrade -n /tmp/H5000M-debian13-sysupgrade.bin
#
# 【内存约束】sysupgrade 会把整包上传到设备 /tmp（tmpfs，占用 RAM）。
# 包体必须控制在设备内存可容纳的范围（本仓库产出门槛 ≤600 MiB）：
# kernel FIT ~13 MiB + 引导层 ~150 MiB ≈ 165 MiB 级（SquashFS 方案）。
# 注意：sysupgrade 整包重写 p5 = 恢复出厂；升级保留配置用设备内在线升级：
#   sudo bash scripts/install-emmc.sh --rootfs-squashfs rootfs.squashfs --kernel-fit kernel.bin
#
# 用法：
#   bash build/make-sysupgrade-tar.sh --board h5000m|ap3000m \
#     [--kernel out/<BOARD_UPPER>-debian13-kernel.bin] \
#     [--root out/<BOARD_UPPER>-debian13-rootfs.bin] \
#     [--out out/<BOARD_UPPER>-debian13-sysupgrade.bin]
#
# --board 必填（板级决定了 CONTROL 里的 BOARD 值 —— 它正是 sysupgrade 的防刷错
# 设备校验位，猜错等于把固件送到错误机型上，因此不做任何自动推断）。
#
# 平台：无 root 需求（纯 tar 封装）。
# 行尾：本文件为 LF。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- 板级加载
# shellcheck source=../boards/board-lib.sh
source "$PROJECT_ROOT/boards/board-lib.sh"

BOARD_ID=""                       # 板级 ID（--board），必填
KERNEL_BIN=""                     # 缺省 = out/$BOARD_FIT_OUT
ROOT_IMG=""                       # 缺省 = out/$BOARD_ROOTFS_OUT
OUT_BIN=""                        # 缺省 = out/$BOARD_SYSUPGRADE_OUT
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel) KERNEL_BIN="$2"; shift 2 ;;
    --root)   ROOT_IMG="$2"; shift 2 ;;
    --board)  BOARD_ID="$2"; shift 2 ;;
    --out)    OUT_BIN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

log() { printf '[make-sysupgrade-tar] %s\n' "$*"; }
die() { printf '[make-sysupgrade-tar] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n "$BOARD_ID" ]] || die "必须用 --board 指定板级（可用：$(board_list | tr '\n' ' ')）。CONTROL 里的 BOARD 值由板级决定，不做推断。"
board_load "$BOARD_ID" || exit 1

# 板级决定默认路径与 CONTROL 值
: "${KERNEL_BIN:=$PROJECT_ROOT/out/$BOARD_FIT_OUT}"
: "${ROOT_IMG:=$PROJECT_ROOT/out/$BOARD_ROOTFS_OUT}"
: "${OUT_BIN:=$PROJECT_ROOT/out/$BOARD_SYSUPGRADE_OUT}"
# BOARD 变量在此之后改为"sysupgrade 板名"，与 board-lib 的 BOARD（板级 ID）区分：
# 下游全部使用 $SYSUP_BOARD，避免与 board-lib 的 BOARD 语义混淆。
SYSUP_BOARD="$BOARD_SYSUPGRADE_BOARD"

[[ -f "$KERNEL_BIN" ]] || die "缺少 FIT 内核：$KERNEL_BIN（先运行 build/make-sd-image.sh）"
[[ -f "$ROOT_IMG"   ]] || die "缺少 rootfs 镜像：$ROOT_IMG（先运行 build/make-sd-image.sh）"

OUT_BIN="$(mkdir -p "$(dirname "$OUT_BIN")" && cd "$(dirname "$OUT_BIN")" && pwd)/$(basename "$OUT_BIN")"

# 包体内存约束门槛（sysupgrade 上传至 /tmp tmpfs）：600 MiB
MAX_TOTAL=$((600 * 1024 * 1024))
KERNEL_SIZE=$(stat -c %s "$KERNEL_BIN")
ROOT_SIZE=$(stat -c %s "$ROOT_IMG")
TOTAL=$((KERNEL_SIZE + ROOT_SIZE + 16384))   # +16 KiB tar 元数据余量
log "板级：$BOARD_NAME（$BOARD_SOC）→ CONTROL BOARD=$SYSUP_BOARD"
log "成员：kernel ${KERNEL_SIZE} B + root ${ROOT_SIZE} B ≈ 总包 $((TOTAL / 1024 / 1024)) MiB"
(( TOTAL <= MAX_TOTAL )) || die "总包 $TOTAL B 超过 600 MiB 内存约束（sysupgrade 需整包进 /tmp tmpfs）。" \
  "请用 build/make-sd-image.sh 的瘦身模式（默认开启）压缩 rootfs，或减小 --rootfs-size。"

# FIT 魔数预检（避免把错误内核封进包）
dd if="$KERNEL_BIN" bs=1 count=4 status=none 2>/dev/null | od -An -tx1 | grep -q 'd0 0d fe ed' \
  || die "$KERNEL_BIN 不是 FIT 镜像（魔数 d0 0d fe ed 不匹配）"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/${BOARD_ID}-sysup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DIRNAME="sysupgrade-${SYSUP_BOARD}"
mkdir -p "${WORK}/${DIRNAME}"

printf 'BOARD=%s\n' "$SYSUP_BOARD" > "${WORK}/${DIRNAME}/CONTROL"
cp "$KERNEL_BIN" "${WORK}/${DIRNAME}/kernel"
cp "$ROOT_IMG"   "${WORK}/${DIRNAME}/root"

# --sort=name：成员物理顺序 CONTROL → kernel → root（与 OpenWrt 官方打包一致）；
# uid/gid 归零 + 固定 mtime：产物可复现；GNU tar 自动完成 512B 块对齐。
MTIME_ARGS=()
[[ -n "$SOURCE_DATE_EPOCH" ]] && MTIME_ARGS=(--mtime=@"$SOURCE_DATE_EPOCH")
rm -f "$OUT_BIN"
(cd "$WORK" && tar --sort=name --owner=0 --group=0 --numeric-owner \
    "${MTIME_ARGS[@]}" -cf "$OUT_BIN" "$DIRNAME")

# 产物自检：CONTROL 逐字节 + 成员大小
TAR_CONTROL="$(tar -xOf "$OUT_BIN" "${DIRNAME}/CONTROL")"
[[ "$TAR_CONTROL" == "BOARD=${SYSUP_BOARD}" ]] || die "CONTROL 内容异常：${TAR_CONTROL}"
TAR_KERNEL_SIZE=$(tar -tvf "$OUT_BIN" "${DIRNAME}/kernel" | awk '{print $3}')
TAR_ROOT_SIZE=$(tar -tvf "$OUT_BIN" "${DIRNAME}/root" | awk '{print $3}')
[[ "$TAR_KERNEL_SIZE" == "$KERNEL_SIZE" ]] || die "kernel 成员大小不符：${TAR_KERNEL_SIZE} != ${KERNEL_SIZE}"
[[ "$TAR_ROOT_SIZE" == "$ROOT_SIZE" ]] || die "root 成员大小不符：${TAR_ROOT_SIZE} != ${ROOT_SIZE}"

log "=========================================="
log "sysupgrade-tar 单文件固件生成完成：$OUT_BIN（$(stat -c %s "$OUT_BIN") 字节）"
log "刷写（目标设备 OpenWrt/ImmortalWrt）：sysupgrade -n -v /tmp/$(basename "$OUT_BIN")"
log "首启：引导层 init 组装 OverlayFS；${BOARD_ID}-grow-rootfs.service 自动 resize2fs 扩满 p5（~7.2 GiB 持久化层）"
