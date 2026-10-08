#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 回归测试：板卡专用 workflow 与可复用工作流的调用链一致性。
#
# 【为什么需要】
# 板卡入口（build-h5000m.yml / build-ap3000m.yml）是**薄壳**，只做一件事：
# 以写死的 board 调用 build.yml（workflow_call）。这种结构有个隐蔽的失败模式：
#
#   workflow_call 的 inputs **不会**从 workflow_dispatch 继承，必须在
#   build.yml 里逐个重新声明。若壳传了一个 build.yml 未声明的参数，GitHub 会在
#   触发瞬间直接报 "Invalid input" 并失败 —— 而这只有真去点 Run workflow 才看得到，
#   本地语法检查（YAML 合法）完全测不出来。
#
# 同理还有三类只在触发时暴露的错误：
#   - 漏传 required input（build.yml 标 required: true 的项）
#   - 壳的 with 引用了壳自己没声明的 inputs.X（引用求值为空）
#   - 调用方未授予 contents: write，导致被调用方建 Release 被权限收窄而失败
#
# 本测试把上述不变量全部前置到 CI 质量门，四个问题一次拦住。
#
# 【YAML 解析陷阱】yaml.safe_load 依 YAML 1.1 会把裸 `on:` 解析为布尔 True，
# 故 Python 侧需要把 True 键映射回 'on'（GitHub 用 YAML 1.2，'on' 是普通字符串）。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WF_DIR="$REPO_ROOT/.github/workflows"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "== 板卡 workflow 调用链一致性 =="

if ! python3 -c "import yaml" 2>/dev/null; then
	echo "  [SKIP] PyYAML 不可用，跳过（CI 质量门已预装 pyyaml）"
	exit 0
fi

python3 - "$WF_DIR" <<'PY'
import re
import sys
from pathlib import Path

import yaml

wf_dir = Path(sys.argv[1])
PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    print(f"  [PASS] {msg}")
    PASS += 1


def bad(msg):
    global FAIL
    print(f"  [FAIL] {msg}")
    FAIL += 1


def load(path):
    """读取 workflow YAML，并把 YAML 1.1 误解析的 True 键还原为 'on'。"""
    d = yaml.safe_load(path.read_text())
    if not isinstance(d, dict):
        raise ValueError(f"{path.name} 顶层不是映射")
    for k in list(d.keys()):
        if k is True:
            d["on"] = d.pop(k)
    return d


base_path = wf_dir / "build.yml"
if not base_path.is_file():
    bad("缺少 .github/workflows/build.yml")
    print()
    print(f"通过 {PASS} 项，失败 {FAIL} 项")
    raise SystemExit(1)

base = load(base_path)

# ---------------------------------------------------------------- 基座: 双触发
on = base.get("on") or {}
if "workflow_dispatch" in on:
    ok("build.yml 保留 workflow_dispatch（多板合一入口）")
else:
    bad("build.yml 缺 workflow_dispatch")

if "workflow_call" in on:
    ok("build.yml 声明 workflow_call（供板卡薄壳调用）")
else:
    bad("build.yml 缺 workflow_call —— 薄壳无法调用")
    print()
    print(f"通过 {PASS} 项，失败 {FAIL} 项")
    raise SystemExit(1)

call_inputs = on["workflow_call"].get("inputs") or {}
call_names = set(call_inputs)
call_required = {k for k, v in call_inputs.items() if (v or {}).get("required")}
ok(f"workflow_call inputs: {sorted(call_names)}")

# 【关键不变量】workflow_call 必须覆盖 workflow_dispatch 的全部输入。
# 否则从薄壳进来时会缺项，job 理由 inputs.X 求值为空 → 行为静默劣化。
disp_inputs = set(((on.get("workflow_dispatch") or {}).get("inputs") or {}).keys())
missing_decl = disp_inputs - call_names
if missing_decl:
    bad(f"workflow_call 漏声明 dispatch 的输入: {sorted(missing_decl)} —— 薄壳调用时该值为空")
else:
    ok("workflow_call 覆盖 workflow_dispatch 的全部输入")

# ---------------------------------------------------------------- 基座: job 定义
jobs = base.get("jobs") or {}
caller_shells = []
for p in sorted(wf_dir.glob("build-*.yml")):
    d = load(p)
    j = (d.get("jobs") or {}).get("build") or {}
    if j.get("uses"):
        caller_shells.append((p, d, j))

if not caller_shells:
    bad("未找到任何板卡薄壳（build-<board>.yml 中用 uses 调用 build.yml）")
else:
    ok(f"发现 {len(caller_shells)} 个板卡薄壳: {[p.name for p, _, _ in caller_shells]}")

boards_seen = set()
for path, d, job in caller_shells:
    name = path.name
    uses = job.get("uses")
    with_ = job.get("with") or {}
    passed = set(with_.keys())
    print(f"--- {name}")

    # 1. 调用目标
    if uses == "./.github/workflows/build.yml" or uses == "./.github/workflows/build.yml@main":
        ok(f"{name}: uses 指向 build.yml")
    else:
        bad(f"{name}: uses={uses!r} 未指向 ./.github/workflows/build.yml")

    # 2. 传入项必须都被 workflow_call 声明（否则 Invalid input 直接失败）
    unknown = passed - call_names
    if unknown:
        bad(f"{name}: 传入未声明 input {sorted(unknown)} → 触发时报 Invalid input")
    else:
        ok(f"{name}: 传入项均已在 workflow_call 声明")

    # 3. required 必须全传
    miss = call_required - passed
    if miss:
        bad(f"{name}: 漏传 required input {sorted(miss)} → 触发即失败")
    else:
        ok(f"{name}: required input 已全部传入")

    # 4. board 必须钉死，且与文件名一致
    b = with_.get("board")
    expect = name[len("build-"):-len(".yml")]
    if b != expect:
        bad(f"{name}: board={b!r}，应与文件名一致（{expect!r}）—— 否则壳名与实构建板卡不符")
    elif not isinstance(b, str) or not b:
        bad(f"{name}: board 不是非空字符串")
    else:
        ok(f"{name}: board 钉死为 {b!r}")
        if b in boards_seen:
            bad(f"{name}: board {b!r} 与其他薄壳重复")
        boards_seen.add(b)

    # 5. board 值必须在 boards/<board>.board 真实存在
    if isinstance(b, str) and b:
        if (wf_dir.parent.parent / "boards" / f"{b}.board").is_file():
            ok(f"{name}: boards/{b}.board 存在")
        else:
            bad(f"{name}: boards/{b}.board 不存在 —— 板级解析会失败")

    # 6. 壳自己声明的 workflow_dispatch inputs，必须覆盖 with 里引用的 inputs.X
    shell_inputs = set(((d.get("on") or {}).get("workflow_dispatch") or {}).get("inputs") or {})
    refs = set(re.findall(r"\$\{\{\s*inputs\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}", str(with_)))
    bad_refs = refs - shell_inputs
    if bad_refs:
        bad(f"{name}: with 引用了壳未声明的 inputs {sorted(bad_refs)} → 求值为空")
    else:
        ok(f"{name}: with 引用的 inputs 均已声明 {sorted(refs) or '（无）'}")

    # 7. 调用方须给 contents: write，否则被调用方建 Release 被权限收窄
    perm = (job.get("permissions") or {}).get("contents")
    if perm == "write":
        ok(f"{name}: 调用方授予 contents: write（Release 需要）")
    else:
        bad(f"{name}: 调用方 contents={perm!r}，被调用方建 Release 会被收窄为只读而失败")

    # 8. 并发组须按板卡隔离（两板不应互相排队）
    grp = str((d.get("concurrency") or {}).get("group") or "")
    if b and b in grp:
        ok(f"{name}: 并发组含板卡维度（group={grp}）")
    else:
        bad(f"{name}: 并发组未含板卡维度（group={grp!r}）—— 两板会互相排队")

    # 9. skip_release 的透传不能丢（丢了会意外发布）
    if "skip_release" in passed:
        ok(f"{name}: 透传 skip_release")
    else:
        bad(f"{name}: 未透传 skip_release —— 用户在壳里勾选会被忽略")

print()
print(f"通过 {PASS} 项，失败 {FAIL} 项")
raise SystemExit(0 if FAIL == 0 else 1)
PY
rc=$?
[[ "$rc" -eq 0 ]] || exit 1
