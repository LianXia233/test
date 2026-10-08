#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 多板 — 生成 U-Boot 启动脚本 boot.scr
#
# 将 boot/<board>/boot.cmd 编译为 boot.scr（U-Boot 脚本二进制），
# 兼容 ImmortalWrt / OpenWrt Filogic U-Boot（boot.scr 自动加载流程）。
#
# 用法：
#   bash build/make-boot.sh --board h5000m|ap3000m [--out 目录]
#
# 板级来源：boot/<board>/boot.cmd（各板 DTB 名 / 串口基址 / bootargs 不同）。
# 产物：out/boot/boot.scr + out/boot/boot.cmd（boot.cmd 为源文件副本，便于审计）。
#
# 平台：Linux / macOS / Windows（Git-Bash / WSL）。
# 依赖：mkimage（u-boot-tools）。
# 行尾：本文件为 LF。

set -Eeuo pipefail

# ---------------------------------------------------------------- 平台检测
case "$(uname -s)" in
  Linux)   BUILD_PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) BUILD_PLATFORM="windows" ;;
  Darwin)  BUILD_PLATFORM="macos" ;;
  *)       BUILD_PLATFORM="unknown" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- 板级加载
# shellcheck source=../boards/board-lib.sh
source "$PROJECT_ROOT/boards/board-lib.sh"

OUT_DIR="$PROJECT_ROOT/out/boot"
BOARD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

if [[ -z "$BOARD" ]]; then
  echo "[make-boot] ERROR: 必须用 --board 指定板级。可用：$(board_list | tr '\n' ' ')" >&2
  exit 1
fi
board_load "$BOARD" || exit 1

BOOT_CMD="$PROJECT_ROOT/boot/$BOARD/boot.cmd"
[[ -f "$BOOT_CMD" ]] || { echo "[make-boot] ERROR: 缺少板级 boot.cmd：$BOOT_CMD" >&2; exit 1; }
command -v mkimage >/dev/null 2>&1 || {
  echo "[make-boot] 缺少 mkimage。请安装 u-boot-tools："
  echo "            Linux (Debian/Ubuntu): sudo apt-get install u-boot-tools"
  echo "            macOS (Homebrew)     : brew install u-boot-tools"
  echo "            Windows (MSYS2)      : pacman -S mingw-w64-x86_64-uboot-tools"
  exit 1
}

mkdir -p "$OUT_DIR"
# mkimage 从扩展名推断输出格式：boot.scr 默认生成 script 二进制
mkimage -A arm64 -O linux -T script -C none -n "${BOARD_UPPER} Debian 13 boot" \
  -d "$BOOT_CMD" "$OUT_DIR/boot.scr" >/dev/null
cp -f "$BOOT_CMD" "$OUT_DIR/boot.cmd"

echo "[make-boot] 完成（板级：$BOARD / $BOARD_NAME）："
ls -lh "$OUT_DIR/boot.scr" "$OUT_DIR/boot.cmd"
