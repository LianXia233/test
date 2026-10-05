#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — LED 控制（参考官方 OpenWrt 固件方案）
#
# 官方固件行为（/etc/diag.sh + /lib/functions/leds.sh + DTS aliases）：
#   boot     阶段：led-boot（蓝色）timer 100ms/100ms 快闪
#   failsafe 阶段：led-failsafe（琥珀）50ms/50ms
#   upgrade  阶段：led-upgrade（琥珀）200ms/200ms
#   done     阶段：关闭 led-boot 并恢复默认 trigger（官方 DTS 未定义
#                 linux,default-trigger → 保持熄灭）
#
# LED 由 DTS gpio-leds 定义（与官方固件一致）：
#   led-3 = amber:wlan-2ghz（琥珀，2.4G WiFi 指示灯，GPIO3，active-low）
#   led-4 = blue:wlan-5ghz （蓝色，5G WiFi 指示灯，GPIO4，active-low）
#   aliases：led-boot=/leds/led-4、led-failsafe=/leds/led-3、led-upgrade=/leds/led-3
#
# 由 systemd 编排：
#   h5000m-led-boot.service（启动早期闪烁）→ h5000m-led.service（就绪后熄灯）
#
# 用法：
#   h5000m-led.sh boot|done|failsafe|upgrade
#   h5000m-led.sh on|off|blink <sysfs-led> [delay_on] [delay_off]
#
# 行尾：本文件为 LF。

set -u

LEDS_BASE="/sys/class/leds"
DT_BASE="/proc/device-tree"

log() { printf '[h5000m-led] %s\n' "$*"; }
warn() { printf '[h5000m-led] WARN: %s\n' "$*" >&2; }

# ---- 复刻官方 /lib/functions/leds.sh 的 DTS → sysfs LED 名解析 ----
# get_dt_led_path：读 /proc/device-tree/aliases/led-<role>，返回该 LED 节点完整路径
get_dt_led_path() {
	local node="$DT_BASE/aliases/led-$1"
	[ -f "$node" ] || return 1
	tr -d '\0' < "$node" | sed 's#^#/proc/device-tree#'
}

# 颜色枚举（dt-bindings/leds/common.h，与官方 leds.sh 一致）
color_name() {
	case "$1" in
		0) echo white ;; 1) echo red ;; 2) echo green ;; 3) echo blue ;;
		4) echo amber ;; 5) echo violet ;; 6) echo yellow ;; 7) echo ir ;;
		8) echo multicolor ;; 9) echo rgb ;; 10) echo purple ;;
		11) echo orange ;; 12) echo pink ;; 13) echo cyan ;; 14) echo lime ;;
	esac
}

# get_dt_led：按官方顺序取 LED 名称（label → chan-name → color:function → basename）
get_dt_led() {
	local ledpath="$1" func color idx name
	[ -r "$ledpath/label" ] && { tr -d '\0' < "$ledpath/label"; return; }
	[ -r "$ledpath/chan-name" ] && { tr -d '\0' < "$ledpath/chan-name"; return; }
	[ -r "$ledpath/function" ] && func="$(tr -d '\0' < "$ledpath/function")"
	if [ -r "$ledpath/color" ]; then
		# FDT 属性为大端 4 字节整数，逐字节拼接成 0xNNNNNNNN
		idx=$((0x$(od -An -tx1 -N4 "$ledpath/color" | tr -d ' \n')))
	fi
	if [ -z "$idx" ] && [ -z "$func" ]; then
		basename "$ledpath"
	elif [ -n "$idx" ]; then
		color="$(color_name "$idx")"
		echo "${color:+$color:}$func"
	else
		echo "$func"
	fi
}

# LED 缺失必须「静默成功」而非返回非 0 —— 见下方 led_set 说明。
# 典型场景：虚拟机 / 非 H5000M 硬件 / DTS 未导出 aliases，此时 /sys/class/leds
# 下没有对应条目，脚本应视为无可操作硬件直接成功，不能让 systemd 标记 failed。
led_set() { # sysfs名 属性 值（仅当属性存在时写入）
	# [重要] 原实现以 `[ -f ... ] && echo ...` 结尾：属性不存在时整个函数返回 1，
	# 逐层冒泡导致 systemd 判定 service failed（QEMU 已复现 h5000m-led-boot /
	# h5000m-led 双双 failed）。此处显式 return 0 切断冒泡。
	[ -n "$1" ] || return 0
	if [ -f "$LEDS_BASE/$1/$2" ]; then
		echo "$3" > "$LEDS_BASE/$1/$2" 2>/dev/null || true
	fi
	return 0
}

led_timer() { # sysfs名 delay_on delay_off —— 内核态持续闪烁，无需守护进程
	led_set "$1" trigger timer
	led_set "$1" delay_on "$2"
	led_set "$1" delay_off "$3"
}

led_on() {
	led_set "$1" trigger none
	led_set "$1" brightness 255
}

led_off() {
	led_set "$1" trigger none
	led_set "$1" brightness 0
}

# resolve_led：解析 role → sysfs LED 名；解析不到返回 1（调用方据此跳过并成功退出）
resolve_led() {
	local ledpath led
	ledpath="$(get_dt_led_path "$1" 2>/dev/null)" || return 1
	[ -n "$ledpath" ] || return 1
	led="$(get_dt_led "$ledpath" 2>/dev/null)" || return 1
	[ -n "$led" ] || return 1
	printf '%s' "$led"
}

# ---- 阶段动作（与官方 diag.sh 的 set_state 对应） ----
cmd_boot() {
	local led
	if led="$(resolve_led boot)"; then
		led_timer "$led" 100 100
	else
		log "跳过 boot LED：未解析到 led-boot（非 H5000M 硬件 / 虚拟化环境，属正常降级）"
	fi
	return 0
}

cmd_done() {
	local ledpath led trigger
	ledpath="$(get_dt_led_path boot)"
	led="$(get_dt_led "$ledpath")"
	[ -z "$led" ] && return 0
	led_off "$led"   # 官方 done：先关闭 led-boot
	# 再恢复 DTS 默认 trigger（官方 DTS 未定义 → 保持熄灭）
	trigger=""
	[ -r "$ledpath/linux,default-trigger" ] && \
		trigger="$(tr -d '\0' < "$ledpath/linux,default-trigger")"
	[ -n "$trigger" ] && led_set "$led" trigger "$trigger"
	return 0
}

cmd_failsafe() {
	local led
	if led="$(resolve_led failsafe)"; then
		led_timer "$led" 50 50
	else
		log "跳过 failsafe LED：未解析到 led-failsafe"
	fi
	return 0
}

cmd_upgrade() {
	local led
	if led="$(resolve_led upgrade)"; then
		led_timer "$led" 200 200
	else
		log "跳过 upgrade LED：未解析到 led-upgrade"
	fi
	return 0
}

cmd_on()    { led_on "${1:-}"; return 0; }
cmd_off()   { led_off "${1:-}"; return 0; }
cmd_blink() { led_timer "${1:-}" "${2:-500}" "${3:-500}"; return 0; }

usage() {
	sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	boot|done|failsafe|upgrade)
		"cmd_$1"
		;;
	on|off|blink)
		if [ -z "${2:-}" ]; then usage; exit 1; fi
		"cmd_$1" "$2" "${3:-}" "${4:-}"
		;;
	-h|--help)
		usage
		;;
	*)
		usage
		exit 1
		;;
esac

# LED 属于「尽力而为」的装饰性动作：即便某分支异常也不得让调用方（systemd）
# 判定服务失败。上面各 cmd_* 已各自 return 0，此处再兜一道显式 exit 0。
exit 0
