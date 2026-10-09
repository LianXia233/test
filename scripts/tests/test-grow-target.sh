#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 回归测试：p5 扩容目标必须恒为 4 GiB，且两处实现保持一致
#
# 为什么需要这个测试：
#   2026-10-09 依用户要求把「首启扩容扩满 p5（~7.24 GiB）」改为「扩容到 4 GiB」。
#   动机不是省空间，而是**减小这次最重的 eMMC 写入规模**：resize2fs 要为新增空间写
#   块位图 / inode 表 / 组描述符 / 备份超级块，写入量大致与新增容量成正比；而本机
#   正在排查「msdc 写挂死」（见 CHANGELOG 2026-10-09 两条目）。
#
#   目标值散落在**两处**实现里，任一处漏改就会造出行为不一致的固件：
#     · rootfs-overlay/usr/local/sbin/router-grow-rootfs  —— 首启兜底（在运行中的根上做）
#     · scripts/install-emmc.sh                           —— 刷写时离线扩容（推荐路径）
#   因此本测试断言：两处算出的目标**逐字节相同**，且都等于 4 GiB；
#   并且不允许退回「不带尺寸参数的裸 resize2fs」（那等于扩满分区）。
#
# 设计要点：与 test-parttable-parse.sh / test-boot-layer-space.sh 同思路 ——
#   测试**不复制**目标计算逻辑，而是从两个脚本里**抽取真实代码块**执行，
#   避免「测试与实现各改一份、测试绿而实现红」。
#
# 用法：bash scripts/tests/test-grow-target.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GROW_SH="$REPO_ROOT/rootfs-overlay/usr/local/sbin/router-grow-rootfs"
INSTALL_SH="$REPO_ROOT/scripts/install-emmc.sh"

for f in "$GROW_SH" "$INSTALL_SH"; do
  [[ -f "$f" ]] || { echo "找不到被测脚本：$f" >&2; exit 1; }
done

GIB=$((1024 * 1024 * 1024))
EXPECT_TARGET=$((4 * GIB))

# ---------------------------------------------------------------------------
# 抽取真实代码块
# ---------------------------------------------------------------------------
# 首启兜底：从 `GROW_TARGET_BYTES=...` 到 `NEED_BYTES=...`
GROW_BLOCK="$(awk '
  /^GROW_TARGET_BYTES=/ { on = 1 }
  on { print }
  on && /^NEED_BYTES=/ { exit }
' "$GROW_SH")"

# 刷写脚本：从缩进的 `GROW_TARGET_BYTES=...` 到同行 `P5_DEV_BYTES` 结束
INSTALL_BLOCK="$(awk '
  /^[[:space:]]*GROW_TARGET_BYTES=/ { on = 1 }
  on { print }
  on && /P5_DEV_BYTES$/ { exit }
' "$INSTALL_SH")"

if [[ -z "$GROW_BLOCK" ]]; then
  echo "无法从 $GROW_SH 抽取目标计算块（脚本被重构？请同步本测试）" >&2; exit 1
fi
if [[ -z "$INSTALL_BLOCK" ]]; then
  echo "无法从 $INSTALL_SH 抽取目标计算块（脚本被重构？请同步本测试）" >&2; exit 1
fi
for needle in GROW_TARGET_BYTES NEED_BYTES; do
  grep -q "$needle" <<<"$GROW_BLOCK" || {
    echo "首启块不含 $needle，抽取范围可能有误" >&2; exit 1; }
done
for needle in GROW_TARGET_BYTES P5_DEV_BYTES; do
  grep -q "$needle" <<<"$INSTALL_BLOCK" || {
    echo "刷写块不含 $needle，抽取范围可能有误" >&2; exit 1; }
done

PASS=0
FAIL=0
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
ok()   { printf '  [ok]   %s\n' "$*"; PASS=$((PASS + 1)); }
assert_eq() { # 期望 实际 描述
  if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3（期望 '$1'，实际 '$2'）"; fi
}

echo "期望目标：${EXPECT_TARGET} 字节（4 GiB）"
echo

# ===========================================================================
# 用例 1：p5 正常容量（~7.24 GiB）下，两处实现都得出 4 GiB
# ===========================================================================
echo "用例 1：p5 = 7.24 GiB（实际容量）→ 目标必须为 4 GiB"
P5_REAL=$(( (15268830 - 83968 + 1) * 512 ))   # 与真机分区表一致
DEV_BYTES="$P5_REAL"; FS_BYTES=0
eval "$GROW_BLOCK" || true
assert_eq "$EXPECT_TARGET" "$GROW_TARGET_BYTES" "首启兜底：目标 = 4 GiB（不是扩满 p5）"

P5_DEV_BYTES="$P5_REAL"
eval "$INSTALL_BLOCK" || true
assert_eq "$EXPECT_TARGET" "$GROW_TARGET_BYTES" "刷写离线：目标 = 4 GiB（不是扩满 p5）"

# ===========================================================================
# 用例 2：两处实现必须一致（防止只改一处 → 固件行为分叉）
# ===========================================================================
echo "用例 2：两处实现算出的目标必须逐字节相同"
DEV_BYTES="$P5_REAL"; FS_BYTES=0
eval "$GROW_BLOCK" || true; A="$GROW_TARGET_BYTES"
P5_DEV_BYTES="$P5_REAL"
eval "$INSTALL_BLOCK" || true; B="$GROW_TARGET_BYTES"
assert_eq "$A" "$B" "首启兜底与刷写离线的目标一致"

# ===========================================================================
# 用例 3：小分区保护 —— 目标不得超过设备容量（min 语义没被改死）
# ===========================================================================
echo "用例 3：p5 仅 2 GiB → 目标必须退化为 2 GiB（不得越界）"
TWO_GIB=$((2 * GIB))
DEV_BYTES="$TWO_GIB"; FS_BYTES=0
eval "$GROW_BLOCK" || true
assert_eq "$TWO_GIB" "$GROW_TARGET_BYTES" "首启兜底：min(4 GiB, 设备容量)"

P5_DEV_BYTES="$TWO_GIB"
eval "$INSTALL_BLOCK" || true
assert_eq "$TWO_GIB" "$GROW_TARGET_BYTES" "刷写离线：min(4 GiB, 设备容量)"

# ===========================================================================
# 用例 4：已达目标必须「不产生任何写入」的判据
#   NEED_BYTES < 1 个块组（128 MiB）视为已达目标 → 后续走 exit 0 分支
# ===========================================================================
echo "用例 4：已达目标时 NEED_BYTES 必须小于一个块组（触发跳过）"
GRP_BYTES=$((128 * 1024 * 1024))
DEV_BYTES="$P5_REAL"; FS_BYTES="$EXPECT_TARGET"
eval "$GROW_BLOCK" || true
if (( NEED_BYTES < GRP_BYTES )); then
  ok "文件系统已是 4 GiB → NEED=${NEED_BYTES}B < 块组 ${GRP_BYTES}B，跳过 resize2fs"
else
  fail "文件系统已是 4 GiB 却仍会扩容（NEED=${NEED_BYTES}B）"
fi

# 未达目标时必须真的要扩
DEV_BYTES="$P5_REAL"; FS_BYTES="$GIB"
eval "$GROW_BLOCK" || true
if (( NEED_BYTES >= GRP_BYTES )); then
  ok "文件系统仅 1 GiB → NEED=${NEED_BYTES}B ≥ 块组，确实会扩容"
else
  fail "未达目标却不扩容（NEED=${NEED_BYTES}B）"
fi

# ===========================================================================
# 用例 5：静态断言 —— 不得退回「不带尺寸参数的裸 resize2fs」
#   `resize2fs <dev>`（无第二个参数）= 扩满分区，正是本次要改掉的行为。
# ===========================================================================
echo "用例 5：resize2fs 调用必须带尺寸参数（禁止退回扩满分区）"
if grep -qE '^[^#]*resize2fs "\$DEV"[[:space:]]+"\$WANT_BLOCKS"' "$GROW_SH"; then
  ok "首启兜底：resize2fs \"\$DEV\" \"\$WANT_BLOCKS\"（按块数指定目标）"
else
  fail "首启兜底未按 WANT_BLOCKS 指定尺寸 —— 可能已退回扩满分区"
fi
if grep -qE '^[^#]*resize2fs "\$P5_DEV" 4G' "$INSTALL_SH"; then
  ok "刷写离线：resize2fs \"\$P5_DEV\" 4G"
else
  fail "刷写离线未显式指定 4G —— 可能已退回扩满分区"
fi

# 反向断言：源码里不得存在无尺寸参数的裸调用（注释行已排除）
BARE=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  BARE=$((BARE + 1))
  printf '  [FAIL] %s 仍存在裸 resize2fs 调用：%s\n' "$(basename "$line")" "$line" >&2
done < <(grep -hoE '^[^#]*resize2fs +"\$[A-Z_]+"[[:space:]]*$' "$GROW_SH" "$INSTALL_SH" 2>/dev/null || true)
if (( BARE == 0 )); then
  ok "两个脚本都不存在不带尺寸参数的裸 resize2fs"
else
  FAIL=$((FAIL + BARE))
fi

echo
echo "通过 $PASS 项，失败 $FAIL 项"
(( FAIL == 0 ))
