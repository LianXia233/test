#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 板级描述加载器（所有构建 / 刷写脚本共用）
#
# 用法（在被 source 的脚本里）：
#   source "$PROJECT_ROOT/boards/board-lib.sh"
#   board_load "$BOARD"          # 显式指定
#   board_load                   # 从 BOARD 环境变量或 --board 已设值取
#
# 提供的函数：
#   board_list              列出可用板级 ID（boards/*.board 的文件名）
#   board_exists <id>       板级是否存在（返回 0/1）
#   board_load <id>         source boards/<id>.board 并校验必填字段
#   board_require_fields    （内部）必填字段校验
#
# 【为什么用 .board 扩展名而不是 .conf/.env】
#   .board 明确表达"这是板级卡片"，与 kernel-conf/*.config（内核配置片段）区分开，
#   避免误当成内核配置被 cat >> .config。
#
# 行尾：本文件为 LF。

# 防止重复定义（多个脚本 source 时不报错）
[[ -n "${_BOARD_LIB_LOADED:-}" ]] && return 0
_BOARD_LIB_LOADED=1

# boards/ 目录（本文件所在目录）
BOARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

board_list() {
  local f
  for f in "$BOARDS_DIR"/*.board; do
    [[ -f "$f" ]] || continue
    basename "$f" .board
  done
}

board_exists() {
  [[ -n "${1:-}" && -f "$BOARDS_DIR/$1.board" ]]
}

board_require_fields() {
  local missing=() v
  for v in BOARD BOARD_NAME BOARD_UPPER BOARD_DTB BOARD_DTS BOARD_SOC_DTSI \
           BOARD_COMPATIBLE BOARD_SYSUPGRADE_BOARD BOARD_HOSTNAME \
           BOARD_KERNEL_CONFIG BOARD_SOC BOARD_UART_MMIO \
           BOARD_FIT_LOAD_ADDR BOARD_P4_SECTORS_START BOARD_P4_SIZE_MIB \
           BOARD_PART_COUNT BOARD_LAN_IFACE BOARD_WAN_IFACE \
           BOARD_WIFI_DRIVER BOARD_AP_2G_IFACE BOARD_AP_5G_IFACE; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    printf '[board-lib] ERROR: 板级 %s 缺少必填字段：%s\n' "${BOARD:-<未设置>}" "${missing[*]}" >&2
    return 1
  fi
  return 0
}

# board_load [board_id]
#   board_id 缺省时取已存在的 $BOARD（支持 --board 先解析、后加载的用法）
board_load() {
  local want="${1:-${BOARD:-}}"
  if [[ -z "$want" ]]; then
    printf '[board-lib] ERROR: 未指定板级。可用：%s\n' "$(board_list | tr '\n' ' ')" >&2
    return 1
  fi
  if ! board_exists "$want"; then
    printf '[board-lib] ERROR: 未知板级 "%s"。可用：%s\n' \
      "$want" "$(board_list | tr '\n' ' ')" >&2
    return 1
  fi
  # 先清掉旧值，避免连续 load 两个板卡时字段串味
  unset BOARD BOARD_NAME BOARD_UPPER BOARD_DTB BOARD_DTS BOARD_SOC_DTSI \
        BOARD_COMPATIBLE BOARD_SYSUPGRADE_BOARD BOARD_HOSTNAME \
        BOARD_KERNEL_CONFIG BOARD_SOC BOARD_CPU_CORES BOARD_UART_MMIO BOARD_PCI \
        BOARD_FIT_LOAD_ADDR BOARD_PART_COUNT \
        BOARD_P4_SECTORS_START BOARD_P4_SECTORS_END BOARD_P4_LABEL \
        BOARD_P5_SECTORS_START BOARD_P5_LABEL BOARD_P4_SIZE_MIB \
        BOARD_LAN_IFACE BOARD_WAN_IFACE BOARD_WAN_IFACE_5G \
        BOARD_WIFI_DRIVER BOARD_WIFI_FIRMWARE_DIR BOARD_WIFI_MODULES_LOAD \
        BOARD_AP_2G_IFACE BOARD_AP_5G_IFACE BOARD_AP_BAND_2G BOARD_AP_BAND_5G \
        BOARD_WIFI_PHY_DESC BOARD_FAN_HWMON_MATCH BOARD_FAN_PWM_CH \
        BOARD_EXTRA_FIRMWARE BOARD_BUILD_MT5700
  # shellcheck source=/dev/null
  source "$BOARDS_DIR/$want.board"
  BOARD="$want"
  board_require_fields || return 1
  # 派生量（board 文件不写死，避免改一处忘一处）
  BOARD_KERNEL_DIR_NAME="kernel"
  BOARD_FIT_OUT="${BOARD_UPPER}-debian13-kernel.bin"
  BOARD_ROOTFS_OUT="${BOARD_UPPER}-debian13-rootfs.bin"
  BOARD_SYSUPGRADE_OUT="${BOARD_UPPER}-debian13-sysupgrade.bin"
  BOARD_SQUASHFS_OUT="${BOARD_UPPER}-debian13-rootfs.squashfs"
  BOARD_DTB_FILE="${BOARD_DTB}.dtb"
  # bootargs 按 SoC 能力拼装（PCIe 是否存在决定 pci=pcie_bus_perf）
  local extra=""
  [[ "${BOARD_PCI:-0}" == "1" ]] && extra=" pci=pcie_bus_perf"
  BOARD_BOOTARGS="console=ttyS0,115200n8 earlycon=uart8250,mmio32,${BOARD_UART_MMIO} root=PARTLABEL=rootfs rootwait rw${extra}"
  export BOARD BOARD_NAME BOARD_UPPER BOARD_DTB BOARD_DTS BOARD_SOC_DTSI \
         BOARD_COMPATIBLE BOARD_SYSUPGRADE_BOARD BOARD_HOSTNAME \
         BOARD_KERNEL_CONFIG BOARD_SOC BOARD_CPU_CORES BOARD_UART_MMIO BOARD_PCI \
         BOARD_FIT_LOAD_ADDR BOARD_PART_COUNT \
         BOARD_P4_SECTORS_START BOARD_P4_SECTORS_END BOARD_P4_LABEL \
         BOARD_P5_SECTORS_START BOARD_P5_LABEL BOARD_P4_SIZE_MIB \
         BOARD_LAN_IFACE BOARD_WAN_IFACE BOARD_WAN_IFACE_5G \
         BOARD_WIFI_DRIVER BOARD_WIFI_FIRMWARE_DIR BOARD_WIFI_MODULES_LOAD \
         BOARD_AP_2G_IFACE BOARD_AP_5G_IFACE BOARD_AP_BAND_2G BOARD_AP_BAND_5G \
         BOARD_WIFI_PHY_DESC BOARD_FAN_HWMON_MATCH BOARD_FAN_PWM_CH \
         BOARD_EXTRA_FIRMWARE BOARD_BUILD_MT5700 \
         BOARD_KERNEL_DIR_NAME BOARD_FIT_OUT BOARD_ROOTFS_OUT \
         BOARD_SYSUPGRADE_OUT BOARD_SQUASHFS_OUT BOARD_DTB_FILE BOARD_BOOTARGS
  return 0
}
