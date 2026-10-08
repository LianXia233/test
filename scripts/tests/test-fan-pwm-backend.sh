#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 回归测试：router-fancontrol 的 PWM 后端选择（硬件 PWM / 软 PWM / pwmchip）
#
# 为什么需要这个测试：
#   AP3000M 存在两款硬件版本，风扇接法不同（依据官方
#   LianXia233/luci-app-airpi3000m-fancontrol）：
#     16GB eMMC → 主板未引出硬件 PWM，风扇挂 GPIO 540，airpi-gpio-fan 软 PWM
#                 只暴露 /sys/kernel/duty_cycle
#      8GB eMMC → 硬件 PWM，pwm-fan 驱动导出 hwmon pwm1
#   通用层 router-fancontrol 原实现只认 hwmon pwm1；若不引入后端分流，
#   16GB 版上 find_pwm() 永远失败 → 风扇完全不转，且日志只报「找不到节点」，
#   极易被误判为硬件故障。
#
#   本测试对**从真实脚本抽取的函数体**喂入 mock sysfs 布局，断言后端选择正确，
#   并覆盖三条容错路径（容量不可读 / 强制覆盖 / H5000M 钉死 hwmon）。
#
# 设计要点：与 test-parttable-parse.sh 同思路 —— 测试**不复制**判定逻辑，而是用
#   awk 从 router-fancontrol 抽取函数定义执行，避免「测试与实现各改一份」。
#
# 用法：bash scripts/tests/test-fan-pwm-backend.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../../rootfs-overlay/usr/local/sbin/router-fancontrol"

[[ -f "$TARGET" ]] || { echo "找不到被测脚本：$TARGET" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 按函数名抽取（含配对 {}），注释与嵌套块都不会误截断
extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { inb=1 }
    inb { print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m;
          if (started==0 && n>0) started=1;
          if (started && depth<=0) { inb=0; started=0; exit } }
  ' "$TARGET"
}

{
  echo '#!/bin/sh'
  extract_fn sysfs_read
  extract_fn is_uint
  extract_fn find_pwm_hwmon
  extract_fn find_pwm_chip
  extract_fn find_pwm_soft
  extract_fn resolve_pwm_backend
  extract_fn find_pwm
  # 覆盖绝对路径为 mock 目录（其余逻辑保持与真实脚本一致）
  cat <<'EOS'
MOCK="$1"
EMMC_SECTORS_FILE="$MOCK/mmcblk0_size"
SOFTPWM_NODE="$MOCK/duty_cycle"
find_pwm_hwmon() { for p in "$MOCK"/hwmon/hwmon*/pwm1; do [ -e "$p" ] && { echo "$p"; return 0; }; done; return 1; }
find_pwm_chip()  { for p in "$MOCK"/pwm/pwmchip*/pwm*/duty_cycle; do [ -e "$p" ] && { echo "$p"; return 0; }; done; return 1; }
find_pwm_soft()  { [ -e "$SOFTPWM_NODE" ] && { echo "$SOFTPWM_NODE"; return 0; }; return 1; }
echo "backend=$(resolve_pwm_backend "${PWM_BACKEND:-auto}")"
echo "path=$(find_pwm 2>/dev/null || echo none)"
EOS
} > "$TMP/probe.sh"
chmod +x "$TMP/probe.sh"

sh -n "$TMP/probe.sh" || { echo "抽取后语法错误：" >&2; cat "$TMP/probe.sh" >&2; exit 1; }

FAIL=0
CASES=0

run_case() {
  local name="$1" setup="$2" expect="$3" override="${4:-auto}"
  local M="$TMP/c"
  rm -rf "$M"; mkdir -p "$M"
  # shellcheck disable=SC2086  # setup 内部使用 $M，故意让调用方拼字符串
  eval "$setup"
  local out got
  out="$(PWM_BACKEND="$override" "$TMP/probe.sh" "$M" 2>&1)"
  got="$(printf '%s\n' "$out" | sed -n 's/^backend=//p')"
  CASES=$((CASES + 1))
  if [[ "$got" == "$expect" ]]; then
    echo "  [PASS] $name → $got"
  else
    echo "  [FAIL] $name → got='$got' want='$expect'"
    printf '%s\n' "$out" | sed 's/^/         /'
    FAIL=1
  fi
}

echo "== PWM 后端选择回归测试（抽自 router-fancontrol）=="
# 16GB eMMC（约 31.2 GiB / 61071360 扇区）应选软 PWM
run_case "16GB eMMC + duty_cycle"     'echo 61071360 > "$M/mmcblk0_size"; touch "$M/duty_cycle"' "softpwm"
# 8GB eMMC（约 7.3 GiB / 15269888 扇区）应选硬件 PWM
run_case "8GB eMMC + hwmon pwm1"      'echo 15269888 > "$M/mmcblk0_size"; mkdir -p "$M/hwmon/hwmon3"; touch "$M/hwmon/hwmon3/pwm1"' "hwmon"
run_case "8GB eMMC + 仅 pwmchip"      'echo 15269888 > "$M/mmcblk0_size"; mkdir -p "$M/pwm/pwmchip0/pwm2"; touch "$M/pwm/pwmchip0/pwm2/duty_cycle"' "pwmchip"
# 容量不可读时的回退
run_case "容量不可读 + hwmon"         'mkdir -p "$M/hwmon/hwmon0"; touch "$M/hwmon/hwmon0/pwm1"' "hwmon"
run_case "容量不可读 + 仅 duty_cycle" 'touch "$M/duty_cycle"' "softpwm"
run_case "容量不可读 + 全无"          'true' "none"
# 板级强制覆盖
run_case "16GB 但强制 hwmon"          'echo 61071360 > "$M/mmcblk0_size"; mkdir -p "$M/hwmon/hwmon1"; touch "$M/hwmon/hwmon1/pwm1"' "hwmon" "hwmon"
run_case "16GB 但强制 softpwm"        'echo 61071360 > "$M/mmcblk0_size"; touch "$M/duty_cycle"' "softpwm" "softpwm"
# H5000M：8GB 判据 + auto，仍应落到 hwmon（不受软 PWM 逻辑影响）
run_case "H5000M 8GB + auto"          'echo 15269888 > "$M/mmcblk0_size"; mkdir -p "$M/hwmon/hwmon9"; touch "$M/hwmon/hwmon9/pwm1"' "hwmon"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "PWM 后端选择测试通过（$CASES 例）"
else
  echo "PWM 后端选择测试未通过" >&2
  exit 1
fi
