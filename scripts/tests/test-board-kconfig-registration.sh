#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 回归测试：板级内核源码层的「Kconfig + Kbuild 双注册」不变量。
#
# 【为什么需要这个测试 —— 2026-10-09 CI 实测事故】
# AP3000M 首次云编译在 46s 处失败，日志：
#   [WARN] CONFIG_AIRPI_GPIO_FAN 未启用（补丁未生效或符号名不匹配）
#   ERROR: 关键配置项缺失（见上方 WARN）。--strict 模式下终止构建
# 根因：首版只提供了 airpi-gpio-fan.c + Kbuild，并在 drivers/hwmon/Makefile
# 追加了 obj-$(CONFIG_AIRPI_GPIO_FAN) += airpi-gpio-fan/，但
# **drivers/hwmon/Kconfig 里没有 source 驱动目录的 Kconfig** ——
# 于是 CONFIG_AIRPI_GPIO_FAN 这个符号在内核配置树中根本不存在，
# `make olddefconfig` 把它当未知符号**静默丢弃**（Kconfig 不报未知符号错误）。
#
# 这是一个"编译期才会暴露、且失败信息指向错误方向（说'补丁未生效或符号名不匹配'，
# 实际是符号压根没定义）"的陷阱，必须用测试钉住三个不变量：
#   A. 驱动目录必须同时存在 Kbuild 与 Kconfig；
#   B. Kconfig 里必须真的定义 config AIRPI_GPIO_FAN；
#   C. build-kernel.sh 必须同时做 Makefile 与 Kconfig 两处注册，
#      且 Kconfig 注册是**幂等**的、插在 `endif # HWMON` 之前。
#
# 测试手法：不复制 build-kernel.sh 的逻辑，而是从**真实脚本**里抽取
# 注册代码块，喂给一个 mock 内核树，然后断言结果。这样脚本改动后测试
# 依然有效，不会出现"测试通过但线上脚本坏了"的假绿。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
BOARD="${1:-ap3000m}"
DRIVER_DIR="$REPO_ROOT/kernel/files-boards/$BOARD/drivers/hwmon/airpi-gpio-fan"
BUILD_KERNEL="$REPO_ROOT/build/build-kernel.sh"

PASS=0
FAIL=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "== 板级内核源码层 Kconfig/Kbuild 注册不变量（board=$BOARD）=="

# ---------------------------------------------------------------- A. 文件齐备
if [[ -f "$DRIVER_DIR/Kbuild" ]]; then
	ok "存在 Kbuild（Makefile 侧）"
else
	bad "缺 $DRIVER_DIR/Kbuild —— 驱动不会被编译"
fi

if [[ -f "$DRIVER_DIR/Kconfig" ]]; then
	ok "存在 Kconfig（符号定义侧）"
else
	bad "缺 $DRIVER_DIR/Kconfig —— CONFIG_AIRPI_GPIO_FAN 符号不存在，olddefconfig 会静默丢弃 =m（2026-10-09 事故）"
fi

if [[ -f "$DRIVER_DIR/airpi-gpio-fan.c" ]]; then
	ok "存在 airpi-gpio-fan.c"
else
	bad "缺驱动源码 airpi-gpio-fan.c"
fi

# ---------------------------------------------------------------- B. Kconfig 内容
if [[ -f "$DRIVER_DIR/Kconfig" ]]; then
	if grep -qE '^config[[:space:]]+AIRPI_GPIO_FAN$' "$DRIVER_DIR/Kconfig"; then
		ok "Kconfig 定义了 config AIRPI_GPIO_FAN"
	else
		bad "Kconfig 未定义 config AIRPI_GPIO_FAN（符号名必须与 Kbuild 的 obj-\$(CONFIG_...) 完全一致）"
	fi

	# 类型必须是 tristate（=m 才可用）；bool 会让 =m 退化成 =y
	if grep -A1 -E '^config[[:space:]]+AIRPI_GPIO_FAN$' "$DRIVER_DIR/Kconfig" | grep -q 'tristate'; then
		ok "类型为 tristate（支持 =m 模块化）"
	else
		bad "类型不是 tristate —— 无法用 =m 构建为模块"
	fi

	# 缩进规范：help 段必须 tab + 2 空格，否则 menuconfig 显示错乱
	if sed -n '/^\thelp/,/^$/p' "$DRIVER_DIR/Kconfig" | grep -qP '^\t  \S'; then
		ok "help 段缩进符合 tab + 2 空格约定"
	else
		bad "help 段缩进异常（Kconfig 要求 help 正文缩进比 help 多 2 空格）"
	fi

	# 不允许空格缩进（Kconfig 只认 tab）
	if grep -qP '^ +\S' "$DRIVER_DIR/Kconfig"; then
		bad "Kconfig 含空格缩进行（Kconfig 只识别 tab 缩进）"
	else
		ok "无空格缩进行（全部 tab）"
	fi

	# 【depends 符号可达性 —— 2026-10-09 第二次 CI 失败根因】
	# 任何 `depends on X && Y` 里的 X/Y 必须是**真实存在的 Kconfig 符号**。
	# 首版写了 `depends on GPIOLIB && HRTIMER`：HRTIMER 在内核里根本不是
	# Kconfig 符号（只有 HIGH_RES_TIMERS），于是恒为 n → config 永远不可见
	# → .config 的 =m 被 olddefconfig 静默丢弃，症状与"缺 Kconfig"完全相同。
	#
	# 这里无法访问内核源码树，因此采用**已知合法符号白名单** + **已知非法
	# 陷阱清单**双向校验：白名单外的符号触发 FAIL 并要求人工确认（保守），
	# 陷阱清单命中的直接 FAIL（这些是宏/内部名，绝不可能出现在 Kconfig）。
	dep_line="$(grep -E '^[[:space:]]+depends on ' "$DRIVER_DIR/Kconfig" || true)"
	if [[ -n "$dep_line" ]]; then
		# 抽出所有大写标识符（去掉 depends on 关键字）
		syms="$(printf '%s\n' "$dep_line" | sed 's/depends on//' | grep -oE '\b[A-Z][A-Z0-9_]*\b' | sort -u)"
		# 非 Kconfig 符号陷阱清单（宏 / 内部 API / 头文件名，恒不可能是 CONFIG_*）
		TRAPS="HRTIMER GPIO_LOOKUP_IDX_OF GPIOLIB_LEGACY HRTIMER_MODE_REL
		       IS_ENABLED LINUX_VERSION_CODE OF_GPIO HWMON_DEVICE_ATTR"
		trap_hit=""
		for s in $syms; do
			for t in $TRAPS; do
				[[ "$s" == "$t" ]] && trap_hit="$trap_hit $s"
			done
		done
		if [[ -n "$trap_hit" ]]; then
			bad "depends 引用了非 Kconfig 符号：$trap_hit —— 该符号恒为 n，config 将永远不可见（=m 被静默丢弃）"
		else
			ok "depends 未引用已知非 Kconfig 符号（检查项：$(printf '%s' "$syms" | tr '\n' ' '))"
		fi

		# 正向确认：每个 depends 符号必须能在注释里找到"为什么它是合法符号"的依据，
		# 或落在公认合法白名单内。白名单外的符号仅告警（不阻断），提示人工核对。
		KNOWN="GPIOLIB HWMON OF PWM THERMAL EXPERT HAS_IOMEM ACPI PCI PM
		       COMPILE_TEST ARCH_MEDIATEK REGULATOR"
		unknown=""
		for s in $syms; do
			found=0
			for k in $KNOWN; do
				[[ "$s" == "$k" ]] && found=1
			done
			[[ "$found" -eq 0 ]] && unknown="$unknown $s"
		done
		if [[ -n "$unknown" ]]; then
			bad "depends 含白名单外符号：$unknown —— 必须确认它在 Kconfig 树中真实存在（grep -r '^config <SYM>' --include=Kconfig）"
		else
			ok "depends 全部符号落在已知合法集内"
		fi
	fi
fi

# ---------------------------------------------------------------- C. build-kernel.sh 双注册
if [[ -f "$BUILD_KERNEL" ]]; then
	if grep -q 'HWMON_MAKEFILE' "$BUILD_KERNEL" && \
	   grep -q 'obj-\$(CONFIG_AIRPI_GPIO_FAN) += airpi-gpio-fan/' "$BUILD_KERNEL"; then
		ok "build-kernel.sh 注册 drivers/hwmon/Makefile"
	else
		bad "build-kernel.sh 未注册 drivers/hwmon/Makefile"
	fi

	if grep -q 'HWMON_KCONFIG' "$BUILD_KERNEL" && \
	   grep -q 'drivers/hwmon/airpi-gpio-fan/Kconfig' "$BUILD_KERNEL"; then
		ok "build-kernel.sh 注册 drivers/hwmon/Kconfig（source 驱动 Kconfig）"
	else
		bad "build-kernel.sh 未注册 drivers/hwmon/Kconfig —— 符号不会存在，=m 被静默丢弃"
	fi
else
	bad "找不到 build/build-kernel.sh"
fi

# ---------------------------------------------------------------- D. 实际执行注册（mock 内核树）
# 从真实脚本抽取 Kconfig 注册块（HWMON_KCONFIG 到其 if/fi 结束），在 mock 树上跑。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/drivers/hwmon"
cat > "$TMP/drivers/hwmon/Kconfig" <<'MOCKEOF'
menuconfig HWMON
	bool "Hardware Monitoring support"

source "drivers/hwmon/pmbus/Kconfig"

endif # HWMON
MOCKEOF
printf '# hwmon makefile\nobj-$(CONFIG_HWMON) += hwmon.o\n' > "$TMP/drivers/hwmon/Makefile"

# 抽取：从 `HWMON_KCONFIG="` 行开始，到 `grep -n 'airpi-gpio-fan' "$HWMON_KCONFIG"`
# 这一行（注册块的最后一条可观测语句）为止。
# 【锚点说明】不能用"第一个 fi"收尾——注册块内部本身含
#   `if [[ ! -f ... ]]; then die ...; fi`
# 这样的嵌套判空，会在第一个 fi 处被误截（首版即踩此坑，抽取到的块只剩判空，
# 执行"成功"但什么都没做，测试因此假绿为 10/13）。
awk '
	/^  HWMON_KCONFIG=/ { inb = 1 }
	inb { print }
	inb && /grep -n .airpi-gpio-fan. "\$HWMON_KCONFIG"/ { exit }
' "$BUILD_KERNEL" > "$TMP/reg-block.sh"

if [[ ! -s "$TMP/reg-block.sh" ]]; then
	bad "无法从 build-kernel.sh 抽取 Kconfig 注册块（脚本结构变动？请更新抽取锚点）"
else
	# mock 树里准备两处源码路径（脚本会 die/校验这两处文件）
mkdir -p "$TMP/drivers/hwmon/airpi-gpio-fan"
	cp "$DRIVER_DIR/Kbuild" "$TMP/drivers/hwmon/airpi-gpio-fan/Kbuild" 2>/dev/null || true
	cp "$DRIVER_DIR/Kconfig" "$TMP/drivers/hwmon/airpi-gpio-fan/Kconfig" 2>/dev/null || true

	# 提供脚本依赖的 die/log 函数与 KERNEL_SRC
	{
		printf 'KERNEL_SRC=%q\n' "$TMP"
		printf 'log() { :; }\n'
		printf 'die() { printf "DIE: %s\\n" "$*" >&2; exit 1; }\n'
		cat "$TMP/reg-block.sh"
	} > "$TMP/run.sh"

	if bash "$TMP/run.sh" > "$TMP/out.log" 2>&1; then
		ok "注册块在 mock 内核树上执行成功"

		if grep -q '^source "drivers/hwmon/airpi-gpio-fan/Kconfig"$' "$TMP/drivers/hwmon/Kconfig"; then
			ok "已向 drivers/hwmon/Kconfig 插入 source 行"
		else
			bad "未插入 source 行"
		fi

		# 位置：必须在 `endif # HWMON` 之前（否则不在 menuconfig HWMON 块内）
		src_ln="$(grep -n 'airpi-gpio-fan/Kconfig' "$TMP/drivers/hwmon/Kconfig" | head -1 | cut -d: -f1)"
		endif_ln="$(grep -n '^endif # HWMON$' "$TMP/drivers/hwmon/Kconfig" | head -1 | cut -d: -f1)"
		if [[ -n "$src_ln" && -n "$endif_ln" && "$src_ln" -lt "$endif_ln" ]]; then
			ok "source 位于 'endif # HWMON' 之前（落在 menuconfig HWMON 块内）"
		else
			bad "source 位置错误（src=$src_ln endif=$endif_ln）—— 应位于 endif # HWMON 之前"
		fi

		# 幂等：再跑一次不得出现第二行
		bash "$TMP/run.sh" > "$TMP/out2.log" 2>&1 || true
		cnt="$(grep -c 'airpi-gpio-fan/Kconfig' "$TMP/drivers/hwmon/Kconfig" || true)"
		if [[ "$cnt" -eq 1 ]]; then
			ok "注册幂等（重跑后仍只有 1 行 source）"
		else
			bad "注册非幂等（出现 $cnt 行 source）"
		fi
	else
		bad "注册块执行失败：$(head -3 "$TMP/out.log" | tr '\n' ' ')"
	fi
fi

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[[ "$FAIL" -eq 0 ]]
