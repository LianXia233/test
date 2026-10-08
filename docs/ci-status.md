# CI 实际状态（单一真源）

<a id="ci-status"></a>

> **本文档是仓库全部「云编译状态」表述的唯一依据。**
> README 与 `docs/*.md` 中凡出现 run id、提交号、成功/失败结论，都必须能在下表中
> 逐项对应。`scripts/tests/test-docs-ci-status.sh` 会在 CI 质量门强制校验这一点。
>
> **为什么要有这个文件**：状态结论此前散落在 10 个文件里，一次 CI 结果变化就要改
> 10 处，必然漂移 —— 上一轮出现过「AP3000M 云编译失败」在 run 已推进到内核编译成功
> 之后仍未更新；本轮又在文档写着「RootFS 进行中」期间实测到该 job 转为失败。
> 现在改为单一真源 + 机械校验。

## 1. 当前结论（2026-10-09）

| 板卡 | 云编译（内核） | 云编译（RootFS+刷写包） | **实机验证** |
| --- | --- | --- | --- |
| Hiveton H5000M (MT7987A) | ✅ 成功 | ✅ 成功 | ⚠️ **未验证** |
| Airpi AP3000M (MT7981B) | ✅ 成功 | ❌ **失败**（第 5 次：`封装 sysupgrade-tar` 步骤 `--board` 误传 sysupgrade 板名，已修复待复验） | ⚠️ **未验证** |

> ## ⚠️ 本项目至今没有任何一块板卡完成实机验收
>
> 「云编译成功」只证明**能构建出镜像**，不证明镜像能启动、网络能通、功能正常。
> 两块板卡的真实刷写 / 启动 / 联网验收**全部未做**。
>
> **两板产物均请勿刷机。**

## 2. Run 明细

| run id | 提交 | 事件 | 结果 | 关键 job 结论 |
| --- | --- | --- | --- | --- |
| [37853148758](https://github.com/LianXia233/test/actions/runs/37853148758) | `6ce92f8` | `workflow_dispatch`（AP3000M 薄壳） | ❌ failure | 质量门 ✅ / 内核 6.18 (ap3000m) ✅ / **RootFS + 刷写包 (ap3000m) ❌**（`封装 sysupgrade-tar 单文件固件` 步骤，`未知板级 "airpi_ap3000m"`） |
| [37851849934](https://github.com/LianXia233/test/actions/runs/37851849934) | `9e8f8f7` | `workflow_dispatch`（AP3000M 薄壳） | ❌ failure | 质量门 ✅ / 内核 6.18 (ap3000m) ✅ / **RootFS + 刷写包 (ap3000m) ❌**（`生成刷写包` 步骤，23 s，`BB: unbound variable`） |
| [37851638744](https://github.com/LianXia233/test/actions/runs/37851638744) | `76edd3a` | `workflow_dispatch`（AP3000M 薄壳） | ❌ failure | **未进入 job**：并发组死锁被取消（`deadlock ... between a top level workflow and 'build'`） |
| [37851376164](https://github.com/LianXia233/test/actions/runs/37851376164) | `3054c00` | `workflow_dispatch`（AP3000M 薄壳） | ❌ startup_failure | **未进入 job**：`cache-cleanup` 需 `actions: write`，壳的上限只给了 `contents` → 降为 `none` |
| [37843516159](https://github.com/LianXia233/test/actions/runs/37843516159) | `c3f861d` | `workflow_dispatch` | ❌ failure | 质量门 ✅ / 内核 6.18 (ap3000m) ✅ / **RootFS + 刷写包 (ap3000m) ❌**（`构建 Debian 13 RootFS` 步骤，1 min 46 s） |
| [37841719136](https://github.com/LianXia233/test/actions/runs/37841719136) | `e9c1594` | `workflow_dispatch` | ❌ failure | 质量门 ✅ / 内核 6.18 (ap3000m) ❌（`编译 Linux 内核` 步骤，44 s） |
| [37840375623](https://github.com/LianXia233/test/actions/runs/37840375623) | `a8e73ce` | `workflow_dispatch` | ❌ failure | 质量门 ✅ / 内核 6.18 (ap3000m) ❌（`编译 Linux 内核` 步骤，46 s） |
| [37825051627](https://github.com/LianXia233/test/actions/runs/37825051627) | `c21fc66` | `workflow_dispatch` | ✅ success | H5000M 全链路（多板化改造**之前**的最后一轮） |

> **scope 说明**：`37853148758`、`37851849934` 与 `37843516159` 都是**部分成功** ——
> 内核 job 通过、RootFS job 失败。
> 不要笼统写成「AP3000M 云编译失败」，那会掩盖「内核已能编过」这个关键进展；
> 也不要说「失败两次」，实际是**多次失败、每个阶段各不相同**（见 §4）。
>
> **进展链条**（每修一次，失败点就往下推一步，这是判断修复是否生效的唯一依据）：
> `37843516159` 挂在 `构建 RootFS` → `37851849934` 挂在 `生成刷写包` →
> `37853148758` 挂在 `封装 sysupgrade-tar`。前三步（`构建 RootFS`、`生成 SquashFS`、
> `生成刷写包`）在 `37853148758` 中**均已转绿**，证明第 3、4 次修复真实生效。
>
> 另外 `37851376164` / `37851638744` 是**薄壳 workflow 自身的缺陷**（根本没进 job），
> 与构建逻辑无关，单独归类见 §4.1。

## 3. 历史参照 Run（非当前状态依据）

以下 run 只用于说明**性能基线**或**已修复的历史事故**，不代表当前状态。
登记在此是为了让「文档里出现的每个 run id 都可追溯」这条不变量成立。

| run id | 提交 | 用途 |
| --- | --- | --- |
| [37353387707](https://github.com/LianXia233/test/actions/runs/37353387707) | `25bb2ad1` | **性能基线**：x86_64 runner 全链路实测（RootFS 67.7 min / 内核 46.7 min），见 `docs/build-guide.md` §3.7.1 |
| [37550743057](https://github.com/LianXia233/test/actions/runs/37550743057) | `42f93ec1` | H5000M 实机迁移阶段的一次失败 run（内核可诊断性修复前） |
| [37549966619](https://github.com/LianXia233/test/actions/runs/37549966619) | `b7df0e4b` | `clean-cache.yml` 权限事故（缺 `actions: write`，HTTP 403），修复记录见 `clean-cache.yml` 注释 |

## 4. 失败根因（按阶段分组）

**每一次症状都不同、根因都不一样** —— 这是本问题最难排查之处：每修完一次都必须
**重新实证**，不能假设"还是老原因"。截至当前共 **5 次构建阶段失败 + 2 次薄壳缺陷**。

| # | run | 失败阶段 | 根因 | 修复 |
| --- | --- | --- | --- | --- |
| 1 | 37840375623 | 内核编译（46 s） | 只有 `Kbuild` + `drivers/hwmon/Makefile` 注册，**缺 `drivers/hwmon/Kconfig` 注册** → 符号 `CONFIG_AIRPI_GPIO_FAN` 在内核配置树中不存在 → `.config` 的 `=m` 被 `olddefconfig` **静默丢弃** | 新增 `kernel/files-boards/ap3000m/drivers/hwmon/airpi-gpio-fan/Kconfig`；`build/build-kernel.sh` 在 `endif # HWMON` 之前幂等插入 `source`，并硬校验文件存在（缺失即 `die`） |
| 2 | 37841719136 | 内核编译（44 s） | 补了 Kconfig，但 `depends on GPIOLIB && HRTIMER` —— **`HRTIMER` 不是 Kconfig 符号**（内核里只有 `HIGH_RES_TIMERS`；hrtimer 是核心基础设施，无条件编入） → 依赖项恒为 `n` → 符号恒不可见 → `=m` **第二次被静默丢弃** | 改为 `depends on GPIOLIB`；Kconfig 内补入可复用规则注释；`scripts/tests/test-board-kconfig-registration.sh` 13 → 15 项，加入 `depends` 符号可达性双向校验 |
| 3 | 37843516159 | **RootFS 构建**（1 min 46 s） | **MT7981 固件「路径 + 清单」双错**：① 路径写成 `mediatek/mt7981/mt7981_*.bin`（子目录），而上游与内核均用**平铺** `mediatek/mt7981_*.bin` → 上游 **404**；② 清单漏了 `mt7981_wm.bin`（**主固件**，驱动加载必需） | 路径改平铺、清单补齐 3 件（`wa` / `wm` / `rom_patch`）、`dest` 改 `mediatek`；补入真实 sha256 白名单；`build/build-rootfs.sh` 的 `REQUIRED_FIRMWARE` 同步并写明「缺一不可」 |
| 4 | 37851849934 | **生成刷写包**（23 s） | **`build/make-sd-image.sh` heredoc 分隔符漏引号**：生成引导层 `/sbin/init` 用的是 `<<INIT_EOF`（未加引号），外层 shell 先做变量展开；而内嵌脚本含大量**外层不存在的自赋值变量**（`BB` / `SQ` / `MERGED` / `RETRY_FILE` / `N` / `_m`）→ `set -Eeuo pipefail` 下 407 行 `BB: unbound variable` 直接退出 | 分隔符改 `<<'INIT_EOF'`（内层变量一律字面保留）；板级值改 `@BOARD_NAME@` 等占位符，生成后显式替换 + **残留即 `die`** 兜底；新增 `scripts/tests/test-boot-init-heredoc.sh`（18 项） |
| 5 | 37853148758 | **封装 sysupgrade-tar**（27 s） | **`--board` 传错了值**：`build.yml` 把 `steps.board.outputs.sysupgrade_board`（**CONTROL 里的设备名** `airpi_ap3000m`）当成板级 ID 传给 `make-sysupgrade-tar.sh`，撞上 `board_load` 白名单 → `[board-lib] ERROR: 未知板级 "airpi_ap3000m"。可用：ap3000m h5000m` | `--board` 改传 `steps.board.outputs.id`（板级 ID `ap3000m`）；CONTROL 板名由脚本**自己**从板级文件的 `BOARD_SYSUPGRADE_BOARD` 读出，不需外部传入；`test-workflow-board-callchain.sh` 新增「全部 `--board` 必须传 `outputs.id`」守卫（26 项，经负向验证） |

**五次共同教训**：

- **第 1、2 次**：`Makefile` 只回答「怎么编」，`Kconfig` 才决定「符号是否存在、能否被选中」，
  两者必须同时提供。`olddefconfig` 对**未知符号不报错**，只静默丢弃。
- **第 3 次**：固件路径来自内核**字面常量**（`mt7915.h` 的 `MT7981_FIRMWARE_WA` 等），
  不是「按 SoC 建子目录」的直觉推论 —— 靠"看起来合理"猜路径必然翻车。
  且**清单可能同时不全**：修路径时若不回头核对内核头文件，仍会漏掉 `wm`（主固件）。
  正确做法是**逐个 HEAD 请求核实上游存在性**，而不是命名类推。
- **第 4 次**：`bash -n` / shellcheck **查不出**这类缺陷 —— 语法完全合法，只在**展开期**才炸。
  且它只在「走到生成刷写包这步」才暴露：内核 job 跑不到，H5000M 跑过但当时内嵌脚本里
  还没有 `BB` 这类变量（后来才加）。**"修一半"更危险**：只把 `BB` 挪到外层，后面
  `MERGED`/`N`/`RETRY_FILE` 会连环爆；若外层变量恰好为空则被**静默替换成空串**，
  生成一个能跑但行为错误的 init —— 实机表现为莫名启动失败，比直接报错难查得多。
- **第 5 次**：**同名不同义的值是最大的隐形陷阱**。本仓库有两个都叫「板名」的值：
  `id`（`ap3000m`，板级 ID，脚本参数用）与 `sysupgrade_board`（`airpi_ap3000m`，
  CONTROL 设备名）。两者在 `boards/ap3000m.board` 里紧挨着定义，读代码时极易混用。
  判定方法是**看消费方怎么用**：`board_load` 对 `--board` 做白名单校验 → 它要的必然是
  板级 ID；而 CONTROL 的 `BOARD=` 由脚本从板级文件自行读出 → 外部根本不该传。
  actionlint / YAML 校验**完全查不出**这类语义错，只有语义级守卫能拦。

### 4.1 薄壳 workflow 自身缺陷（未进入 job，与构建逻辑无关）

`build-h5000m.yml` / `build-ap3000m.yml` 是 `workflow_call` 薄壳（板卡写死、逻辑复用 `build.yml`）。
首次触发连续踩两个坑，**都不是构建问题**，但都让 run 在"还没开始跑"就结束：

| run | 症状 | 根因 | 修复 |
| --- | --- | --- | --- |
| 37851376164 | `startup_failure`，**job 数 0** | `workflow_call` 的权限取「调用方 ∩ 被调用方」，**调用方权限是所有被调用 job 的硬上限**。壳顶层只声明 `contents: read`，而基座 `cache-cleanup` 需 `actions: write` → 上限为 `none` → 校验阶段即拒 | 壳顶层放开 `actions: write` + `contents: write`（基座各 job 用到的**全部**权限）；`test-workflow-board-callchain.sh` 补 7b 项，遍历基座每个 job 的 permissions 逐一校验上限 |
| 37851638744 | 3 秒即结束，**job 数 0** | **并发组死锁**：壳 `group: ap3000m-build-${{ github.ref }}` 与基座 `${{ inputs.board }}-build-${{ github.ref }}` **求值完全相同** → 自我等待 | 删除壳的顶层 `concurrency`，**并发控制由基座统一持有**（基座 group 已含 `board`，两板天然隔离）；测试第 8 项改为「把基座模板代入壳的 board 值后做字符串相等比较」 |

> **为什么原来的守卫没拦住**：两处都是"看似覆盖、实则有洞"——
> 权限守卫只查了 `contents` 漏了 `actions`；并发守卫用"group 含板卡名即通过"，
> 而事故里的 group 恰好含板卡名，**完全放行**。两者均已重写并**经负向验证确认能拦住**。

**验证闭环**：

- `scripts/tests/test-board-kconfig-registration.sh` —— 把 `HRTIMER` 加回去，测试由
  「15 通过」降为「13 通过 2 失败」，确认能真正拦住该陷阱；
- `scripts/tests/test-boot-init-heredoc.sh` —— 把 heredoc 引号去掉还原事故写法，
  测试由「18 通过」降为「8 通过 10 失败」，且**复现出与线上完全相同的
  `BB: unbound variable`**；
- `test-workflow-board-callchain.sh` —— 两处守卫各自经负向验证（去掉 `actions: write` /
  还原死锁 group 写法），均能精确 FAIL；
- run 37843516159 的内核 job（`编译 Linux 内核（Image / DTB / modules）` 步骤）
  **已成功**，端点确认第 1、2 次修复；
- 第 3 次修复后**实跑 `fetch-firmware.py --board ap3000m`**：3/3 下载成功、
  sha256 与白名单逐项匹配（494256 / 2054688 / 9824 字节）；
- run 37851849934 的 `构建 Debian 13 RootFS` 与 `生成只读基础系统 SquashFS（zstd）`
  步骤**均 ✅ 通过** —— 端点确认第 3 次修复。
- 第 4 次修复后**隔离实跑生成逻辑**：生成成功、无占位符残留、内层自赋值保持字面量、
  板级值正确注入、权限 0755、生成物 `bash -n` 通过。**待下次 CI 复验。**

## 5. 待验证清单

- [ ] **重跑 AP3000M 云编译**：确认 `封装 sysupgrade-tar` 步骤转绿（第 5 次修复的效果验证）
- [ ] RootFS job 全绿（构建 RootFS 树 / SquashFS / 引导层镜像 / sysupgrade 包 / Release）
- [ ] `out/AP3000M-debian13-kernel.bin` 首 4 字节为 FIT 魔数且 < 30 MiB
  （注：run 37851849934 中该文件已生成，12389511 字节，FIT 魔数校验通过 —— **待下次 run 复现确认**）
- [ ] `out/AP3000M-debian13-sysupgrade.bin` 产出且 CONTROL 内 `BOARD=airpi_ap3000m`
  （**这是第 5 次修复的直接确认点**：CONTROL 值必须仍是 `airpi_ap3000m`，
  不能因为 `--board` 改传 `ap3000m` 就变成 `ap3000m` —— 后者会让设备侧 sysupgrade 拒绝刷写）
- [ ] `out/AP3000M-debian13-rootfs.bin` 通过 `e2fsck -fn`
- [ ] **实机**：真实 GPT 分区表（`sgdisk -p`）与 U-Boot `bdinfo` 的 `kernel_addr_r`
- [ ] **实机**：16GB 版 `modprobe airpi_gpio_fan` 后 `/sys/kernel/duty_cycle` 是否出现、
      `fangpio=540` 是否准确；8GB 版 `pwm1` 的实际 hwmon 序号
- [ ] **实机**：`/lib/firmware/mediatek/mt7981_{wa,wm,rom_patch}.bin` 就位后
      `mt7915e` 是否 probe 成功（**这是第 3 次修复的实机确认点**）
- [ ] **实机**：刷写后能否启动、LAN `192.168.88.1` 是否可达、Wi-Fi 是否 probe、风扇曲线、eMMC 首启扩容

H5000M 的实机复核清单（同样**全部未验证**）见 [../README.md](../README.md) 顶部警告块。

## 6. 维护约定

1. **任何 CI 结果变化，先改本文件**，再让引用方自然跟随；
2. 引用 run id 时**必须**使用本文表格中出现过的 id，不要凭空写「进行中」这类无据状态；
3. 若某条结论的理由是「单个 job 结论」而非「整轮 run 结论」，**必须标明 scope**
   —— 例如「内核 job ✅、RootFS job ❌」不等于「云编译失败」，也不等于「云编译成功」；
4. 乐观表述（`已跑通` / `可作参考基线` / `实机已验证`）一律禁止，由回归测试拦截；
5. 排查新失败时**不要假设沿用上次根因** —— 三次失败的三个阶段各不相同。
