#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 回归测试：build/make-sd-image.sh 生成引导层 /sbin/init 的 heredoc 契约
#
# 为什么需要这个测试：
#   2026-10-09 实机构建（run 37851849934，AP3000M）在「生成刷写包」步骤失败：
#       build/make-sd-image.sh: line 407: BB: unbound variable
#
#   根因不在那一行的内容，而在**heredoc 分隔符没加引号**。引导层 init 的内嵌脚本是
#   用 `cat > "$STAGE/sbin/init" <<INIT_EOF` 生成的。未加引号的分隔符会让外层 shell
#   先做一次变量展开，而内嵌脚本里存在**大量外层并不存在的自赋值变量**
#   （BB / SQ / MERGED / RETRY_FILE / N / _m）。脚本开头是 `set -Eeuo pipefail`，
#   于是第一个 $BB 就当场 unbound variable 退出。
#
#   这个缺陷能潜伏很久，是因为它只在「走到生成刷写包这步」才暴露：
#     · 内核 job 跑不到这里；
#     · H5000M 曾经跑过这条路径，但当时内嵌脚本里还没有 BB 这类变量（后来才加）；
#     · bash -n / shellcheck 都**查不出** —— 语法完全合法，只是语义在展开期才炸。
#
#   更危险的是"修一半"：只把 BB 定义挪到外层，后面的 MERGED/N/RETRY_FILE 会连环爆；
#   而若某个外层变量恰好为空（如未 load board），会被**静默替换成空串**，
#   生成一个能跑但行为错误的 init，实机表现为莫名启动失败 —— 比直接报错难查得多。
#
# 本测试据此钉住四条不变量：
#   A. heredoc 分隔符必须**带引号**（内层变量一律字面保留）
#   B. 内层不得再出现会被外层展开的裸 $VAR（除白名单），一律走 @PLACEHOLDER@
#   C. 每个 @PLACEHOLDER@ 都必须在替换列表里有对应项（且方向也要成立）
#   D. 端到端：真实抽取 heredoc + 替换块执行一遍，生成物可 bash -n、无占位符残留、
#      权限 0755，且内层自赋值变量保持字面量、板级值被正确注入
#
# 设计要点：与 test-boot-layer-space.sh 同思路 —— **不复制**实现，而是从
#   make-sd-image.sh 抽取真实 heredoc 与替换块执行，避免「测试与实现各改一份」。
#
# 用法：bash scripts/tests/test-boot-init-heredoc.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../../build/make-sd-image.sh"

[[ -f "$TARGET" ]] || { echo "找不到被测脚本：$TARGET" >&2; exit 1; }

PASS=0
FAIL=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

echo "== 引导层 init heredoc 契约（$(basename "$TARGET")）=="

# ---------------------------------------------------------------- 定位 heredoc
# 允许引号形式为 <<'INIT_EOF' / <<"INIT_EOF"（都表示不展开）；<<INIT_EOF 即违规。
HD_OPEN_LINE="$(grep -nE '^cat > "\$STAGE/sbin/init" <<' "$TARGET" | head -1 | cut -d: -f1 || true)"
if [[ -z "$HD_OPEN_LINE" ]]; then
  fail "找不到 'cat > \"\$STAGE/sbin/init\" <<...' 这一行（脚本被重构？请同步本测试）"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit 1
fi

OPEN_TEXT="$(sed -n "${HD_OPEN_LINE}p" "$TARGET")"

# ---- A. 分隔符必须带引号 ----
# 用 case 做字面匹配，避免 [[ =~ ]] 里转义引号/尖括号带来的歧义。
case "$OPEN_TEXT" in
  *"<<'INIT_EOF'"*|*'<<"INIT_EOF"'*)
    ok "A. heredoc 分隔符已加引号（内层变量不会在外层被展开）" ;;
  *)
    fail "A. heredoc 分隔符未加引号：$OPEN_TEXT
         → 外层 shell 会先展开内层变量；内层自赋值变量（BB/SQ/MERGED/...）在外层不存在，
           在 set -Eeuo pipefail 下会 'unbound variable' 直接退出（run 37851849934 症状）" ;;
esac

# ---- 定位 heredoc 结束行与替换块结束行（chmod） ----
HD_CLOSE_LINE="$(awk -v s="$HD_OPEN_LINE" 'NR>s && /^INIT_EOF$/ { print NR; exit }' "$TARGET")"
if [[ -z "$HD_CLOSE_LINE" ]]; then
  fail "找不到 heredoc 结束标记 INIT_EOF"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit 1
fi
CHMOD_LINE="$(awk -v s="$HD_CLOSE_LINE" 'NR>s && /^chmod 0755 "\$STAGE\/sbin\/init"$/ { print NR; exit }' "$TARGET")"
if [[ -z "$CHMOD_LINE" ]]; then
  fail "heredoc 之后找不到 chmod 0755 行（替换块可能被删）"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit 1
fi
ok "定位 heredoc 第 ${HD_OPEN_LINE}-${HD_CLOSE_LINE} 行，替换块止于第 ${CHMOD_LINE} 行"

# ---------------------------------------------------------------- 抽取内容
HD_BODY="$(sed -n "$((HD_OPEN_LINE + 1)),$((HD_CLOSE_LINE - 1))p" "$TARGET")"
REPL_BLOCK="$(sed -n "$((HD_CLOSE_LINE + 1)),${CHMOD_LINE}p" "$TARGET")"

# ---- B. 内层不得出现会被外层展开的裸 $VAR ----
# 内层脚本里合法出现的、**确实需要外层注入**的变量，在改造后应一律写成 @XXX@；
# 因此内层剩余的任何 $VAR/${VAR} 都应当是内层自己的局部变量。
# 这里用「白名单」而不是「黑名单」，因为新增注入值时黑名单会漏。
# 内层自赋值变量（合法）：BB SQ MERGED RETRY_FILE N _m / 以及位置参数类
LOCAL_VARS_ALLOWED='^(BB|SQ|MERGED|RETRY_FILE|N|_m)$'
# 内层会出现的特殊展开（$* / $@ / $? 等）不算
# 注意：GNU grep -E 不支持 (?<!\\) 这类 PCRE 前瞻/后顾，用 -oE '\$...' 再手工过滤转义。
RAW_REFS="$(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' <<<"$HD_BODY" \
              | sed -E 's/^\$\{?//' | sort -u || true)"
BAD_REFS=""
while IFS= read -r v; do
  [[ -z "$v" ]] && continue
  if ! [[ "$v" =~ $LOCAL_VARS_ALLOWED ]]; then
    BAD_REFS+="$v "
  fi
done <<<"$RAW_REFS"

if [[ -z "$BAD_REFS" ]]; then
  ok "B. 内层无越界裸变量（仅内层自赋值变量：$(tr '\n' ' ' <<<"$RAW_REFS" | sed 's/ $//')）"
else
  fail "B. 内层出现未白名单化的裸变量：$BAD_REFS
         → 这些变量会尝试在外层展开。若外层没有 → unbound variable 崩溃；
           若外层恰好有空值 → 被静默替换成空串（生成行为错误的 init，实机难查）。
           正确做法：改写成 @NAME@，并在替换列表补一项"
fi

# ---- C. 占位符与替换列表双向一致 ----
PLACEHOLDERS="$(grep -oE '@[A-Z_][A-Z0-9_]*@' <<<"$HD_BODY" | sort -u || true)"

# 替换列表的键：只取 for 循环 in 列表里的 "KEY:..." 字面项，
# 不要用宽松正则去抓整个替换块 —— 块里含 ${_k}/${_v} 等实现细节，会被误当成键
# （首版即因此把内层变量 BB 误报为"未引用的替换项"）。
REPL_LINE="$(grep -nE '^\s*for _p in ' "$TARGET" | head -1 | cut -d: -f1 || true)"
if [[ -n "$REPL_LINE" ]]; then
  # 取 for 语句起的连续行，直到 `do` 结束
  REPL_ITEMS="$(awk -v s="$REPL_LINE" 'NR>=s { print; if ($0 ~ /;[[:space:]]*do[[:space:]]*$/ || $0 ~ /^[[:space:]]*do[[:space:]]*$/) exit }' "$TARGET")"
  REPL_KEYS="$(grep -oE '"[A-Z_][A-Z0-9_]*:' <<<"$REPL_ITEMS" | tr -d '":' | sort -u || true)"
else
  REPL_KEYS=""
fi

if [[ -z "$PLACEHOLDERS" ]]; then
  fail "C. heredoc 内一个占位符都没有 —— 板级值（板名/SoC/大写名）将无法注入"
else
  ok "C1. heredoc 含占位符：$(tr '\n' ' ' <<<"$PLACEHOLDERS" | sed 's/ $//')"
fi

# C2. 每个占位符都必须有替换项（否则残留 @XXX@ → init 里带 @ 的坏值）
MISSING=""
for ph in $PLACEHOLDERS; do
  key="${ph//@/}"
  if ! grep -qE "\"${key}:" <<<"$REPL_BLOCK"; then
    MISSING+="$key "
  fi
done
if [[ -z "$MISSING" ]]; then
  ok "C2. 每个占位符均有对应替换项"
else
  fail "C2. 以下占位符在替换列表里找不到对应项：$MISSING → 会残留在生成的 init 中"
fi

# C3. 反之，替换列表里的项也应当真的在 heredoc 里被使用（防止改名后留下空跑项）
UNUSED=""
for key in $REPL_KEYS; do
  if ! grep -q "@${key}@" <<<"$HD_BODY"; then
    UNUSED+="$key "
  fi
done
if [[ -z "$UNUSED" ]]; then
  ok "C3. 替换列表无空跑项（每项都在 heredoc 中被引用）"
else
  fail "C3. 替换列表存在 heredoc 中未引用的项：$UNUSED → 多半是改名后忘删"
fi

# ---- C4. 必须有"占位符残留即失败"的兜底断言 ----
if grep -qE "grep -q '@\[A-Z_\]\[A-Z0-9_\]\*@'" <<<"$REPL_BLOCK" \
   || grep -q "未替换的占位符" <<<"$REPL_BLOCK"; then
  ok "C4. 替换块含「占位符残留即 die」的兜底断言"
else
  fail "C4. 替换块缺少占位符残留检查 —— 漏配的占位符会静默进入 init，实机表现为莫名启动失败"
fi

# ---------------------------------------------------------------- D. 端到端生成
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/sbin"

# 用固定值做桩，便于断言注入结果
{
  echo 'set -Eeuo pipefail'
  echo 'BOARD="ap3000m"'
  echo 'BOARD_NAME="Airpi AP3000M"'
  echo 'BOARD_SOC="MT7981B"'
  echo 'BOARD_UPPER="AP3000M"'
  echo "STAGE='$STAGE'"
  echo 'die() { echo "DIE: $*" >&2; exit 1; }'
  sed -n "${HD_OPEN_LINE},${CHMOD_LINE}p" "$TARGET"
} > "$WORK/gen.sh"

if bash "$WORK/gen.sh" >"$WORK/gen.out" 2>&1; then
  ok "D1. 生成流程执行成功（无 unbound variable）"
else
  fail "D1. 生成流程失败：$(tr '\n' ' ' <"$WORK/gen.out" | tail -c 300)"
fi

INIT="$STAGE/sbin/init"
if [[ -f "$INIT" ]]; then
  ok "D2. 已生成 $INIT"
else
  fail "D2. 未生成 init 文件"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit 1
fi

# D3. 无占位符残留
if grep -qE '@[A-Z_][A-Z0-9_]*@' "$INIT"; then
  fail "D3. 生成物仍有占位符残留：$(grep -oE '@[A-Z_][A-Z0-9_]*@' "$INIT" | sort -u | tr '\n' ' ')"
else
  ok "D3. 生成物无占位符残留"
fi

# D4. 内层自赋值变量保持字面量（这是整个修复的核心目的）
for probe in 'BB=/usr/bin/busybox' 'SQ=/squashfs/rootfs.squashfs' 'MERGED=/overlay/merged'; do
  if grep -qxF "$probe" "$INIT"; then
    ok "D4. 内层自赋值保持字面量：$probe"
  else
    fail "D4. 内层自赋值被破坏（期望整行 '$probe'）"
  fi
done

# D5. 板级值被正确注入
if grep -q '/dev/\.ap3000m_rescue_count' "$INIT"; then
  ok "D5. 板级值已注入（RETRY_FILE 含 ap3000m）"
else
  fail "D5. 板级值未注入（${BOARD:-board} 占位符没被替换？）"
fi
if grep -q 'BOARD_NAME@\|BOARD_SOC@\|BOARD_UPPER@' "$INIT"; then
  fail "D5b. 仍有板级占位符未替换"
else
  ok "D5b. 板级占位符全部替换完成"
fi

# D6. 生成物可被 bash 解析 + 权限正确
if bash -n "$INIT" 2>/dev/null; then
  ok "D6. 生成的 init 通过 bash -n"
else
  fail "D6. 生成的 init 语法错误"
fi
perm="$(stat -c '%a' "$INIT" 2>/dev/null || echo '?')"
if [[ "$perm" == "755" ]]; then
  ok "D7. 生成物权限 0755"
else
  fail "D7. 生成物权限异常：$perm（应为 755）"
fi

# ---- D8. 反向验证：把引号去掉应当导致 unbound variable（守卫真的有效） ----
SABOTAGE="$WORK/sabotage.sh"
{
  echo 'set -Eeuo pipefail'
  echo 'BOARD="ap3000m"'
  echo 'BOARD_NAME="Airpi AP3000M"'
  echo 'BOARD_SOC="MT7981B"'
  echo 'BOARD_UPPER="AP3000M"'
  echo "STAGE='$WORK/stage2'"
  echo 'die() { echo "DIE: $*" >&2; exit 1; }'
  # 故意去掉引号 = 事故写法
  sed -n "${HD_OPEN_LINE},${CHMOD_LINE}p" "$TARGET" \
    | sed "s/<<'INIT_EOF'/<<INIT_EOF/; s/@BOARD_NAME@/\${BOARD_NAME}/g; s/@BOARD_SOC@/\${BOARD_SOC}/g; s/@BOARD_UPPER@/\${BOARD_UPPER}/g; s/@BOARD@/\${BOARD}/g"
} > "$SABOTAGE"
mkdir -p "$WORK/stage2/sbin"
if bash "$SABOTAGE" >"$WORK/sab.out" 2>&1; then
  fail "D8. 反向验证失败：去掉引号后竟然还能生成 —— 说明本测试的 A 项判定可能失效"
else
  if grep -q 'unbound variable' "$WORK/sab.out"; then
    ok "D8. 反向验证：去掉 heredoc 引号确实触发 unbound variable（守卫有效）"
  else
    ok "D8. 反向验证：去掉引号后生成失败（$(head -c 120 "$WORK/sab.out" | tr '\n' ' ')）"
  fi
fi

printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
