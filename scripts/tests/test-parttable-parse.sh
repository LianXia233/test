#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 回归测试：scripts/install-emmc.sh 的 GPT 分区表解析
#
# 为什么需要这个测试：
#   2026-10-09 发现 install-emmc.sh 原解析正则要求 `sgdisk -p` 的 Size 列为**纯整数**
#   （`([0-9]+)` 后紧跟空白），但真实输出是**人类可读**值 `30.0 MiB`（含小数点）。
#   于是在小数点处必然失配 → 每行 continue → N_PART=0 → 脚本 die，刷入通道 100% 中止。
#   该 bug 不会被 CI 发现：现有质量门只跑 make-boot/make-squashfs/make-sd-image/
#   make-sysupgrade-tar，从不执行 install-emmc.sh（它需要真实块设备与 root 权限）。
#   本测试用**桩 sgdisk**喂入多种真实/边界格式，对解析块做无设备回归。
#
# 设计要点：
#   1) 测试**不复制**解析逻辑，而是从 install-emmc.sh 抽取真实代码块执行，
#      避免「测试与实现各改一份、测试绿而实现红」。
#   2) 被测块必须在**顶层** eval，且**不可用函数包装**：块内 `declare -A PART_*`
#      若在函数里执行会变成函数局部变量，函数一返回断言就看不到数据
#      （本测试首版正是这样假失败的）。放顶层则成为全局变量，且每次
#      重新 eval 会重新 `declare`，天然清空上一用例的状态。
#
# 用法：bash scripts/tests/test-parttable-parse.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../install-emmc.sh"

[[ -f "$TARGET" ]] || { echo "找不到被测脚本：$TARGET" >&2; exit 1; }

# 抽取解析块：从 `N_PART=0` 开始，到其后第一个独占一行的 `fi` 结束。
# （块内的 `if (( num > N_PART )); then ...; fi` 是单行写法，不会被 `^fi$` 误截。）
PARSE_BLOCK="$(awk '/^N_PART=0$/{f=1} f{print} f&&/^fi$/{exit}' "$TARGET")"
if [[ -z "$PARSE_BLOCK" ]]; then
  echo "无法从 $TARGET 抽取解析块（脚本被重构？请同步本测试）" >&2
  exit 1
fi
if ! grep -q 'N_PART == 0' <<<"$PARSE_BLOCK"; then
  echo "抽取到的解析块不含 N_PART==0 兜底判定，抽取范围可能有误" >&2
  exit 1
fi

PASS=0
FAIL=0
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
ok()   { printf '  [ok]   %s\n' "$*"; PASS=$((PASS + 1)); }
assert_eq() { # 期望 实际 描述
  if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3（期望 '$1'，实际 '$2'）"; fi
}

# ---- 桩：sgdisk 返回当前用例的 mock 输出；die 只记录不退出 -------------------
DEVICE="/dev/mmcblk0"
MOCK_OUTPUT=""
DIE_MSG=""
sgdisk() { printf '%s\n' "$MOCK_OUTPUT"; }
die() { DIE_MSG="$*"; return 1; }

# ===========================================================================
# 用例 1：真实 sgdisk 输出（Size 列为人类可读值 —— 即踩坑格式）
# ===========================================================================
read -r -d '' MOCK_HUMAN <<'EOF' || true
Disk /dev/mmcblk0: 30535680 sectors, 14.6 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 7D8C1E4B-0000-4000-8000-000000000000
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 30535646
Partitions will be aligned on 2048-sector boundaries
Total free space is 4399 sectors (2.1 MiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            8192           10239   1024.0 KiB  8300  u-boot-env
   2           10240           14335   2.0 MiB     8300  factory
   3           14336           22527   4.0 MiB     8300  fip
   4           22528           83967   30.0 MiB    8300  kernel
   5           83968        15268830   7.2 GiB     8300  rootfs
EOF

echo "用例 1：真实 sgdisk 输出（Size 列含小数点与单位）"
MOCK_OUTPUT="$MOCK_HUMAN"; DIE_MSG=""; N_PART=0
eval "$PARSE_BLOCK" || true
assert_eq 5 "${N_PART}" "解析出 5 个分区"
assert_eq "" "$DIE_MSG" "未触发 die"
assert_eq "u-boot-env" "${PART_LABEL[1]:-}" "p1 PARTLABEL"
assert_eq "8192" "${PART_START[1]:-}" "p1 起始扇区"
assert_eq "10239" "${PART_END[1]:-}" "p1 结束扇区"
assert_eq "kernel" "${PART_LABEL[4]:-}" "p4 PARTLABEL"
assert_eq "22528" "${PART_START[4]:-}" "p4 起始扇区"
assert_eq "83967" "${PART_END[4]:-}" "p4 结束扇区"
assert_eq 61440 "${PART_SIZE[4]:-0}" "p4 扇区数（End-Start+1 = 30 MiB）"
assert_eq "rootfs" "${PART_LABEL[5]:-}" "p5 PARTLABEL"
assert_eq 15184863 "${PART_SIZE[5]:-0}" "p5 扇区数（End-Start+1）"

# ===========================================================================
# 用例 2：Size 列为纯扇区数（旧注释假设的格式）。
# 新实现不读 Size 列，两种格式结果必须一致 —— 这是「与 sgdisk 版本无关」的保障。
# ===========================================================================
MOCK_SECTORS="$(sed -e 's/1024\.0 KiB/2048     /' -e 's/2\.0 MiB   /4096     /' \
                       -e 's/4\.0 MiB   /8192     /' -e 's/30\.0 MiB  /61440    /' \
                       -e 's/7\.2 GiB   /15184863 /' <<<"$MOCK_HUMAN")"

echo "用例 2：Size 列为纯扇区数（应与用例 1 结果一致）"
MOCK_OUTPUT="$MOCK_SECTORS"; DIE_MSG=""; N_PART=0
eval "$PARSE_BLOCK" || true
assert_eq 5 "${N_PART}" "解析出 5 个分区"
assert_eq "kernel" "${PART_LABEL[4]:-}" "p4 PARTLABEL"
assert_eq 61440 "${PART_SIZE[4]:-0}" "p4 扇区数"
assert_eq 15184863 "${PART_SIZE[5]:-0}" "p5 扇区数"

# ===========================================================================
# 用例 3：分区名含空格（原实现用 $NF，只会取到最后一个词）
# ===========================================================================
MOCK_SPACED="$(sed 's/  kernel$/  my kernel part/' <<<"$MOCK_HUMAN")"

echo "用例 3：分区名含空格（应按第 7 字段起完整拼接）"
MOCK_OUTPUT="$MOCK_SPACED"; DIE_MSG=""; N_PART=0
eval "$PARSE_BLOCK" || true
assert_eq "my kernel part" "${PART_LABEL[4]:-}" "含空格的分区名被完整取出"

# ===========================================================================
# 用例 4：无分区表 / 输出异常 → 必须 die（fail-safe，绝不放行写盘）
# ===========================================================================
echo "用例 4：sgdisk 输出无表体（非 H5000M 布局）"
MOCK_OUTPUT="Disk /dev/sda: 100 sectors, 50 KiB
First usable sector is 34, last usable sector is 66"; DIE_MSG=""; N_PART=0
eval "$PARSE_BLOCK" || true
assert_eq 0 "${N_PART}" "未解析出任何分区"
if [[ -n "$DIE_MSG" ]]; then ok "已 die 并中止（fail-safe）"; else fail "未 die —— 可能在未知布局上继续写盘"; fi

echo
echo "通过 $PASS 项，失败 $FAIL 项"
(( FAIL == 0 ))
