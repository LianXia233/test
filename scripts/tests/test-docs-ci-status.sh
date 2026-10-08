#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 回归测试：文档中的「CI 实际状态」表述必须与单一真源 docs/ci-status.md 一致。
#
# 【为什么需要这个测试 —— 2026-10-09 实测事故】
# CI 状态结论此前散落在 README + 7 篇 docs + 2 个 workflow 注释里，一次 CI 结果变化
# 要改 10 处，必然漂移。实际就发生了：
#
#   AP3000M 的 run 37843516159（提交 c3f861d）里，**内核编译 job 早已成功**，
#   文档却仍写着「❌ 云编译失败 / 内核编译阶段连续失败两次」，并把该 run 标成
#   「（进行中）⏳ 待验证」—— 与真实 job 结论相反。
#
# 危险之处：这类过期表述会让读者对"当前到底能不能构建"产生错误判断 ——
# 反向的过期同样危险（把失败写成成功会诱导刷机）。
#
# 本测试把六条不变量前置到质量门（A–F 见下）。
#
# 【四轮负向验证换来的设计原则】
# 本脚本的守卫规则被负向验证反复打回过，每一轮都暴露了"看似正确实则漏检"的写法：
#
#   轮 1：把「同一行出现 run id 与 ✅」判为乐观表述 → 误伤 README 里
#         「内核 job 已 ✅ 通过」这条**正确**陈述。
#   轮 2：把「云编译成功 ≠ 实机可用」这句**安全警告**当成乐观表述 → 误伤警告本身。
#   轮 3：`实机可用[^性]` 连「云编译成功不等于实机可用」都匹配 → 再次误伤。
#   轮 4：乐观表述的「否定词过滤」按**整行**判定 → 表格行里右列写着
#         「实机未验证」，就把左列新注入的「✅ 实机已验证，已跑通」一起放行了。
#
# 结论（本脚本据此重构）：
#   - 判定窗口必须**锚定在匹配词周围**，不能拿到整行就下结论；
#   - 「安全警告」与「乐观断言」的区别在于**该匹配词本身**处于肯定还是否定结构中；
#   - 每个守卫都要有对应的负向验证，否则等于没写。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
STATUS="$REPO_ROOT/docs/ci-status.md"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "== 文档 CI 状态一致性（单一真源：docs/ci-status.md）=="

# ---------------------------------------------------------------- A. 真源存在 + 锚点
if [[ -f "$STATUS" ]]; then
	ok "docs/ci-status.md 存在"
else
	bad "缺 docs/ci-status.md —— 它是全部 CI 状态表述的单一真源，README/docs 都引用它"
	echo
	echo "通过 $PASS 项，失败 $FAIL 项"
	exit 1
fi

if grep -q '<a id="ci-status"></a>' "$STATUS"; then
	ok "docs/ci-status.md 含稳定锚点 <a id=\"ci-status\">"
else
	bad "docs/ci-status.md 缺稳定锚点 —— 其它文档无法可靠引用"
fi

if grep -q '实机验证' "$STATUS" && grep -q 'H5000M' "$STATUS" && grep -q 'AP3000M' "$STATUS"; then
	ok "docs/ci-status.md 含两板 × 「实机验证」维度状态表"
else
	bad "docs/ci-status.md 缺板卡状态表（需同时覆盖 H5000M / AP3000M 与「实机验证」列）"
fi

# ---------------------------------------------------------------- 收集受检文档
# 【范围说明】真源自身不参与 C/D/E 检查：它在 §4 标题里以「经 run X 内核 job 证实」
# 陈述事实，还定义了黑名单词表本身。
DOCS=("$REPO_ROOT/README.md")
while IFS= read -r f; do DOCS+=("$f"); done < <(find "$REPO_ROOT/docs" -maxdepth 1 -name '*.md' -print | sort)
while IFS= read -r f; do DOCS+=("$f"); done < <(find "$REPO_ROOT/.github/workflows" -name '*.yml' -print | sort)

PEER=()
for f in "${DOCS[@]}"; do
	[[ "$f" == "$STATUS" ]] && continue
	PEER+=("$f")
done

# ---------------------------------------------------------------- B. run id 必须见于真源
known_runs="$(grep -oE '\b3[0-9]{10}\b' "$STATUS" | sort -u)"
unknown_report=""
total_refs=0
for f in "${PEER[@]}"; do
	mapfile -t ids < <(grep -oE '\b3[0-9]{10}\b' "$f" | sort -u)
	for id in "${ids[@]:-}"; do
		[[ -z "$id" ]] && continue
		total_refs=$((total_refs + 1))
		if ! grep -qx "$id" <<<"$known_runs"; then
			unknown_report="$unknown_report\n      ${f#$REPO_ROOT/}: $id"
		fi
	done
done

if [[ -n "$unknown_report" ]]; then
	bad "以下 run id 未在 docs/ci-status.md 中登记（禁止凭空引用）:$(printf '%b' "$unknown_report")"
else
	ok "全部 $total_refs 处 run id 引用均已在 docs/ci-status.md 登记"
fi

if [[ -n "$known_runs" ]]; then
	ok "docs/ci-status.md 登记了 $(wc -l <<<"$known_runs") 个 run id"
else
	bad "docs/ci-status.md 未登记任何 run id —— 引用校验会退化为恒真（假绿）"
fi

# ---------------------------------------------------------------- C. scope 混淆（run 级）
# 【判定收紧的教训】首版规则是「该行含 ❌/失败 且不含通过语义」即违规，结果把
#     「AP3000M 云编译历史（三次失败，三个阶段各不相同…）
#       内核 job 证实，第三次修复待重跑复验）」
#   这样的**叙述句**误判为违规 —— 它既没断言整轮失败，也明确写了「内核 job 证实」。
# 真正要拦的是**把整轮 run 断言为失败**的句式，故改为匹配「断言词 + 失败/❌」的组合。
scope_bad=""
for f in "${PEER[@]}"; do
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# 仅命中「(云编译|整轮|run)\s*(失败|❌)」这类整轮结论断言
		if grep -qE '(云编译|整轮|整个)[^。]{0,8}(失败|❌)|(失败|❌)[^。]{0,4}(整轮|云编译)' <<<"$line"; then
			# 但若同句已说明是 job 维度或已修复，则放行
			grep -qE 'job|阶段|已修复|待重跑|复验|内核[^。]*✅' <<<"$line" && continue
			scope_bad="$scope_bad\n      ${f#$REPO_ROOT/}: $(cut -c1-120 <<<"$line")"
		fi
	done < <(grep -E '37843516159' "$f" 2>/dev/null)
done
if [[ -n "$scope_bad" ]]; then
	bad "存在 scope 混淆 / 事实错误（37843516159 内核 job 实际已 ✅）:$(printf '%b' "$scope_bad")"
else
	ok "无非限定地「37843516159 = 整轮失败」的 scope 混淆"
fi

# ---------------------------------------------------------------- C2. scope 混淆（板卡状态表行级）
# 【为什么必须做行级校验】结论最容易漂移的地方是板卡状态表，且那里通常不写 run id。
# 负向验证实测：把文档改回「AP3000M | ❌ 云编译失败」时，run 级守卫**完全放行**。
#
# 【判定必须精确到列 —— 第二版教训】首版规则是「AP3000M 行含 ❌ 即违规」，
# 但真实正确状态恰恰是「内核 ✅ 成功 | RootFS ❌ 失败」，该规则把**正确内容**判为违规。
# 故改为**按列切分**：状态表列序为
#     | 板卡 | 云编译（内核） | 云编译（RootFS+刷写包） | 实机验证 |
# 取第 2 个数据列（内核）判定 —— 只有内核列为 ❌ 才与真源矛盾。
table_bad=""
for f in "${PEER[@]}"; do
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		case "$line" in *'|'*) ;; *) continue ;; esac
		grep -qE 'AP3000M|H5000M' <<<"$line" || continue
		grep -qE '✅|❌|⏳|⚠' <<<"$line" || continue
		# 按 | 切列，去掉首尾空段
		IFS='|' read -r -a cols <<<"$line"
		# cols[1]=板卡, cols[2]=内核列, cols[3]=RootFS 列, cols[4]=实机列
		kernel_col="${cols[2]:-}"
		[[ -z "$kernel_col" ]] && continue
		if grep -q '❌' <<<"$kernel_col" && grep -qE 'AP3000M|H5000M' <<<"$kernel_col${cols[1]}"; then
			# 仅当该行确实是状态表行（板卡列含板名）时才判
			grep -qE 'AP3000M|H5000M' <<<"${cols[1]}" || continue
			table_bad="$table_bad\n      ${f#$REPO_ROOT/}: 内核列出现 ❌ —— $(cut -c1-130 <<<"$line")"
		fi
	done < <(grep -nE 'AP3000M|H5000M' "$f" 2>/dev/null)
done
if [[ -n "$table_bad" ]]; then
	bad "板卡状态表**内核列**与真源矛盾（真源：两板内核云编译均 ✅）:$(printf '%b' "$table_bad")"
else
	ok "板卡状态表内核列与 docs/ci-status.md 一致（RootFS 列允许 ❌）"
fi

# 真源自身必须体现「AP3000M 内核列 ✅」，否则上面那条守卫会被反转的真源蒙混过去
_ap_line="$(grep -E '^\| .*AP3000M' "$STATUS" | head -1)"
IFS='|' read -r -a _ap_cols <<<"$_ap_line"
if grep -q '✅' <<<"${_ap_cols[2]:-}"; then
	ok "真源确认 AP3000M 内核列为 ✅（与 run 37843516159 内核 job 结论吻合）"
else
	bad "真源 AP3000M 内核列非 ✅ —— 守卫基准错误，需先修正 docs/ci-status.md"
fi

# run 已推进到具体 job 时，不得再用笼统「待验证」描述该 run
if grep -rInE '待验证' "${PEER[@]}" 2>/dev/null | grep -E 'c3f861d|37843516159' >/dev/null 2>&1; then
	bad "仍把 c3f861d / 37843516159 写成笼统「待验证」—— 应写明「内核 job ✅ / RootFS job ⏳」"
else
	ok "c3f861d / 37843516159 的状态已按 job 维度写明（非笼统「待验证」）"
fi

if grep -q 'RootFS' "$STATUS"; then
	ok "docs/ci-status.md 已按 job 维度区分内核 / RootFS"
else
	bad "docs/ci-status.md 未按 job 维度区分（内核 vs RootFS）—— scope 会再次混淆"
fi

# ---------------------------------------------------------------- D. 乐观表述黑名单
# 【设计要点：匹配窗口锚定，不拿整行下结论】
# 只禁「把未验证说成已验证」的**肯定式**说法。判定分两步：
#   1. 对每个禁用词，取出「命中处前后 16 字符」的窗口；
#   2. 仅当**该窗口内**是否定结构（不 / 未 / ≠ / 请勿…）时才放行。
# 这样「左列写 ✅ 实机已验证，右列写 实机未验证」的表格行**不会**因为右列的
# 否定词而把左列的违规一起放行（轮 4 负向验证暴露的洞）。
OPTIMISTIC='已跑通|可作参考基线|实机已验证|实机已通过|生产可用'
hit=""
for f in "${PEER[@]}"; do
	while IFS= read -r raw; do
		[[ -z "$raw" ]] && continue
		ln="${raw%%:*}"
		line="${raw#*:}"
		# 规则说明行不算违规（那是规则本身在描述规则）
		grep -qE '乐观表述|黑名单|一律禁止|OPTIMISTIC' <<<"$line" && continue
		# 逐词定位，用锚定窗口判定否定结构
		for w in 已跑通 可作参考基线 实机已验证 实机已通过 生产可用; do
			grep -q "$w" <<<"$line" || continue
			# 以词为中心取 ±16 字符窗口（awk 无 lookaround，用前后的唯一标记替代）
			if awk -v w="$w" '{
				idx = index($0, w)
				while (idx > 0) {
					pre = (idx > 16) ? substr($0, idx-16, 16) : substr($0, 1, idx-1)
					post = substr($0, idx+length(w), 6)
					win = pre w post
					if (win ~ /不|未|≠|请勿|禁止|不得|尚未/) { idx = index(substr($0, idx+length(w)), w); if (idx>0) idx += length(w); continue }
					print "HIT"; exit
				}
			}' <<<"$line" | grep -q HIT; then
				hit="$hit\n      ${f#$REPO_ROOT/}:$ln: 「$w」缺否定语境 —— $(cut -c1-110 <<<"$line")"
			fi
		done
	done < <(grep -nE "$OPTIMISTIC" "$f" 2>/dev/null)
done
if [[ -n "$hit" ]]; then
	bad "存在肯定式乐观表述（本项目至今无任何板卡完成实机验收）:$(printf '%b' "$hit")"
else
	ok "无「已跑通 / 可作参考基线 / 实机已验证 / 生产可用」等肯定式乐观表述"
fi

# 「云编译成功 ≠ 实机可用」提醒必须保留
warn_ok=0
for f in "${PEER[@]}"; do
	grep -qE '云编译成功[^。]{0,12}[≠不]' "$f" && warn_ok=$((warn_ok + 1))
done
if [[ "$warn_ok" -ge 5 ]]; then
	ok "「云编译成功 ≠ 实机可用」提醒覆盖 $warn_ok 个文件"
else
	bad "「云编译成功 ≠ 实机可用」提醒仅覆盖 $warn_ok 个文件（应 ≥5：README + 各 docs）"
fi

# ---------------------------------------------------------------- E. 单体名残留
# 【范围收紧】只对**命令 / 路径 / 配置引用**语境判定；放行历史沿革说明
#（如「原 h5000m-fancontrol」）—— 否则测试会逼人删掉有用信息。
STALE='h5000m-router-init|h5000m-fancontrol|h5000m-grow-rootfs|h5000m-led|H5000M-AP[0-9*-]|H5000M-debian13'
stale_hit=""
for f in "${PEER[@]}"; do
	while IFS= read -r raw; do
		[[ -z "$raw" ]] && continue
		ln="${raw%%:*}"
		line="${raw#*:}"
		grep -qE '原 ?`?h5000m-|更名|原名|由 ?`?h5000m-' <<<"$line" && continue
		stale_hit="$stale_hit\n      ${f#$REPO_ROOT/}:$ln: $(cut -c1-110 <<<"$line")"
	done < <(grep -nE "$STALE" "$f" 2>/dev/null)
done
if [[ -n "$stale_hit" ]]; then
	bad "存在 H5000M 单体名残留（应为 router-* / ROUTER-AP-* / <BOARD_UPPER>）:$(printf '%b' "$stale_hit")"
else
	ok "无 H5000M 单体名残留（unit / profile / 产物名均已板级无关化）"
fi

# 反向确认：实际 unit 文件确实叫 router-*（防止"文档对了、代码没对"）
unit_bad=0
for u in router-init router-fancontrol router-grow-rootfs router-led-boot router-led; do
	[[ -f "$REPO_ROOT/rootfs-overlay/etc/systemd/system/$u.service" ]] || {
		bad "文档写 $u.service，但 rootfs-overlay 中无该 unit —— 文档与代码不一致"
		unit_bad=1
	}
done
[[ "$unit_bad" -eq 0 ]] && ok "文档引用的 5 个 router-*.service 与 rootfs-overlay 实际 unit 一一对应"

# ---------------------------------------------------------------- F. 真源引用闭环
if grep -q 'docs/ci-status.md' "$REPO_ROOT/README.md"; then
	ok "README.md 引用 docs/ci-status.md"
else
	bad "README.md 未引用 docs/ci-status.md —— 读者无法核对状态依据"
fi

ref_docs=0
for f in "$REPO_ROOT"/docs/*.md; do
	[[ "$f" == "$STATUS" ]] && continue
	grep -q 'ci-status.md' "$f" && ref_docs=$((ref_docs + 1))
done
if [[ "$ref_docs" -ge 5 ]]; then
	ok "$ref_docs 篇 docs 引用 ci-status.md"
else
	bad "仅 $ref_docs 篇 docs 引用 ci-status.md（应 ≥5）"
fi

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[[ "$FAIL" -eq 0 ]]
