#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 回归测试：build/make-sd-image.sh 的引导层空间预算（§3）
#
# 为什么需要这个测试：
#   2026-10-09 发现该脚本算镜像尺寸时只统计 (SquashFS + busybox)，把 /boot 下真正落盘的
#   引导文件笼统算进 BOOT_FS_OVERHEAD_MB=24。而 --keep-boot-image 要往 /boot 再放一份
#   解压态 Image（本平台约 60 MiB，见 CHANGELOG 2026-10-06「省 60+ MiB」）：
#     · 镜像尺寸不跟着涨 → mkfs.ext4 -d 直接 ENOSPC；
#     · 或侥幸建成，但 BOOT_FREE_MB 仍报 ~103 MiB（真话是 ~40 MiB）→ 空间断言变成谎话，
#       实机冷启动阶段 journal/NM state 写满 → errno 28 → 起不来。
#   本测试对**真实抽取的预算代码块**喂入确定尺寸的桩文件，断言：
#     (1) /boot 引导文件按真实字节计入 BOOT_FILE_BYTES；
#     (2) 打开 --keep-boot-image 后镜像尺寸同步增长，空闲量不被侵蚀；
#     (3) 即使在 --extra-mb 下限，空闲量仍 ≥ MIN_BOOT_FREE_MB（断言不说谎）；
#     (4) --extra-mb 低于下限时仍会 die（拦阻逻辑没被改死）。
#
# 设计要点：与 test-parttable-parse.sh 同思路 —— 测试**不复制**预算逻辑，而是从
#   make-sd-image.sh 抽取真实代码块执行，避免「测试与实现各改一份、测试绿而实现红」。
#
# 用法：bash scripts/tests/test-boot-layer-space.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../../build/make-sd-image.sh"

[[ -f "$TARGET" ]] || { echo "找不到被测脚本：$TARGET" >&2; exit 1; }

# 抽取预算块：从 `SQ_BYTES=$(stat -c %s "$SQUASHFS")` 到 `log "  预计引导层空闲` 行。
SPACE_BLOCK="$(awk '
  /^SQ_BYTES=\$\(stat -c %s "\$SQUASHFS"\)$/ { on = 1 }
  on { print }
  on && /^log "  预计引导层空闲/ { exit }
' "$TARGET")"
if [[ -z "$SPACE_BLOCK" ]]; then
  echo "无法从 $TARGET 抽取空间预算块（脚本被重构？请同步本测试）" >&2
  exit 1
fi
for needle in BOOT_FILE_BYTES IMG_SIZE_MB BOOT_FREE_MB MIN_BOOT_FREE_MB; do
  if ! grep -q "$needle" <<<"$SPACE_BLOCK"; then
    echo "抽取到的预算块不含 $needle，抽取范围可能有误" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
ok()   { printf '  [ok]   %s\n' "$*"; PASS=$((PASS + 1)); }
assert_eq() { # 期望 实际 描述
  if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3（期望 '$1'，实际 '$2'）"; fi
}
assert_ge() { # 实际 下限 描述
  if [[ "$1" -ge "$2" ]]; then ok "$3（$1 ≥ $2）"; else fail "$3（实际 $1 < $2）"; fi
}
assert_gt() { # 实际 下限 描述
  if [[ "$1" -gt "$2" ]]; then ok "$3（$1 > $2）"; else fail "$3（实际 $1 未 > $2）"; fi
}

# ---- 桩：确定尺寸的输入文件 ------------------------------------------------
# 归一化为 POSIX 路径：Git Bash 下 mktemp 返回 `C:\...\Temp/tmp.xxx`，
# 直接拿去 rm -rf 会被本机 safe-delete 钩子判为"内嵌盘符"而拒绝清理。
WORK="$(cd "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

truncate -s 120M "$WORK/rootfs.squashfs"        # SQ_BYTES  = 125829120
truncate -s  60M "$WORK/Image"                  # IMAGE_BYTES = 62914560
truncate -s 57344 "$WORK/h5000m.dtb"            # DTB      = 57344
mkdir -p "$WORK/boot"
truncate -s 1024 "$WORK/boot/boot.scr"          # boot.scr = 1024

SQUASHFS="$WORK/rootfs.squashfs"
IMAGE="$WORK/Image"
DTB="$WORK/h5000m.dtb"
BOOT_DIR="$WORK/boot"

# 从被测脚本抽取真实阈值常量（本测试是回归网，不是常量的第二份定义）
extract_const() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$TARGET" | head -1; }
MIN_EXTRA_MB="$(extract_const MIN_EXTRA_MB)"
MIN_BOOT_FREE_MB="$(extract_const MIN_BOOT_FREE_MB)"
BOOT_FS_OVERHEAD_MB="$(extract_const BOOT_FS_OVERHEAD_MB)"
for c in MIN_EXTRA_MB MIN_BOOT_FREE_MB BOOT_FS_OVERHEAD_MB; do
  if [[ -z "${!c}" ]]; then
    echo "无法从 $TARGET 抽取常量 $c（脚本被重构？请同步本测试）" >&2
    exit 1
  fi
done
echo "抽取常量：MIN_EXTRA_MB=$MIN_EXTRA_MB MIN_BOOT_FREE_MB=$MIN_BOOT_FREE_MB BOOT_FS_OVERHEAD_MB=$BOOT_FS_OVERHEAD_MB"
echo

# 固定但与本测试语义无关的输入
BB_SIZE=1975064
FORCE_EXTRA_MB=0
ROOTFS_IMG="/nonexistent/out.img"

# ---- 桩：log / die ---------------------------------------------------------
LAST_LOG=""
DIE_MSG=""
log()  { LAST_LOG="$*"; }
die()  { DIE_MSG="$*"; return 1; }

IMG_A=""; FREE_A=""
IMG_B=""; FREE_B=""

# ===========================================================================
# 用例 1：默认（不落 /boot/Image）—— 引导文件仅 DTB + boot.scr
# ===========================================================================
echo "用例 1：默认（KEEP_BOOT_IMAGE=0）"
KEEP_BOOT_IMAGE=0; EXTRA_MB=128; DIE_MSG=""
eval "$SPACE_BLOCK" || true
assert_eq "" "$DIE_MSG" "未触发 die"
assert_eq 58368 "$BOOT_FILE_BYTES" "BOOT_FILE_BYTES = DTB(57344) + boot.scr(1024)"
assert_eq 256 "$IMG_SIZE_MB" "镜像尺寸（8 MiB 对齐）"
assert_eq 110 "$BOOT_FREE_MB" "引导层预计空闲"
assert_eq "" "$DIE_MSG" "空闲充足，未 die"
IMG_A="$IMG_SIZE_MB"; FREE_A="$BOOT_FREE_MB"

# ===========================================================================
# 用例 2：--keep-boot-image —— /boot/Image 必须进预算
# ===========================================================================
echo "用例 2：--keep-boot-image（落 /boot/Image 60 MiB）"
KEEP_BOOT_IMAGE=1; EXTRA_MB=128; DIE_MSG=""
eval "$SPACE_BLOCK" || true
assert_eq "" "$DIE_MSG" "未触发 die"
assert_eq 62972928 "$BOOT_FILE_BYTES" "BOOT_FILE_BYTES 含 Image(62914560)+DTB+boot.scr"
assert_eq 312 "$IMG_SIZE_MB" "镜像尺寸随 Image 增长"
assert_eq 106 "$BOOT_FREE_MB" "引导层预计空闲未被侵蚀"
assert_gt "$IMG_SIZE_MB" "$IMG_A" "镜像尺寸比默认大（说明 Image 计入尺寸，而非游离在预算外）"
IMG_B="$IMG_SIZE_MB"; FREE_B="$BOOT_FREE_MB"

# ===========================================================================
# 用例 3：修 bug 前的行为对照 —— 空闲量不得因加 Image 而掉到门槛以下
#   （旧实现 IMG_SIZE 不涨，BOOT_FREE 仍报 110，但真实空闲只有 110-60=50 < 64）
# ===========================================================================
echo "用例 3：加 Image 后空闲量必须仍然 ≥ MIN_BOOT_FREE_MB（断言不说谎）"
assert_ge "$FREE_B" "$MIN_BOOT_FREE_MB" "用例 2 空闲量过门槛"
# 8 MiB 对齐会让空闲量抖动几个 MiB；关键是**不得侵蚀掉一整张 Image（60 MiB）**——
# 那正是旧实现的行为：尺寸不涨、BOOT_FREE 仍报 ~103，而真实空闲只剩 ~40（errno 28 起不来）。
ERODE=$(( FREE_A - FREE_B ))
assert_ge 8 "$ERODE" "加 Image 造成的空闲侵蚀 ≤ 8 MiB（仅 8 MiB 对齐抖动，非整张 Image）"

# ===========================================================================
# 用例 4：--extra-mb 取下限 + --keep-boot-image —— 仍须安全通过
# ===========================================================================
echo "用例 4：--extra-mb=${MIN_EXTRA_MB}（下限）+ --keep-boot-image"
KEEP_BOOT_IMAGE=1; EXTRA_MB="$MIN_EXTRA_MB"; DIE_MSG=""
eval "$SPACE_BLOCK" || true
assert_eq "" "$DIE_MSG" "下限 + keep-boot-image 仍不 die"
assert_ge "$BOOT_FREE_MB" "$MIN_BOOT_FREE_MB" "下限工况空闲量仍过门槛"

# ===========================================================================
# 用例 5：--extra-mb 低于下限 → 必须 die（拦阻逻辑没被改死）
# ===========================================================================
echo "用例 5：--extra-mb=1（低于下限）必须 die"
KEEP_BOOT_IMAGE=1; EXTRA_MB=1; DIE_MSG=""
eval "$SPACE_BLOCK" || true
if [[ -n "$DIE_MSG" ]]; then ok "已 die：${DIE_MSG:0:60}…"; else fail "未 die —— 空间断言形同虚设"; fi

echo
echo "通过 $PASS 项，失败 $FAIL 项"
(( FAIL == 0 ))
