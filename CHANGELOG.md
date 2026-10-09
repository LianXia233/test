# 更新文档 (Changelog)

本项目遵循用户规则：任何对仓库的推送/更新，必须同步更新本文档。

## [Unreleased]

### 2026-10-09 — H5000M 风扇控制避开 MT7996 温度读取阻塞

**现场日志**：`boot-20261009-083917.log` 中未再出现 eMMC 命令超时；但系统反复报告 CPU3 RCU stall。
约 77.9 秒时，`router-fancontrol` 在读取 MT7996 温度（`mt7996_thermal_temp_show`）时等待驱动 MCU
互斥锁，而 MT7996 初始化工作线程正等待 MCU 响应。日志没有 watchdog 调用栈，无法据此证明这条阻塞链
就是 CPU3 RCU stall 的根因。

- H5000M 将 `TEMP_SOURCE` 从 `max` 改为 `cpu`。
- 修正 `router-fancontrol` 的 CPU 模式：按传感器类型筛选后再读取温度节点，并跳过 5G 模组温度查询，
  避免仅仅不参与温度取最大值、却仍触发 Wi-Fi/PHY/5G 传感器读取的问题。
- **限制**：这针对日志中已观察到的风扇守护进程阻塞；CPU3 RCU stall 是否随之消失仍需实机复测，根因未完全确认。

### 2026-10-09 — H5000M eMMC 探测限定与故障归因修正

- `dts/mt7987a-hiveton-h5000m.dts`：为焊接式 eMMC 增加 `no-sd` 与 `no-sdio`，禁止内核
  在同一控制器上探测不存在的 SD / SDIO 设备。现场日志中的 CMD52、CMD5、CMD8、CMD55 均来自
  这些必然失败的探测；移除后，启动日志只保留真实 eMMC 协议流量。
- 修正串口日志解读：首个致命超时是 **CMD18 读取**（约 15.1 秒），不是扩容写入；
  `CMD6 0x03B34801` 写入的是 `EXT_CSD[179] PARTITION_CONFIG=0x48`，并非 `BKOPS_EN`。
  现有证据指向 eMMC 卡或 MSDC 控制器通讯失效，尚不能把根因限定在写路径。
- 保留 25 MHz 降频和 4 GiB 扩容上限。两项均可降低负载或增加时序余量，但现在明确作为规避手段，
  不再将其描述为已经证实的根因修复。

### 2026-10-09 — eMMC 降频 25MHz + 扩容目标限定 4 GiB（针对「msdc 写挂死」的两项规避）

**实机现场（第二轮串口录制 `boot-20261009-073542.log`，1510 行，COM3 115200 8N1）**：设备经 U-Boot
Web 界面（`POST /upload` 267.8 MiB + `/flashing.html`）刷写后启动，根以 **ext4 r/w 挂 p5**，
**t≈15.1s** 出现首个数据面 eMMC 命令超时，随后完整复现「msdc 写挂死」：

- **命令层**：`CMD18`(15.1s) → `CMD13` → `CMD12` → `CMD6`(23 次) → 连 `CMD0`/`CMD1` 复位也超时；
  `host->error=0x00000002`（mtk-sd 的 `REQ_CMD_TMO`）；`mmc0: cache flush error -110`、
  `mmc0: tried to HW reset card, got error -110`、**`mmcblk0: recovery failed!`**。
  首个超时是读取命令 `CMD18`。后续 CMD6 中，`0x03200101` → `EXT_CSD[32]=1`
  （**FLUSH_CACHE**），`0x03B34801` → `EXT_CSD[179]=0x48`（**PARTITION_CONFIG**，恢复用户
  数据分区选择）；后者不是 BKOPS，二者均发生在卡失去响应后的恢复流程中。
- **块层**：`kworker/1:1H`(PID 101, `Workqueue: mmc_complete mmc_blk_mq_complete_work`) 卡在
  `mmc_wait_for_req_done` 持锁不放 → `flush-179:0`（`Workqueue: writeback wb_workfn`）卡在
  `mmc_blk_rw_wait` → 脏页刷不出 → `ext4_journal_check_start: Detected aborted journal`(t=201s)
  → 写 superblock 失败 → **`Remounting filesystem read-only`**(t=263s)。
- **RCU**：`rcu: 3-...0 ... softirq=819/834`，该计数在多次 stall 报告间几乎不增长 → CPU3 软中断
  冻结 → 所有 `synchronize_rcu()` 调用者转 D 态（d-logind / 多个 kworker）→ systemd 卡在等
  d-logind 的 cgroup mutex（内核自报 `systemd:1 is blocked on a mutex likely owned by (d-logind):329`）。
- **规律对照**（上一轮 5 次启动）：**ext4 r/w 根 → 挂死（3/3）；squashfs readonly 根 → 存活（2/2）**。

**本次改动（两项规避，均单变量、可回退）**：

- **eMMC 降频 48MHz → 25MHz**（`dts/mt7987a-hiveton-h5000m.dts` 的 `&mmc0` `max-frequency`）：
  增大 CMD/DATA 线的采样时序余量。本轮**只改频率**、保留 `cap-mmc-highspeed`，把「频率」与
  「时序模式」两个变量隔离开做对照；若 25MHz 仍挂死，下一步再去掉 `cap-mmc-highspeed`
  退回 default speed。
  > **不要误判方向**：`mmc0` 只协商到 high speed（日志明确 `mmc0: new high speed MMC card`），
  > **从未进入 HS200/HS400**，故本次挂死不应归因于高速时序问题。
- **扩容目标限定 4 GiB**（`rootfs-overlay/usr/local/sbin/router-grow-rootfs` 与
  `scripts/install-emmc.sh` 离线扩容段）：不再扩满 p5（~7.24 GiB）。`resize2fs` 要为新增空间写
  块位图 / inode 表 / 组描述符 / 备份超级块，写入量大致与「新增容量」成正比；把这次最重的 eMMC
  写入从 ~7.24 GiB 压到 4 GiB，是当前最直接的降风险手段。目标取 `min(4 GiB, p5 容量)`；
  已达目标（允许不足一个块组 128 MiB 的零头）时**一次 eMMC 写都不产生**。
- **本改动经「多板化重基线」移植**：原实现基于多板化之前的 `h5000m-*` 命名结构（提交于
  `fix/msdc-write-hang-and-wifi` 分支）；本次落在已多板化的 `main` 上，故扩容兜底脚本路径为
  `rootfs-overlay/usr/local/sbin/router-grow-rootfs`、单元名 `router-grow-rootfs.service`，
  新增回归测试引用的路径同步为 `router-*`。**两项改动的语义与旧结构版本逐字一致**。
- **文档同步**：`docs/hardware.md`（新增 §1.2，记录降频依据、边界与不扩满的取舍）、
  `docs/architecture.md`、`docs/build-guide.md`、`docs/first-boot.md`、
  `docs/debian13-partition-plan.md`、`README.md`，以及 `build/make-sd-image.sh` /
  `build/make-squashfs.sh` / `build/make-sysupgrade-tar.sh` / `build/rootfs/chroot-finalize.sh`
  中涉及扩容尺寸的注释与 log 文案。
- **新增回归测试** `scripts/tests/test-grow-target.sh`：从两处实现**抽取真实代码块**执行
  （不复制逻辑），断言 p5 正常容量下目标恒为 4 GiB、小分区退化为设备容量、两处实现逐字节
  一致、已达目标时判据确实触发跳过，并**静态禁止**退回「不带尺寸参数的裸 `resize2fs`」
  （那等于扩满分区）。**10 项全通过**。

> **这两项是规避手段，不是根因修复**：改变的是 eMMC 的时序余量与写入规模，不改变卡内部
> cache 或分区配置行为。根因定位仍依赖内核侧可诊断性——`CONFIG_ARM64_PSEUDO_NMI` 等已在 config 中，
> 但**尚未进入实机镜像**（本轮实机仍报 `watchdog: NMI not fully supported` /
> `watchdog: Hard watchdog permanently disabled`），导致 CPU3 的调用栈无法 dump，
> 是本次诊断中唯一靠推理而非直证的环节。

### 2026-10-09 — ✅ AP3000M 云编译全链路首绿（run 37855852616）

第 5 次修复推送后触发复验，run `37855852616`（提交 `2d9fe9f`）
**`completed / success`** —— AP3000M 首次三个 job 全绿：

| job | 结论 |
| --- | --- |
| 质量门（语法 / 静态检查 / 单元测试） | ✅ success |
| 内核 6.18 (ap3000m) | ✅ success |
| RootFS + 刷写包 (ap3000m) | ✅ success（含 `封装 sysupgrade-tar`） |

**产物实证**（job 日志原文）：

```
[make-sysupgrade-tar] 板级：Airpi AP3000M（MT7981B）→ CONTROL BOARD=airpi_ap3000m
[make-sysupgrade-tar] 成员：kernel 12377751 B + root 268435456 B ≈ 总包 267 MiB
[make-sysupgrade-tar] sysupgrade-tar 单文件固件生成完成：
    out/AP3000M-debian13-sysupgrade.bin（280821760 字节）
```

| 产物 | 大小 |
| --- | --- |
| `AP3000M-debian13-kernel.bin`（FIT 内核） | 12,377,751 B ≈ 12 MiB |
| `AP3000M-debian13-rootfs.bin`（引导层 ext4） | 268,435,456 B = 256 MiB |
| `AP3000M-debian13-sysupgrade.bin`（sysupgrade-tar） | 280,821,760 B ≈ 267 MiB |

**第 5 次修复的关键确认点通过**：CONTROL 内**仍是** `BOARD=airpi_ap3000m` ——
该值由脚本自行从 `BOARD_SYSUPGRADE_BOARD` 读取，不受 `--board` 影响。
若误变成 `ap3000m`，设备侧 sysupgrade 会因板名不匹配拒绝刷写。
总包 267 MiB < 600 MiB 约束（整包需进设备 `/tmp` tmpfs）。

**未覆盖**：本轮用 `skip_release=true`，Release 创建 / tag / 旧 Release 清理链路未验证。

> **⚠️ 云编译成功 ≠ 可用**：只证明能构建出镜像，**实机刷写 / 启动 / 联网全部未验证**，
> 两板产物均请勿刷机。

同步：`docs/ci-status.md` 状态表 AP3000M RootFS 列转 ✅、Run 明细补 `37855852616`、
新增 §2.1 产物实证段、§5 勾选已完成的 4 项并补 2 项待办（不带 skip_release 重跑、`e2fsck`）。

### 2026-10-09 — 第 5 次构建失败修复（`--board` 误传 sysupgrade 板名），AP3000M 推进到「封装 sysupgrade-tar」

**背景**：继第 4 次修复（引导层 init heredoc）后触发复验 run `37853148758`（提交 `6ce92f8`），
失败点**再次下移一步** —— 这本身证明前一次修复真实生效，但也暴露出第 5 个独立缺陷。

#### 一、第 4 次修复的实证确认

run `37853148758` 步骤级结论（来自 `/actions/runs/<id>/jobs`）：

```
质量门                                    ✅ success
内核 6.18 (ap3000m)                       ✅ success
RootFS + 刷写包 (ap3000m)                 ❌ failure
  构建 Debian 13 RootFS                   ✅
  生成只读基础系统 SquashFS（zstd）        ✅
  生成刷写包                               ✅   ← 第 4 次修复生效
  封装 sysupgrade-tar 单文件固件           ❌   ← 新的失败点
```

#### 二、第 5 次失败根因：两个「板名」值被混用

```
bash build/make-sysupgrade-tar.sh \
  --kernel "out/AP3000M-debian13-kernel.bin" \
  --root "out/AP3000M-debian13-rootfs.bin" \
  --board "airpi_ap3000m" \
  --out "out/AP3000M-debian13-sysupgrade.bin"
[board-lib] ERROR: 未知板级 "airpi_ap3000m"。可用：ap3000m h5000m
```

本仓库有**两个都叫「板名」但语义完全不同**的值，在 `boards/ap3000m.board` 里紧挨着定义，
极易混用：

| 值 | 例子 | 语义 | 消费方 |
| --- | --- | --- | --- |
| `BOARD` / `outputs.id` | `ap3000m` | **板级 ID** | 所有 `--board` 参数；`board_load` 对它做白名单校验 |
| `BOARD_SYSUPGRADE_BOARD` / `outputs.sysupgrade_board` | `airpi_ap3000m` | **sysupgrade CONTROL 内的设备名** | **只**写进 CONTROL，供设备侧防刷错校验 |

`make-sysupgrade-tar.sh` 的契约很明确：

- `--board` 收的是**板级 ID**（:46 行 `BOARD_ID`，:69 行 `board_load "$BOARD_ID"` 校验）；
- CONTROL 的板名由**脚本自己**从板级文件读出（:77 行 `SYSUP_BOARD="$BOARD_SYSUPGRADE_BOARD"`，
  :103 行写进 CONTROL）—— 外部根本不该传。

workflow 却把 `sysupgrade_board` 喂给了 `--board`，直接撞上白名单。
**基座里其余 4 处 `--board` 本来就传的是 `outputs.id`，唯独这一处写错** ——
典型的「复制粘贴时顺手改了值」型缺陷。

#### 三、修复

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/build.yml:691` | `--board "${{ steps.board.outputs.sysupgrade_board }}"` → `--board "${{ steps.board.outputs.id }}"` |
| 同上，步骤注释 | 补入两个值的语义对照 + 事故原文 + 「该不变量由测试第 3b 项守卫」 |

> **注意 CONTROL 值不受影响**：脚本仍从板级文件自行读 `BOARD_SYSUPGRADE_BOARD`，
> 产物 CONTROL 里依然是 `BOARD=airpi_ap3000m`（设备侧校验所需），
> **不会**因为 `--board` 改传 `ap3000m` 就变成 `ap3000m`。这一点已写入
> `docs/ci-status.md` §5 作为复验时的确认点。

#### 四、新增守卫（第 3b 项）

`scripts/tests/test-workflow-board-callchain.sh`：扫描 `build.yml` **原文**里每一处
`--board ${{ steps.board.outputs.X }}`，**只认 `outputs.id`**，其余一律判 FAIL。
（用原文而非 YAML 解析值，是因为原文匹配能一眼看出传的是哪个 output。）

**负向验证已实测**：把缺陷改回 `sysupgrade_board` → 测试报

```
[FAIL] build.yml 有 1 处 --board 传了非板级 ID 的 outputs.sysupgrade_board ——
       --board 必须是板级 ID（outputs.id）；sysupgrade_board 是 CONTROL 设备名，
       由脚本自行从板级文件读取，不可作为 --board 传入
通过 25 项，失败 1 项
```

项数 25 → **26**。

**这类缺陷 actionlint / YAML 校验完全查不出** —— 它既不是语法错也不是表达式错，
只有语义级守卫能拦。

#### 五、真源与文档同步

`docs/ci-status.md`：

- 状态表 AP3000M RootFS 列 → 第 5 次失败；
- §2 Run 明细补 `37853148758`（11 个 run id 全部登记），并新增**进展链条**说明
  （`构建 RootFS` → `生成刷写包` → `封装 sysupgrade-tar`，失败点逐步下移）；
- §4 补第 5 行根因表 + 「第 5 次」教训（同名不同义的值）；
- §5 新增确认点：产物 CONTROL 必须仍是 `BOARD=airpi_ap3000m`。

**验证**：

- 全量回归 **7 组全绿**（15 + 18 + 15 + 16 + 15+18 + **26** 项）；
- `bash -n` FAIL=0；actionlint 无错误（仅 `clean-cache.yml` 一条 info 级 SC2015，不阻断）；
- 4 个 workflow YAML 可解析；`test-docs-ci-status.sh` 16 项通过。

**当前状态**：AP3000M 质量门 ✅ / 内核 ✅ / RootFS ✅ / 刷写包 ✅ /
**`封装 sysupgrade-tar` ❌（第 5 次，已修复待复验）**。两板实机验收仍全部未做。

### 2026-10-09 — 薄壳触发问题 + 第 4 次构建失败（引导层 init heredoc）修复，AP3000M 推进到「生成刷写包」

**背景**：文档按实际更新并推送到远端后，首次真正触发薄壳 workflow，连续暴露
**两个薄壳自身缺陷 + 一个构建脚本缺陷**。三者性质完全不同，逐个修复。

#### 一、远端历史分叉：哈希漂移（推送前必须先核对）

推送时发现远端 main（`933a8bd`）与本地同名提交 **SHA 不同**，且 `git fetch` 反复
返回陈旧引用（git 协议经沙箱代理被缓存，与 GitHub API 结果不一致）。

- 用 **API 权威查询**确认远端真实 HEAD，再按 **精确 SHA** `git fetch` 绕过缓存；
- 逐字节比对确认：远端 `933a8bd` 与本地 `116af8f` **内容完全一致**，仅提交元信息不同
  （此前云服务器侧以不同时间戳重推所致）；
- 处理：以远端为基线 `git rebase --onto`，只重放本地真正新增的提交，零冲突、内容树逐字节一致。

**顺手修正远端缺陷**：`933a8bd` 中 `scripts/tests/test-board-kconfig-registration.sh`
权限为 `100644`（丢了可执行位，同级脚本均为 `100755`），已恢复。

#### 二、薄壳 workflow 缺陷 1：`startup_failure`（job 数 0）

```
The nested job 'cache-cleanup' is requesting 'actions: write',
but is only allowed 'actions: none'.
```

`workflow_call` 的权限取「调用方 ∩ 被调用方」，且**调用方权限是所有被调用 job 的硬上限** ——
调用方没声明的权限，在被调用方一律降为 `none`，被调用 job 里写再高也没用。
壳顶层原只声明 `contents: read`，而基座 `cache-cleanup` 需 `actions: write`。

修复：壳顶层放开 `actions: write` + `contents: write`。**原注释里"job 级声明即可"的理解是错的**，一并改正。

#### 三、薄壳 workflow 缺陷 2：并发组死锁（3 秒即结束）

```
Canceling since a deadlock was detected for concurrency group:
'ap3000m-build-refs/heads/main' between a top level workflow and 'build'
```

壳 `group: ap3000m-build-${{ github.ref }}` 与基座 `${{ inputs.board }}-build-${{ github.ref }}`
**求值完全相同** → 自我等待。修复：删除壳的顶层 `concurrency`，**由基座统一持有**
（基座 group 已含 `board`，两板天然隔离）。

#### 四、构建缺陷（第 4 次）：引导层 init 的 heredoc 漏引号

```
build/make-sd-image.sh: line 407: BB: unbound variable
```

生成引导层 `/sbin/init` 用 `cat > ... <<INIT_EOF`（**未加引号**），外层 shell 先做变量展开；
而内嵌脚本含大量**外层不存在的自赋值变量**（`BB` / `SQ` / `MERGED` / `RETRY_FILE` / `N` / `_m`）
→ `set -Eeuo pipefail` 下当场退出。

**为什么长期潜伏**：`bash -n` / shellcheck 查不出（语法合法，只在展开期炸）；且只在走到
「生成刷写包」才暴露（内核 job 跑不到；H5000M 跑过但当时内嵌脚本还没有 `BB`）。
**"修一半"更危险**：只挪 `BB` 会让后面变量连环爆；若外层变量恰好为空则被静默替换成空串，
生成能跑但行为错误的 init —— 实机表现为莫名启动失败。

修复：

| 项 | 内容 |
| --- | --- |
| 分隔符 | 改 `<<'INIT_EOF'`，内层变量一律字面保留（与同文件 `<<'FSTAB_EOF'` 的既有写法一致） |
| 板级注入 | 改 `@BOARD_NAME@` / `@BOARD_SOC@` / `@BOARD_UPPER@` / `@BOARD@` 占位符，生成后显式替换 |
| 兜底 | 替换后若仍有 `@XXX@` 残留即 `die`（防漏配占位符静默产出坏 init） |
| 测试 | 新增 `scripts/tests/test-boot-init-heredoc.sh`（18 项） |

#### 五、补守卫：四处"看似覆盖、实则有洞"的判定

| 守卫 | 原有漏洞 | 修正 |
| --- | --- | --- |
| `test-workflow-board-callchain.sh` 第 7 项 | 只查 `contents: write`，**漏了 `actions`** | 新增 7b：遍历基座每个 job 的 permissions，逐一校验壳的上限 ≥ 之 |
| 同上 第 8 项 | 「group 含板卡名即通过」——事故里的 group 恰好含板卡名，**完全放行** | 把基座模板代入壳的 board 值后做**字符串相等**比较，相等即判死锁 |
| 同上 项数 | 23 项 | **25 项** |
| `test-boot-init-heredoc.sh` | 全新 | 18 项：A 引号 / B 内层裸变量 / C 占位符双向一致 + 残留兜底 / D 端到端生成 |

**四项负向验证全部实测可拦住**：
- 去掉 `actions: write` → 24 通过 1 失败，报「cache-cleanup 需要 actions: write」
- 还原死锁 group 写法 → 24 通过 1 失败，报「壳与基座并发组求值相同 → 死锁」
- heredoc 去引号还原事故写法 → **8 通过 10 失败**，且**复现出与线上完全相同的 `BB: unbound variable`**

#### 六、真源与文档同步

`docs/ci-status.md`：状态表 AP3000M RootFS 列更新为第 4 次失败；Run 明细补 3 个新 run
（10 个 run id 全部登记）；§4 重写为「按阶段分组」并补第 4 次根因；新增 §4.1 专门归类
**薄壳自身缺陷**（未进入 job，与构建逻辑无关）；§5 待验证清单更新。

**验证**：

- 全量回归 **7 组全绿**（18 + 25 + 16 + 15 + 15 + 18 项 + 1 组无汇总行）；
- `bash -n` FAIL=0；actionlint 无错误；4 个 workflow YAML 可解析；
- 新增测试 0755、LF 行尾；
- 真实 run 证据：`37851849934` 中 **`构建 Debian 13 RootFS` ✅ 通过、
  `生成只读基础系统 SquashFS（zstd）` ✅ 通过、内核 job ✅ 通过**
  —— 端点确认第 3 次（MT7981 固件路径/清单）修复**已完全生效**。

**当前状态**：AP3000M 质量门 ✅ / 内核 ✅ / RootFS 构建 ✅ / **`生成刷写包` ❌（第 4 次，已修复待复验）**。
两板实机验收仍全部未做。

### 2026-10-09 — 修复 AP3000M 第三次云编译失败（MT7981 固件路径 + 清单双错）+ docs 全面按实际更新

**触发**：用户要求「docs 里所有文档，根据实际更新」。

核对远端真实 CI 的过程中，不但发现**文档与事实相反**，还**查出了第三次失败的真根因**，
并顺手建立了防止再次漂移的机制。

#### 一、结论反转 + 三次失败的精确画像

查 GitHub Actions API 逐 job 核对：

| run | 提交 | 真实结论 |
| --- | --- | --- |
| 37840375623 | `a8e73ce` | ❌ 内核 job 失败（46 s） |
| 37841719136 | `e9c1594` | ❌ 内核 job 失败（44 s） |
| **37843516159** | **`c3f861d`** | **内核 job ✅ 通过**（前两次修复生效）；**RootFS + 刷写包 job ❌ 失败**（`构建 Debian 13 RootFS` 步骤，1 min 46 s） |

即：**三次失败、三个阶段各不相同**。文档当时仍写着「内核编译阶段连续失败两次」，
既漏了内核已通过这一关键进展，也漏了新增的 RootFS 阶段失败。全部 10 处按 job 维度重写。

> 期间还实测到一次「文档刚写完就过期」：本轮中途文档写的是「RootFS 进行中」，
> 随后该 job 转为失败 —— 这恰好印证了「状态必须收敛到单一真源 + 机械校验」的必要性。

#### 二、🔴 修复第三次失败根因：MT7981 固件「路径 + 清单」双错

`scripts/fetch-firmware.py` 的 `ap3000m` 固件集有两处真实错误，构成 404：

| # | 错误 | 实证 | 后果 |
| --- | --- | --- | --- |
| 1 | 路径写成 `mediatek/mt7981/mt7981_*.bin`（**子目录**） | 内核 `mt7915.h` 用**字面常量**：`#define MT7981_FIRMWARE_WA "mediatek/mt7981_wa.bin"` —— **平铺在 `mediatek/` 下**。gitlab 上游对子目录路径返回 **404** | 固件拉取失败、RootFS 构建终止 |
| 2 | 清单**漏了 `mt7981_wm.bin`**（**主固件**） | 同上头文件：`MT7981_FIRMWARE_WM "mediatek/mt7981_wm.bin"` 为驱动加载必需 | 即便路径修对仍缺件 → 实机 `mt7915e` probe 必报 `-ENOENT` |

**修复**：

| 文件 | 改动 |
| --- | --- |
| `scripts/fetch-firmware.py` | 路径改平铺；清单补齐 3 件（`wa` / `wm` / `rom_patch`）；`dest` 改 `mediatek`；补入三个文件的**真实 sha256** 白名单（494256 / 2054688 / 9824 字节）；写明「内核用字面常量，不是按 SoC 建子目录」的根因注释 |
| `build/build-rootfs.sh` | `REQUIRED_FIRMWARE` 的 `ap3000m` 分支同步为平铺 3 件，并注明「缺一不可：WA 常驻固件 / WM 主固件 / ROM patch 启动补丁」 |

**验证**：实跑 `fetch-firmware.py --board ap3000m` → **3/3 下载成功，sha256 与白名单逐项匹配**。

> **反直觉点（已写入注释与 docs）**：文件不在子目录，而在 `mediatek/` 平铺 ——
> 与 H5000M 的 MT7992（`mediatek/mt7996/` 子目录）命名习惯不同。靠"看起来合理"猜路径必翻车，
> 必须回查内核头文件的字面常量、并对上游逐项 HEAD 核实存在性。

#### 三、建立 CI 状态单一真源 `docs/ci-status.md`

**根因不是"忘了改"，而是结构问题**：一条状态结论散落在 README + 7 篇 docs + 2 个
workflow 注释里，一次 CI 变化要改 10 处，必然漂移。

新增 `docs/ci-status.md`（含稳定锚点 `<a id="ci-status">`）：当前结论三维状态表 /
Run 明细（含 **job 级结论**）/ 历史参照 Run / 三次失败根因对照 / 待验证清单 / 维护约定。

#### 四、新增回归测试 `scripts/tests/test-docs-ci-status.sh`（16 项）

**五轮负向验证打回，暴露五个"看似正确实则漏检"的写法**（全部记录在脚本注释里）：

| 轮 | 错误写法 | 后果 | 修正 |
| --- | --- | --- | --- |
| 1 | 同行出现 run id 与 ✅ 即判乐观表述 | 误伤 README 里「内核 job 已 ✅ 通过」这条**正确**陈述 | 黑名单只留「实机/生产/跑通/基线」语义 |
| 2 | 把「云编译成功 ≠ 实机可用」当乐观表述 | 误伤**安全警告本身** | 排除否定式结构 |
| 3 | `实机可用[^性]` | 连「不等于实机可用」都匹配 | 该规则废弃 |
| 4 | 乐观表述的否定词过滤按**整行**判定 | 表格右列写「实机未验证」，把左列新注入的「✅ 实机已验证，已跑通」一起放行 | 判定窗口**锚定在命中词 ±16 字符** |
| 5 | scope 守卫「含 ❌/失败 且无通过语义」即违规 | 误伤「三次失败，三个阶段各不相同…内核 job 已通过」这类**正确叙述** | 只匹配「(云编译\|整轮)\s*(失败\|❌)」断言句式 |
| 6 | 板卡状态表「含 ❌ 即违规」 | 把**正确内容**「内核 ✅ \| RootFS ❌」判为违规 | **按列切分**，只看内核列 |

> 教训（已写入脚本头注）：**测试因误报被绕过，比没有测试更糟**；漏检的守卫等于没写。
> 本脚本 5 项负向全部实测可拦住，且基线不被误伤。

#### 五、板级无关化收尾：修正大量单体名残留

| 类别 | 文档旧值（错） | 实际值（已改） |
| --- | --- | --- |
| systemd unit | `h5000m-router-init.service` / `h5000m-fancontrol` / `h5000m-grow-rootfs` / `h5000m-led(-boot)` | `router-*.service`（与 `rootfs-overlay/etc/systemd/system/` 实际文件比对确认） |
| NM profile | `H5000M-AP-2G` / `H5000M-AP-5G` | `ROUTER-AP-2G` / `ROUTER-AP-5G`（据 `router-init.sh` 的 `add_ap` 实参确认） |
| 脚本 | `h5000m-router-init.sh` / `h5000m-led.sh` | `router-init.sh` / `router-led.sh` |
| 配置 / marker | `/etc/default/h5000m-router`、`/var/lib/h5000m-rootfs-grown` | `/etc/default/router.conf`、`/var/lib/router-rootfs-grown` |
| 产物 | `H5000M-debian13-*.bin` | `<BOARD_UPPER>-debian13-*.bin` |

`H5000M-AP-2G → ROUTER-AP-2G` 是**真实文档 bug**：按旧文档排查 AP 问题会走空
（`nmcli connection show H5000M-AP-2G` 不存在）。已由测试钉住。

#### 六、其余按实际更新

| 文档 | 改动 |
| --- | --- |
| `README.md` | 状态表拆三维三列；云编译章节重写为三层入口表（+ 为什么用薄壳）；目录结构重写（补 `boards/`、`kernel/files-boards/`、`docs/ci-status.md`、3 workflow、`scripts/tests/`） |
| `docs/build-guide.md` | §3.7 三层入口 + 薄壳权限；§6 验证清单按**通用 / 板级 / 待实机复核**重构；§3.2 / §4 / §5 按双板改写（固件分板清单、`BOARD_EXTRA_FIRMWARE`） |
| `docs/troubleshooting.md` | §12 新增 4 条真实症状：`Invalid input`（薄壳传参未声明）、Release 403（薄壳缺 `contents: write`）、**符号被 `olddefconfig` 静默丢弃**、**固件路径/清单错**（含"三次根因各不相同，勿套用上次"的警告） |
| 5 篇 docs + `armbian-evaluation.md` | 警告块改三维状态表；单体名批量修正 |
| `.github/workflows/build-ap3000m.yml` | 头部状态注释按三次失败的实际进展重写 |

**验证**：

- 全量回归 **6 组全绿**（16 + 15 + 15 + 18 + 23 项 + 1 组无汇总行）；
- **5 项负向验证全部实测可拦住**（内核列写回 ❌ / 未登记 run id / 表格注入乐观表述 /
  单体名残留 / 断言整轮失败），且基线不被误伤；
- `bash -n` 21 个脚本 FAIL=0；`py_compile` / 4 个 workflow YAML 全 OK；
- 新增文件 LF 行尾；`grep` 复检单体名残留 **0**；
- 文档引用的 5 个 unit 名与 `rootfs-overlay` 实际文件**一一对应**；
- `fetch-firmware.py --board ap3000m` 实跑 **3/3 成功**（修复的直接证据）。

**待办**：重跑 AP3000M 云编译，确认 RootFS 阶段转绿。

### 2026-10-09 — docs 全面按实际更新：AP3000M 结论反转 + 建立 CI 状态单一真源

**触发**：用户要求「docs 里所有文档，根据实际更新」。核对远端真实 CI 后发现
**文档与事实相反** —— 这不是措辞问题，是结论错误：读者据此会误判「当前根本构建不出东西」，
而真实情况是**内核已能编过**（进展被掩盖）、**RootFS 阶段另有新根因**（未被记录）。

#### 一、结论反转：AP3000M 内核已编过，RootFS 阶段失败

查 GitHub Actions API 实测（**job / step 级结论**）：

| run | 提交 | 真实结论 |
| --- | --- | --- |
| 37840375623 | `a8e73ce` | ❌ 内核 job 失败（`编译 Linux 内核` 步骤，46 s） |
| 37841719136 | `e9c1594` | ❌ 内核 job 失败（`编译 Linux 内核` 步骤，44 s） |
| **37843516159** | **`c3f861d`** | 内核 6.18 (ap3000m) job ✅ 通过；**RootFS + 刷写包 job ❌ 失败**（`构建 Debian 13 RootFS` 步骤，1 min 46 s） |

即：**前两次修复均已生效，内核已能编译通过；但此前文档写「RootFS 进行中 ⏳」的期间，
该 job 实测转为失败** —— 这是第三次失败，且换了阶段、根因又是新的。

据此把全部 10 处按 job 维度改写（内核 / RootFS 分列），并显式提示 scope：
**「内核 job ✅」与「RootFS job ❌」不可互相替代** —— 既不能笼统写「AP3000M 云编译失败」
（会掩盖「内核已能编过」这个关键进展），也不能写「失败两次」（实际是**三次失败、
三个阶段各不相同**）。

#### 一之二、第三次失败根因：MT7981 固件「路径 + 清单」双错（**真实代码缺陷**）

**症状**：`RootFS + 刷写包（ap3000m）` job 的 `构建 Debian 13 RootFS` 步骤 exit 1。

**根因**（三条独立证据交叉确认）：

1. **路径错**：脚本按 H5000M 的 `mediatek/mt7996/` 子目录习惯写成
   `mediatek/mt7981/mt7981_wa.bin`，**上游该路径不存在**。
   实测（GitLab API HEAD，no-redirect）：

   | 路径 | 结果 |
   | --- | --- |
   | `mediatek/mt7981/mt7981_wa.bin` | **404** |
   | `mediatek/mt7981_wa.bin` | **OK 494256 B** |
   | `mediatek/mt7996/mt7992_wa_23.bin`（H5000M 对照） | OK 517552 B |

   对照项可用，证明不是 API/网络问题，而是**路径确实错了**。

2. **内核权威依据**：`drivers/net/wireless/mediatek/mt76/mt7915/mt7915.h` 的字面常量
   ```
   MT7981_FIRMWARE_WA    "mediatek/mt7981_wa.bin"
   MT7981_FIRMWARE_WM    "mediatek/mt7981_wm.bin"
   MT7981_ROM_PATCH      "mediatek/mt7981_rom_patch.bin"
   ```
   —— MT7981 固件**平铺在 `mediatek/` 下**，无 `mt7981/` 子目录
   （`mt7996/` 那种子目录是 MT7992 的另一回事，不可类推）。

3. **清单不全**：除路径错外还**漏了主固件** `mt7981_wm.bin`。只补前两件则 `mt7915e`
   probe 时主固件 `-ENOENT`，Wi-Fi 起不来但构建不报错 —— **静默故障**，比构建失败更危险。

**修复**：

| 文件 | 改动 |
| --- | --- |
| `scripts/fetch-firmware.py` | `FIRMWARE_SETS["ap3000m"]` 键改为平铺路径 `mediatek/mt7981_{wa,wm,rom_patch}.bin`，`dest` 由 `mediatek/mt7981` 改为 `mediatek`；**补入主固件 `mt7981_wm.bin`**；`EXPECTED_SHA256` 补 3 条实测值（`5b838a85…` 494256 B / `e09cecd2…` 2054688 B / `1cd38eaa…` 9824 B），任一不匹配即构建失败 |
| `build/build-rootfs.sh` | `REQUIRED_FIRMWARE` 的 `ap3000m)` 分支由 2 件改 **3 件**且去子目录前缀；该分支后逐项 `[[ -s ]] \|\| die`，缺任一即报明板级 |

注释同时写明内核字面常量依据与「实机 -ENOENT」后果，防止后续再按 MT7992 习惯改回子目录。

**端到端验证**（实跑，非仅静态检查）：

```
$ python3 scripts/fetch-firmware.py --board ap3000m --out /tmp/fwtest
[fetch-firmware] 板级    : ap3000m（3 个固件项）
  [OK]   mediatek/mt7981_wa.bin (5b838a854838…)
  [OK]   mediatek/mt7981_wm.bin (e09cecd2931d…)
  [OK]   mediatek/mt7981_rom_patch.bin (1cd38eaa6882…)
[fetch-firmware] 完成: 新下载 3，已存在 0，失败 0
```
sha256 三项逐项匹配白名单 —— 修复有效，**待重跑 CI 复验**。

#### 二、建立 CI 状态单一真源 `docs/ci-status.md`

**根因不是"忘了改"，而是结构问题**：一条状态结论散落在 README + 7 篇 docs + 2 个
workflow 注释里，一次 CI 变化要改 10 处，必然漂移。

新增 `docs/ci-status.md`（含稳定锚点 `<a id="ci-status">`），分节记录：

| 节 | 内容 |
| --- | --- |
| 当前结论 | 两板 × 「内核云编译 / RootFS 云编译 / 实机验证」三维状态表 |
| Run 明细 | 4 个 run 的 id / 提交 / 事件 / 结果 / **关键 job 结论**（含失败步骤与耗时） |
| 历史参照 Run | 3 个仅用于性能基线或已修复事故的 run（登记以便追溯） |
| 三次失败根因 | 对照表（前两次症状相同、根因不同；第三次换阶段、又是新根因） |
| 待验证清单 | run 剩余部分 + 实机复核项 |
| 维护约定 | 5 条引用规则 |

#### 三、新增回归测试 `scripts/tests/test-docs-ci-status.sh`（16 项）

把「文档状态必须与真源一致」前置到质量门：

- **A** 真源存在 + 锚点 + 状态表结构
- **B** 文档中出现的**每个 run id** 必须已在真源登记（禁凭空引用）
- **C** scope 混淆：run 级（不得把 `37843516159` 表述为整轮失败）+ **板卡状态表行级**
      （真源说内核 ✅，文档就不得在该行写 ❌；RootFS 列允许 ❌）
- **D** 肯定式乐观表述黑名单
- **E** 单体名残留 + **反向确认**实际 unit 文件确实叫 `router-*`
- **F** 真源引用闭环

**四轮负向验证打回，暴露四个"看似正确实则漏检"的写法**（全部记录在脚本注释里）：

| 轮 | 错误写法 | 后果 | 修正 |
| --- | --- | --- | --- |
| 1 | 同行出现 run id 与 ✅ 即判乐观表述 | 误伤 README 里「内核 job 已 ✅ 通过」这条**正确**陈述 | 黑名单只留「实机/生产/跑通/基线」语义 |
| 2 | 把「云编译成功 ≠ 实机可用」当乐观表述 | 误伤**安全警告本身** | 排除否定式结构 |
| 3 | `实机可用[^性]` | 连「不等于实机可用」都匹配 | 该规则整体废弃 |
| 4 | 乐观表述的否定词过滤按**整行**判定 | 表格右列写「实机未验证」，把左列新注入的「✅ 实机已验证，已跑通」一起放行 | 判定窗口**锚定在命中词 ±16 字符** |

> 教训（已写入脚本头注）：**测试因误报被绕过，比没有测试更糟**；而"漏检"的守卫
> 等于没写。每个守卫都必须有对应的负向验证，本脚本 4 项负向全部实测可拦住。

#### 四、板级无关化收尾：修正大量单体名残留

文档（含 README）仍大量使用 H5000M 单体名，与实际代码不符（属**误导性文档**）：

| 类别 | 文档旧值（错） | 实际值（已改） |
| --- | --- | --- |
| systemd unit | `h5000m-router-init.service` / `h5000m-fancontrol` / `h5000m-grow-rootfs` / `h5000m-led(-boot)` | `router-*.service`（与 `rootfs-overlay/etc/systemd/system/` 实际文件比对确认） |
| NM profile | `H5000M-AP-2G` / `H5000M-AP-5G` | `ROUTER-AP-2G` / `ROUTER-AP-5G`（据 `router-init.sh` 的 `add_ap` 实参确认） |
| 脚本 | `h5000m-router-init.sh` / `h5000m-led.sh` | `router-init.sh` / `router-led.sh` |
| 配置 / marker | `/etc/default/h5000m-router`、`/var/lib/h5000m-rootfs-grown` | `/etc/default/router.conf`、`/var/lib/router-rootfs-grown` |
| 产物 | `H5000M-debian13-*.bin` | `<BOARD_UPPER>-debian13-*.bin` |

`H5000M-AP-2G → ROUTER-AP-2G` 是**真实文档 bug**：按旧文档排查 AP 问题会走空
（`nmcli connection show H5000M-AP-2G` 不存在）。已由测试 E 项钉住。

#### 五、其余按实际更新

| 文档 | 改动 |
| --- | --- |
| `README.md` | 状态表拆「云编译（内核）/ 云编译（RootFS+刷写包）/ 实机验证」三列（AP3000M RootFS 列 ❌）；**云编译章节重写**为三层入口表（`build-h5000m.yml` / `build-ap3000m.yml` / `build.yml` + 为什么用薄壳）；失败记录表补第三行并改标题为「三次失败，三个阶段各不相同」；产物名去写死后补 `BOARD_UPPER` 说明；**目录结构重写**（补 `boards/`、`kernel/files-boards/`、`docs/ci-status.md`、3 个 workflow、`scripts/tests/`） |
| `docs/build-guide.md` | §3.7 补三层入口 + 触发命令 + 薄壳权限说明；§6 验证清单按**通用项 / 板级项 / 待实机复核**三类重构（原为 H5000M 硬编码，AP3000M 无法照用）；§3.2 / §4 / §5 按双板改写（固件清单分板且 AP3000M 已改平铺 3 件、`BOARD_EXTRA_FIRMWARE`、NVMe→nvmem 说明） |
| `docs/troubleshooting.md` | §12 新增 4 条真实症状：`Invalid input`（薄壳传参未声明）、Release 403（薄壳缺 `contents: write`）、**符号被 `olddefconfig` 静默丢弃**（含"两次根因不同而报错相同"的警告）；补前置提示「先看是哪个 job 的哪个步骤，三次失败阶段不同，不要套用上次根因」 |
| `docs/architecture.md`、`hardware.md`、`first-boot.md`、`debian13-partition-plan.md`、`armbian-evaluation.md` | 警告块改为三维状态表 + AP3000M 三次失败说明；单体名批量修正 |
| `.github/workflows/build-ap3000m.yml` | 头部状态注释更新（原写「云编译失败 … 验证中」→ 内核已通过 / RootFS 阶段失败（MT7981 固件路径/清单双错，已修复）） |

**验证**：

- `scripts/tests/test-docs-ci-status.sh` 16/16 通过；**4 项负向验证全部实测可拦住**
  （写回失败结论 / 未登记 run id / 表格注入乐观表述 / 单体名残留），每轮修完重新验证；
- 全量回归 6 组全绿（16 + 23 + 15 + 15 + 9 + 18 项）；
- `bash -n` 全量 FAIL=0；新增脚本 LF 行尾、0755；
- **MT7981 固件修复端到端实跑**：`fetch-firmware.py --board ap3000m` 新下载 3、失败 0，
  sha256 逐项匹配（非仅静态检查）；
- `grep` 复检：docs + README + workflows 中 `h5000m-{router-init,fancontrol,grow-rootfs,led}`、
  `H5000M-AP*`、`H5000M-debian13` 残留 **0**；
- 文档引用的 5 个 unit 名与 `rootfs-overlay/etc/systemd/system/` 实际文件**一一对应**；
- **待办**：重跑 AP3000M 云编译以复验第 3 次修复；两板实机验收仍全部未做。

### 2026-10-09 — 警告修正：H5000M 实机尚未通过（此前误标为「已跑通」）

**问题**：上一轮文档加警告时，把 H5000M 写成了「✅ 已跑通 / 可作参考基线」，并向读者
暗示「H5000M 相关能力不受影响」。这是**不准确的**：

- `c21fc66` 的 CI `success` 只证明**能构建出镜像**；
- 该镜像**从未在真机刷写验收** —— 能否正常启动、LAN `192.168.88.1` 是否可达、
  Wi-Fi 是否 probe 成功、风扇是否按曲线转动、eMMC 首启扩容是否生效，**全部未验证**；
- 多板化改造（`router-*.service` 改名、两层 overlay、`chroot-finalize.sh` 的 enable
  修正）之后的回归同样未做。

把「云编译通过」等同于「可用」会让读者产生错误的安全感，对刷机决策是危险的。

**修正**：全仓 9 处表述改为准确状态，并显式点出「云编译成功 ≠ 实机可用」。

| 位置 | 修正 |
| --- | --- |
| `README.md` 警告块 | 表头拆为「云编译 / **实机验证**」两列（H5000M：✅ 成功 / ⚠️ 尚未通过）；新增「本项目至今没有任何一块板卡完成实机验收」；待办清单补齐 **H5000M 的 5 项实机复核**（启动 / LAN 可达 / Wi-Fi probe / 风扇曲线 / eMMC 扩容） |
| `README.md` 硬件表 | 「自定义 6.18 内核」行 `✅ 已跑通` → `⚠️ 云编译通过，实机未验证` |
| `docs/architecture.md`、`first-boot.md`、`troubleshooting.md`、`hardware.md`、`debian13-partition-plan.md` | 统一警告块中 H5000M 那行重写，补「云编译成功 ≠ 实机可用 / 至今无板卡完成实机验收」 |
| `docs/build-guide.md` | 警告块标题 `尚未端到端验证通过` → `尚未实机验证通过`；H5000M 改标 ⚠️；刷机禁令从"勿刷 AP3000M"扩为"**两板均不例外**" |
| `.github/workflows/build-h5000m.yml` | 壳头部状态注释改为实机未验证 + 请勿刷机 |
| `.github/workflows/build-ap3000m.yml` | 补「全仓状态提醒」：H5000M 虽云编译成功但实机未验证，两板均勿刷机 |

**验证**：`grep -rn '已跑通\|✅ 通过\|✅ 已\|可作参考基线'` 在 `README.md`、
`docs/*.md`、`.github/workflows/*.yml` 中返回**空**（乐观表述已全部清除）。

### 2026-10-09 — 文档同步：全面加注「未跑通」警告 + 多板化改写

**背景**：AP3000M 云编译连续两次失败（详见下条），当前**无任何 AP3000M 可用产物**。
文档此前仍以「H5000M 单体」视角描述，且未标注板卡验证状态，存在被误用于刷机的风险。
本轮做两件事：**加警告**、**板级化**。

**加警告**（醒目 blockquote，置于各文档标题正下方）：

- `README.md` —— 警告块含**失败记录表**（run / 提交 / 结果 / 根因三行），
  并明确"请勿将本仓库当前状态用于生产或刷机验收"，列出即使 CI 通过也必须实机复核的 4 项。
- `docs/build-guide.md` —— 警告块 + 声明"本文档描述的多板构建流程尚未端到端验证通过"。
- `docs/architecture.md`、`docs/first-boot.md`、`docs/troubleshooting.md`、
  `docs/hardware.md`、`docs/debian13-partition-plan.md` —— 统一警告块，
  点名 AP3000M 相关资产（`boards/ap3000m.board`、`dts/mt7981b*`、
  `build/kernel-conf/ap3000m-6.18.config`、`kernel/files-boards/ap3000m/`、
  AP3000M 风扇链路）为**未验证状态**。

**多板化改写**：

| 文档 | 改动 |
| --- | --- |
| `README.md` | 标题改为双板；硬件支持表由「状态」单列改为 **H5000M / AP3000M 双列对照**；WAN/LAN 改为双板表格；风扇行说明 16GB/8GB 双路径；补多板化架构说明（`.board` + `overlay.d` + `files-boards` 三处真源） |
| `docs/build-guide.md` | 加已支持板卡表（board ID / 机型 / SoC / DTB / 内核配置）；**所有命令补 `--board`**（`scripts/build.sh`、`build-kernel.sh`、`build-rootfs.sh`）；产物名改为 `<BOARD_UPPER>` / `<BOARD_DTB>` 占位；凭据路径改 `/etc/<board>-initial-credentials`；`h5000m-grow-rootfs` → `router-grow-rootfs`；验收清单补「首启服务已 enable」5 项（含 unit 名不带板级前缀的约定） |

**验证**：`grep` 复检确认 `docs/build-guide.md` 已无 `h5000m-fancontrol` /
`h5000m-grow-rootfs` / `h5000m-router-init` / `h5000m-led` / `/etc/h5000m-` /
`h5000m-debian13` 等旧命名单体残留。

### 2026-10-09 — AP3000M 云编译二次失败修复（Kconfig `depends` 引用了非 Kconfig 符号 `HRTIMER`）

**症状**（run 37841719136，`e9c1594`）：补齐 Kconfig 后**仍 46s 失败**，报**完全相同的**
`[WARN] CONFIG_AIRPI_GPIO_FAN 未启用（补丁未生效或符号名不匹配）`。

**真根因**：新增的 Kconfig 写了 `depends on GPIOLIB && HRTIMER`，而
**`HRTIMER` 在内核里不是一个 Kconfig 符号** —— hrtimer 是核心基础设施，无条件编入；
Kconfig 里只有 `config HIGH_RES_TIMERS`（可选的 tickless 高精度模式）。

后果链与首次失败**一模一样**：
1. `depends on ... && HRTIMER` 中 `HRTIMER` 恒求值为 `n`；
2. `config AIRPI_GPIO_FAN` 被 Kconfig 判为**不可见**；
3. `.config` 里的 `=m` **第二次被 `olddefconfig` 静默丢弃**。

**这是本问题最难排查之处：两次原因不同、报错信息完全相同。** 上一轮修复（补 Kconfig
文件）看起来"应该已经解决了"，实际只是把第二个陷阱暴露出来。

**修复**：

| 项 | 内容 |
| --- | --- |
| 修改 | `depends on GPIOLIB`（`GPIOLIB` 是真实符号，`drivers/gpio/Kconfig` 中 `menuconfig GPIOLIB`）。hrtimer API 的可用性由源码 include 与 export 保证，不需要也不应写进 `depends` |
| 新增 | Kconfig 内补入完整根因注释，含可复用规则：「写 `depends` 前必须 `grep -r '^config <SYM>' --include=Kconfig` 确认每个符号都真实存在，尤其别把**宏 / 内部函数名**当成 CONFIG 符号」 |
| 增强 | `scripts/tests/test-board-kconfig-registration.sh` **13 → 15 项**，新增 `depends` 符号可达性双向校验：<br>• **陷阱清单命中即 FAIL**（宏 / 内部 API 名，恒不可能是 Kconfig 符号）：`HRTIMER`、`GPIO_LOOKUP_IDX_OF`、`GPIOLIB_LEGACY`、`HRTIMER_MODE_REL`、`IS_ENABLED`、`LINUX_VERSION_CODE`、`OF_GPIO`、`HWMON_DEVICE_ATTR`<br>• **合法白名单外 FAIL**（`GPIOLIB`/`HWMON`/`OF`/`PWM`/`THERMAL`/...），提示人工核对 |

**验证**：负向验证闭环 —— 把 `HRTIMER` 加回去，测试由 15 通过降为 **13 通过 2 失败**，
确认能真正拦住该陷阱。回归测试 4 组全绿（15 + 15 + 9 + 18 项）。
CI 侧 `c3f861d` 验证构建进行中。

### 2026-10-09 — AP3000M 首次云编译失败修复（缺 `drivers/hwmon/Kconfig` 注册，符号被静默丢弃）+ unit 名一致性收尾

**事故**：AP3000M 首次云编译在 **46 秒**处失败（run 37840375623），日志：

```
[build-kernel]   [OK] CONFIG_GPIOLIB_LEGACY
[build-kernel]   [WARN] CONFIG_AIRPI_GPIO_FAN 未启用（补丁未生效或符号名不匹配）
[build-kernel]   [OK] CONFIG_SENSORS_PWM_FAN
[build-kernel] ERROR: 关键配置项缺失（见上方 WARN）。--strict 模式下终止构建
```

40+ 项配置全部 `[OK]`，仅 `CONFIG_AIRPI_GPIO_FAN` 一项失败。

**根因**：板级内核源码层首版只提供了 `airpi-gpio-fan.c` + `Kbuild`，并在
`drivers/hwmon/Makefile` 追加了 `obj-$(CONFIG_AIRPI_GPIO_FAN) += airpi-gpio-fan/`，
**但 `drivers/hwmon/Kconfig` 里没有 `source` 驱动目录的 Kconfig**。

后果链：
1. `CONFIG_AIRPI_GPIO_FAN` 这个符号在内核 Kconfig 树中**根本不存在**；
2. `.config` 片段里的 `=m` 在 `make olddefconfig` 阶段被当作**未知符号静默丢弃**
   —— Kconfig 对未知符号不报错，这是最坑的一步；
3. 模块不编译，`--strict` 配置核验报 WARN 并终止。

关键认知：**Makefile 只回答「怎么编」，Kconfig 才决定「符号是否存在、能否被选中」**，
两者必须同时提供。且失败信息（"补丁未生效或符号名不匹配"）指向错误方向，
实际是符号压根没定义。

**修复**：

| 项 | 内容 |
| --- | --- |
| 新增 | `kernel/files-boards/ap3000m/drivers/hwmon/airpi-gpio-fan/Kconfig`（`tristate`，含依赖 `GPIOLIB && HRTIMER` 与完整 help） |
| 修改 | `build/build-kernel.sh` 在 `drivers/hwmon/Kconfig` 的 `endif # HWMON` **之前**插入 `source`，保证落在 `menuconfig HWMON` 块内；幂等，且找不到结束标记时退回文件末尾追加（语法仍合法） |
| 新增 | 注册后硬校验 `drivers/hwmon/airpi-gpio-fan/Kconfig` 存在，缺失即 `die`（把静默丢弃变成显式失败） |
| 新增 | `scripts/tests/test-board-kconfig-registration.sh`（13 项）钉住不变量：Kbuild/Kconfig/c 三件套齐备、`config AIRPI_GPIO_FAN` 存在且为 `tristate`、help 缩进规范、**从真实脚本抽取注册块**喂 mock 内核树验证「插在 endif 之前 + 幂等」 |

**同轮一并修复的 unit 名一致性缺陷**（`router-*.service` 板级无关化收尾）：

| 位置 | 问题 | 影响 |
| --- | --- | --- |
| `build/rootfs/chroot-finalize.sh` | `enable "${BOARD_PREFIX_}-router-init.service"` 等 5 处 | **真实缺陷**：unit 已改名 `router-*.service`，旧名不存在 → enable 失败；且每行带 `\|\| true` 完全吞掉错误。后果 = 首启网络编排 / 风扇 / 首启扩容 / LED **全部不启动且无任何报错** |
| `scripts/install-emmc.sh` | 提示语 `${BOARD}-grow-rootfs.service` | 真实缺陷：展开成 `h5000m-…`/`ap3000m-…`，两者都不存在，按此排查会走空 |
| `build/make-sysupgrade-tar.sh` | 日志 `${BOARD_ID}-grow-rootfs.service` | 真实缺陷：打包日志里的 unit 名错误 |
| `build/build-rootfs.sh`、`build/rootfs/packages.list` | 注释中的旧 unit 名 / 凭据文件名 | 过时注释，误导维护者 |

另有 `router-fancontrol` 打通 `FAN_HWMON_MATCH` 配置项（原为硬编码字面量 `pwmfan`，
板级 `BOARD_FAN_HWMON_MATCH` 未被消费）；`status` 子命令新增 `hwmon_match` 输出。

**验证**：本地 `bash -n` FAIL=0；`shellcheck --severity=error` 无输出；
回归测试 4 组全绿（13 + 15 + 9 + 18 项）；`test-board-kconfig-registration.sh`
经**负向验证**（删掉 Kconfig 后由 13 通过降为 8 通过 1 失败）确认能真正捕获缺陷。
CI 侧待重跑 AP3000M 全流程确认。

### 2026-10-09 — AP3000M 风扇控制落地（GPIO 软 PWM 驱动内置构建 + 三后端 PWM 分流 + 板级回归测试）

**背景**：AP3000M 的风扇接法与 H5000M **完全不同**，且存在两款硬件版本。依据官方
`LianXia233/luci-app-airpi3000m-fancontrol`（该插件专为 `airpi,ap3000m` 定制）：

| eMMC | 驱动链路 | PWM 节点 |
| --- | --- | --- |
| 16GB | 主板未引出硬件 PWM 引脚，风扇挂 **GPIO 540**，由 `kmod-airpi-gpio-fan` 位翻转软 PWM | `/sys/kernel/duty_cycle` |
| 8GB | 主板已接硬件 PWM 控制器，内核 `pwm-fan` 驱动 | `hwmon/*/pwm1`（上游 DTS `&fan { pwms = <&pwm 2 40000 0>; }`） |

**此前仓库中的缺陷（本轮修复）**：通用层 `router-fancontrol` 的 `find_pwm()` 只扫描
`hwmon/*/pwm1`。在 16GB 版上该节点**永不存在** → `find_pwm()` 恒失败 → 风扇完全不转，
且日志只报「PWM control node not found」，极易被误判为硬件故障。板级层原注释还错误地
写着「AP3000M fan 挂 pwm2 / hwmon 名 pwmfan」，与硬件实际不符。

**改动**：

- **内核驱动内置构建**（`kernel/files-boards/ap3000m/drivers/hwmon/airpi-gpio-fan/`，vendored 自官方，GPL-2.0-only）：
  - 新增**板级内核源码层**机制 `kernel/files-boards/<board>/`：`build-kernel.sh` 在复制
    `files-generic` / `files-mediatek` 之后叠加该层，只对所属板卡生效。
  - **为什么在本仓库构建而不是拿上游 .ko**：上游 README 记录了实机踩坑 —— 即使 vermagic
    完全一致，外部 .ko 仍可能因 `struct module` 大小/偏移不匹配被拒载
    （`this_module section size must match`），根因是 `CONFIG_MODULES_TREE_LOOKUP` /
    `EVENT_TRACING` / `DEBUG_INFO_BTF_MODULES` / `BPF_EVENTS` 改变了结构体布局。
    本仓库自行编译内核，模块与 vmlinux 出自同一次 `make`，配置天然一致，该 ABI 风险归零。
  - `drivers/hwmon/Makefile` 追加 `obj-$(CONFIG_AIRPI_GPIO_FAN) += airpi-gpio-fan/`
    （新增目录不会被自动递归；用追加而非 patch，避免随内核版本漂移失配）。
  - **`CONFIG_GPIOLIB_LEGACY=y` 显式钉死**：驱动有两条 GPIO 申请路径（legacy 整数接口 /
    6.17+ descriptor），由 `IS_ENABLED()` 选择。显式开启 legacy，不依赖 6.18 的默认值，
    锁定在长期验证的成熟路径上。
- **通用层 `router-fancontrol` 三后端 PWM 分流**：
  - `hwmon`（H5000M / AP3000M 8GB）、`pwmchip`（`/sys/class/pwm/.../duty_cycle`）、
    `softpwm`（`/sys/kernel/duty_cycle`）。
  - `PWM_BACKEND=auto` 判定与官方 `airpi-fanctl` 一致：读 `/sys/block/mmcblk0/size`，
    > 25 000 000 扇区（≈12.8 GiB）判为 16GB 版 → softpwm；否则先试 hwmon → pwmchip →
    最后回退 softpwm。读不到容量时按「有硬件 PWM 就走硬件」处理。
  - 新增 `router-fancontrol-modprobe` 钩子（**通用层为空操作，板级层覆盖**），由
    `router-fancontrol.service` 的 `ExecStartPre` 调用，在守护进程读 sysfs 之前加载驱动模块。
  - `status` 子命令新增 `pwm_backend` / `pwm_backend_cfg` / `softpwm_node` /
    `softpwm_loaded` / `emmc_sectors` 五项，便于实机诊断。
  - 软 PWM 节点缺失时给出**区分性告警**（提示检查 `airpi-gpio-fan` 是否加载），
    不再与「通用找不到 PWM」混为一条消息。
- **板级层**（`boards/overlay.d/ap3000m/`）：
  - 新增 `usr/local/sbin/router-fancontrol-modprobe`（覆盖通用层空操作版）：按 eMMC 容量
    决定是否 `modprobe airpi_gpio_fan fangpio=540 cycle=255 period=15000 fanen=1`，
    并校验 `/sys/kernel/duty_cycle` 出现；加载失败 `exit 1` 让服务显式失败。
  - `etc/default/router-fancontrol` 新增 `PWM_BACKEND=auto` / `AIRPI_FAN_GPIO=540` /
    `AIRPI_FAN_PERIOD=15000` / `AIRPI_FAN_FORCE=`（调试用强制覆盖）。
  - `etc/default/router.conf` 风扇段更正为「两版本双路径」的准确描述（原文有误）。
  - **H5000M 侧显式 `PWM_BACKEND=hwmon`**：钉死行为，避免 auto 判定在异常情形下误走
    softpwm（该板没有 `/sys/kernel/duty_cycle`）。
- **构建与 CI 防回归**：
  - `build/kernel-conf/ap3000m-6.18.config` 新增 `CONFIG_GPIOLIB_LEGACY=y` /
    `CONFIG_AIRPI_GPIO_FAN=m`（`CONFIG_SENSORS_PWM_FAN=y` 原已有，未重复定义）。
  - `build/build-kernel.sh` 的 `ap3000m` 分支 `REQUIRED_SYMBOLS` 纳入上述三项。
  - **ccache key 修正**（`build.yml`）：原 key 未覆盖 `kernel/files-generic` /
    `files-mediatek` / `files-boards` 与 `boards/`，会导致「改了驱动源码仍复用旧 .o」的
    静默脏命中；同时加入板卡维度，避免两板跨用缓存。这是引入 `files-boards` 后必须同步的修复。
- **新增回归测试** `scripts/tests/test-fan-pwm-backend.sh`（CI 的 `scripts/tests/*.sh` 自动纳入）：
  用 awk 从**真实脚本抽取函数体**（不复制逻辑）喂入 mock sysfs，覆盖 9 例：16GB→softpwm、
  8GB→hwmon、8GB 仅 pwmchip、容量不可读的三种回退、强制覆盖两例、H5000M 判据。

**验证状态**：`bash -n` / `shellcheck --severity=error` 全绿（含 workflow 36 段内嵌脚本）；
`test-fan-pwm-backend.sh` 9/9 通过；两块板板级字段导出实测正确；
两层 overlay 叠加后板级钩子覆盖与 0755 权限实测正确。
**待实机确认**（无实机，仅静态分析）：16GB 版 `modprobe` 后 `/sys/kernel/duty_cycle`
确已出现、`fangpio=540` 对该板正确、8GB 版 `hwmon pwm1` 实际 hwmon 序号。

### 2026-10-09 — 实机启动硬挂死诊断 + 五组缺陷修复（内核可诊断性 / Wi-Fi 时序 / 首启扩容 / 刷写脚本 / 兜底引导与救援）

**实机现象（串口实锤，COM3 115200 8N1 全程录制）**：t≈10.0s 起完全静默冻结，此后只有 RCU 告警
（录制至 t=409s 仍在刷）。判读证据：① `t=2105 jiffies` + `CONFIG_HZ=100` 反推挂死起点；
② CPU 0/1/3 的 softirq 计数在 7 次 dump 中**逐字相同**（1096/1097、928/939、839/839），CPU3
`timer-softirq=251` 冻结、内核自述 `Possible timer handling issue on cpu=3`；③ `Sending NMI from
CPU 2 to CPUs 0/1/3` 之后**无任何回栈**（`CONFIG_ARM64_PSEUDO_NMI` 未启用时
`arch_trigger_cpumask_backtrace()` 走普通 IPI，被钉死的核取不到中断）；④ 连 systemd(1) 都不再推进
（oneshot 默认 90s 应打 `Timed out` 而没打）→ 持 `console_lock` 的正是被钉死的核。
结论：**内核级硬挂死，不是慢 I/O**。首要嫌疑：`h5000m-grow-rootfs` 首次真机执行（CHANGELOG
2026-10-06 明确记录它此前从未被 enable，本机内核编译于 2026-10-07）→ 全分区在线 `resize2fs`
（设备上最重的 eMMC 写）→ 命中本项目长期跟踪的「msdc 写挂死」。

- **内核 config**（`build/kernel-conf/h5000m-6.18.config`）：
  - **Wi-Fi 由内置改模块**（`CONFIG_CFG80211=m` / `MAC80211=m` / `MT7921E=m` / `MT7925E=m` /
    `MT7996E=m`，`WLAN=y`）：内置驱动 t=1.505s 请求 `mediatek/mt7996/mt7992_rom_patch_23.bin`，
    而 `VFS: Mounted root` 在 t=1.754s → `-ENOENT` → `mt7996e probe ... failed with error -2`，
    Wi-Fi 100% 起不来（`regulatory.db` 同理）。新增
    `rootfs-overlay/etc/modules-load.d/h5000m-wifi.conf` 在 rootfs 就绪后确定性加载。
  - 新增 `CONFIG_EFI_PARTITION=y`（`root=PARTLABEL=rootfs` 依赖；此前纯属侥幸可用）。
  - 新增挂死可诊断性：`ARM64_PSEUDO_NMI=y`、`SOFTLOCKUP_DETECTOR`/`HARDLOCKUP_DETECTOR=y`、
    `DETECT_HUNG_TASK=y`、`DEFAULT_HUNG_TASK_TIMEOUT=30`、`RCU_CPU_STALL_TIMEOUT=10` —— 让下一次
    "静默冻结"能直接给出带函数名的现场，而不是只有 softirq 计数。
  - `build/build-kernel.sh` 的 `REQUIRED_SYMBOLS` 同步扩充（把上述关键项纳入构建期断言）。
- **首启扩容**（`h5000m-grow-rootfs.service` + `usr/local/sbin/h5000m-grow-rootfs`）：
  - `StartLimitBurst` / `StartLimitIntervalSec` 从 `[Service]` 移到 `[Unit]` —— 实机日志实证
    systemd 报 `Unknown key` 并直接忽略（配置写错段等于没写）。
  - service 移出启动关键路径：`After=local-fs.target multi-user.target` + `TimeoutStartSec=90`，
    不再让一次 eMMC 重写卡住整个 boot。
  - 脚本改为「先只读容量比对，已扩容则一行不写」：读 `sys/class/block/*/size` 与 `dumpe2fs -h`
    算多余空间，不足一个块组直接 `exit 0` 并打 marker，避免每次启动都做无谓写盘。
- **刷写脚本**（`scripts/install-emmc.sh`）：
  - **P0：GPT 解析 100% 失配 → 刷入通道全程中止**。原正则要求 `sgdisk -p` 的 Size 列为纯整数
    （`([0-9]+)` 后紧跟空白），而真实输出是**人类可读**的 `30.0 MiB`（含小数点、占两列）→
    每行 `continue` → `N_PART=0` → `die`。新解析块按「第 5 列是否为容量单位」动态判定 Name
    起始列，两种格式（人类可读 / 纯扇区数）通吃；无表体时 `die` 兜底（绝不在未知布局上写盘）。
  - 新增 `--no-grow` 与 **p5 离线扩容段**（写 p5 后、§6 校验前）：挂载状态硬前提检查 +
    `blockdev --flushbufs` + `resize2fs` + 扩容后容差校验（允许不足一个块组的零头）。
  - 新增回归测试 `scripts/tests/test-parttable-parse.sh`：从 install-emmc.sh **抽取真实解析块**
    执行（避免测试与实现各写一份），用桩 `sgdisk` 覆盖 4 种格式，**18 项全通过**。
- **兜底引导死路径 + 救援路径三重缺陷**（`build/make-sd-image.sh`）：
  - **P1-1 兜底引导引用不存在的文件**：`extlinux.conf` 的 `KERNEL ../Image` 与 `boot/boot.cmd`
    的 `/boot/Image`（mmc 0:5 分支）指向的文件**全脚本从不落盘**（只把 FIT 写 p4，而 FIT 不能当
    `booti` 的裸 Image 用）→ 兜底引导 100% 以 `File not found: /boot/Image` 收场，而
    `docs/debian13-partition-plan.md` 声称"两套文件均已预置"。修法：
    新增 `--keep-boot-image`（默认关闭，与 2026-10-06「省 60+ MiB」的决定一致）；
    **`/boot` 引导文件按真实字节计入镜像尺寸与空闲预算**（旧实现让这 60 MiB 游离在预算之外：
    要么 `mkfs.ext4 -d` 直接 ENOSPC，要么侥幸建成却把空闲压到 errno 28 以下、实机起不来——
    这条正是 2026-10-06「EXTRA_MB=24 只剩 2.8 MiB → 起不来」的同一类坑）；
    `extlinux.conf` 与 `Image` **同进同退**（缺 Image 时不写该文件，不留引用空气的配置）；
    镜像自检新增互斥断言（有 conf 无 Image 直接拒绝产出）。`extlinux.conf` 的 APPEND 补 `rw`，
    与 `FIT_BOOTARGS` / `boot.cmd` 三处 cmdline 对齐。
  - **P1-2 救援路径三重缺陷**（文档承诺的"防砖救援"从未实现）：
    ① `umount /rmerged` 写死裸路径，而真实挂载点是 `/overlay/merged`（`$MERGED`）→ 每轮 umount
    都失败、overlay/loop 引用持续累积，**反而加剧了它自己注释里那个「437 轮 → deadlocked on
    memory」的 OOM 循环**（2026-10-06 条目还把这条错误路径当正确做法记录了下来）；
    ② 救援 overlay 用 `lowerdir=/` + `upperdir=/rrun/upper`，upper 嵌在 lower 之内 —— 内核
    overlayfs 自 6.5 起 `ovl_check_overlapping_layers()` 直接判 `-EINVAL`，**救援根 100% 构造
    失败**；且 `lowerdir=/` 里只有 busybox 与本脚本、没有可用 userspace，`exec /sbin/init` 又回到
    本脚本自身（见 ③）；③ 救援失败后 `exec /sbin/init` 构成自循环。
    修法：挂载点一律用变量 + `umount -l` 兜底，并修正「先摘 overlay → 再摘 rescue tmpfs → 最后摘
    /sq → `losetup -D`」的顺序（否则在用设备挡住摘除、loop 泄漏清不掉）；救援根改为
    **`lowerdir=/sq`（只读 Debian 用户空间）+ `upperdir/workdir` 落 tmpfs（128 MiB，RAM 后备）**
    —— 与 `docs/architecture.md` 「SquashFS 根 + tmpfs upper」的设计承诺终于一致，且 tmpfs 零落盘，
    正好避开本场景高概率的「msdc 写挂死」；救援**只尝试 1 次**（计数器在 devtmpfs，每次开机归零），
    其后一律转串口应急 shell，彻底去掉 `exec /sbin/init` 自循环。
  - **P2**：`usage()` 原本 `sed -n '2,30p'` 恰在第 30 行截断，而"用法："段从第 31 行才开始 →
    `--help` **从来不显示调用方法**（新增参数也看不见）；改为按抬头注释块动态截取。两条 `die`
    文案在逗号/冒号处被截断（"…空闲不足，"），补齐全文。头部注释把 `--extra-mb` 默认值错写成 24
    （实为 128）。
  - 新增回归测试 `scripts/tests/test-boot-layer-space.sh`：抽取真实预算块 + 确定尺寸桩文件，
    断言「引导文件入账 / 加 Image 后镜像同步增大 / 空闲量不被整张 Image 侵蚀 / 下限工况仍安全 /
    低于下限仍 die」，**15 项全通过**。两个测试共 33 项，0 失败。
- **硬约束遵守**：全程未触碰 U-Boot / GPT / p1-p3 / u-boot-env / factory / fip / eMMC 硬件配置，
  分区布局与启动链保持零改动（分区分辨率相关代码只读不写）。
- **文档同步**：`docs/debian13-partition-plan.md`（§2 distro boot 注记、§6 Kernel 与备用脚本两行、
  §7 兜底路径，明确 `/boot/Image` 需 `--keep-boot-image` 且与 extlinux.conf 同进同退）、
  `docs/architecture.md`（p5 内容清单）、`docs/build-guide.md`（p5 内容清单）、
  `docs/troubleshooting.md`（救援"重试 3 次"改为"只尝试 1 次"；新增兜底引导 `File not found`
  排查行）、`build/make-sd-image.sh` 与 `boot/boot.cmd` 注释。
- **验证状态**：`bash -n`（外壳）+ `sh -n`（从 heredoc 抽出的引导层 init）通过；两个回归测试
  33 项全绿；`usage()` 实际输出已核对覆盖到"用法"段。**待 CI 重建 → 重刷 p4+p5 → 实机复验**。
  本次改动尚未推送，等用户确认与凭据。

### 2026-10-07 — 修复 RootFS 构建 shebang 扫描静默退出（不确定性失败）

- **根因**（run 37551055700 / build #42）：`build-rootfs.sh` 覆盖层 shebang 扫描的循环体写的是 `head | grep -q '#!' && printf`。在 `set -Eeuo pipefail` 下 while 循环的退出码等于循环体**最后一次执行**的状态：当 `find` 枚举的最后一个文件恰好无 shebang（如普通配置文件）时整条管道返回 1，子 shell 静默退出，主脚本无消息退出 1——runner 日志表现为打印"安装固件"后 46ms 内 exit 1，无任何错误输出。
- **为何以前不炸**：旧版扫描范围只含 `usr/local/{sbin,bin}` 与 dispatcher.d（全是脚本文件，循环体最后必成功）；上轮审计修复把范围扩大到整个覆盖层后引入 18 个无 shebang 的配置文件，是否触发取决于文件枚举顺序，属不确定性行为（本地恰好存活、CI 必炸）。
- **修复**：判定搬进 `if` 语境（if 条件失败不影响循环退出码），并新增兜底——扫描结果为空时 `die` 显式报错。
- **验证**：构造"末位无 shebang"场景复测原结构必挂、修复后存活；对真实覆盖层全量扫描结果与旧逻辑一致（7 个脚本）；`bash -n` / shellcheck 通过；全仓确认无其他 `grep -q ... && ...` 循环体模式。
- 同步 CHANGELOG。

### 2026-10-07 — 修复 quality-gate pyflakes 命令缺失（127）

- **根因**：Ubuntu noble（runner 24.04）的 apt 包 `python3-pyflakes` 只提供 `/usr/bin/pyflakes3`，不带 `pyflakes` 入口脚本；CI 步骤调用裸 `pyflakes --version` 报 `command not found`（exit 127），run 37550743057 的「安装检查工具」步骤失败、后续质量门全部跳过。沙箱内验证未暴露该差异，因为 pip 安装的 pyflakes 才带同名入口脚本。
- **修复**：两处调用统一改为 `python3 -m pyflakes`（版本探测与静态检查步骤），模块名跨发行版固定，不再依赖入口脚本命名。
- 全仓确认无其他裸 `pyflakes` 调用残留；YAML 校验与 `python3 -m pyflakes` 实测通过。
- 同步 CHANGELOG。

### 2026-10-07 — 修复 clean-cache 工作流 403 权限失败

- **根因**：`clean-cache.yml` 未声明 `permissions`，仓库默认工作流权限为只读（contents/packages read），`gh cache delete` 需要的 `actions: write` 不在授权内，实测报 `HTTP 403: Resource not accessible by integration`（run 37549966619）。`build.yml` 的 `cache-cleanup` job 因早已显式声明 `actions: write` 不受影响。
- **修复**：job 级显式声明 `permissions: actions: write`（最小授权，仅这一个 job 拿写权限）。
- **删除逻辑加固**：改为逐条删除（`gh api DELETE .../actions/caches/{id}`），单条失败不中断并继续；`gh cache list` 显式 `--limit 1000`（默认只列 30 条）；全部失败以非零退出让 run 明确红掉；删除后仍输出剩余缓存清单便于核对。`--jq` 输出格式已在本地用真实仓库实测。
- 同步 CHANGELOG。

### 2026-10-07 — 历史 Release 清理与凭据资产清除

- **清空历史 Release**：删除全部 11 个历史 Release 及其 11 个 tag，释放约 8.1 GiB Release 资产（单个 Release 含 kernel/rootfs/squashfs/sysupgrade 四个大件，约 660 MiB）。
- **清除明文凭据资产**：11 个 Release 均附带 `initial-credentials.txt`（内容为 root 与 WebUI admin 的明文出厂口令）。仓库为 public，任何人无需登录即可下载。已逐个删除全部 11 个该资产；`build.yml` 早已不再把该文件放入 Release，本次清除了历史遗留。
- **构建后自动清理**：新增 `keep_releases` 输入（默认 3，填 0 关闭）。发布成功后按发布时间倒序保留最近 N 个，其余 Release 连同资产与 tag 一并删除。防护：`skip_release` 时跳过、非法输入按不清理处理并告警、跳过 draft、先删 Release 再删 tag、删除动作打 `::warning` 便于审计。
- **内嵌脚本纳入静态检查**：quality-gate 新增「GitHub Actions 内嵌 run 脚本」ShellCheck 步骤，用 PyYAML 解析出每个 `run:` 块补shebang 后送 shellcheck（`--severity=error -s bash -e SC2296`，SC2296 为 GitHub 表达式误报），填补 workflow 脚本不在 `find -name '*.sh'` 覆盖范围内的检查盲区；检查工具依赖补 `python3-yaml`。
- 保留出厂默认口令 `password` 不变；清理为不可逆操作，删除前清单已留档。

### 2026-10-07 — Linux-Router H5000M 桥接 AP 适配

- **识别系统预设热点**：Linux-Router 面板与网络摘要识别 `H5000M-AP-2G/5G`，展示实际 SSID/无线状态并提供停止操作，不再把系统 AP 误判成 Wi-Fi 客户端。
- **热点共用 LAN 服务**：面板创建的 `DebianRouterHotspot` 改为 `br-lan` 从属连接、关闭连接自身 IPv4/IPv6 服务，避免 NetworkManager `shared` 与系统 dnsmasq/NAT 冲突；停止自定义热点时恢复对应预设 AP。
- **客户端与状态检测**：客户端租约从系统 dnsmasq lease 文件读取，邻居/IP 与 LAN bridge 对齐；热点在线和依赖检查按桥接连接检测。
- **启动保持默认 AP**：router-init 每次启动都恢复两个预设 AP profile 的 autoconnect，避免面板停止热点后该设置跨重启残留。
- 同步架构与排障文档；不改默认密码与 LAN 地址。

### 2026-10-07 — 修复 Debian 首启固件与服务编排遗漏

- **固件进入 rootfs**：将已下载的 MT7992 Wi-Fi 与 MT7987 2.5G PHY 固件安装到 `/usr/lib/firmware/mediatek`，并在构建阶段逐项检查文件存在且非空。
- **消除启动等待闭环**：不再从 `h5000m-router-init` 同步重启被 systemd 排在该服务之后的 dnsmasq；由 systemd 在网络初始化结束后启动 dnsmasq。NetworkManager 激活命令设有限等待，Wi-Fi profile 改为接口晚到后自动连接。
- **修复 USB 5G 接口竞态**：启动时始终创建绑定 `eth2` 的 DHCP profile，交给 NetworkManager 在 USB 网卡出现时自动激活；MT5700 拨号 hook 改为请求 NetworkManager 接管，避免启动第二个 DHCP 客户端。
- **消除 LED 服务排序环**：将收尾服务改为排在 `multi-user.target` 之前。
- **按实现重写文档**：同步 README、架构、首启、构建、硬件与排障说明；明确首启 AP 使用 NetworkManager/wpa_supplicant、USB WAN 晚到行为和 dnsmasq systemd 顺序，并将 MT7992 的 Debian 实机状态标为待验收。
- 保持实机配置和用户指定的默认密码不变。

### 2026-10-07 — 实机 H5000M Debian 迁移适配

- **分区布局校正**：依据实机 GPT 将安装器校验的 p1–p5 起始/结束扇区改为实际值，避免合法设备被错误拒绝；分区方案文档同步记录约 14.6 GiB eMMC、p5 约 7.24 GiB、尾部未分配空间及备份 GPT 异常，保持分区表不变。
- **修复构建参数错位**：移除 chroot 参数中的多余标记，恢复 hostname、时区与密码等参数的正确传递。
- **LAN 地址保留**：按用户要求保留仓库默认管理地址 `192.168.88.1`、DHCP 地址池及原默认密码，不按实机 OpenWrt 地址改动。
- **5G 上联兼容**：为实机 MT5700M 使用的 eth2 增加 DHCP 备用 WAN，eth1 有线 WAN 保持优先；同步开放该出口的转发与 NAT。
- **迁移提示**：首次启动文档明确 OpenWrt 与 Debian 管理网段不同；电脑需获取或切换到 `192.168.88.0/24` 后才能访问 Debian WebUI。

### 2026-10-06 — 刷写与构建链安全加固

- **刷写保护**：`scripts/install-emmc.sh` 现在严格校验 H5000M 原厂 GPT 的分区标签、起始扇区及 p4/p5 大小；不匹配时拒绝执行，避免误写其他磁盘。
- **构建传输安全**：Debian mirror 默认改用 HTTPS，并拒绝 HTTP mirror；CI 下载 `debootstrap.deb` 后按 Debian 元数据中的 SHA256 校验，避免未验证的构建依赖进入固件。
- **移除远程脚本执行**：CI 不再通过 `curl | sh` 安装 Rust，改为使用系统软件包提供的 `cargo`/`rustc`。
- **构建参数安全**：`build/build-rootfs.sh` 改用安全的参数传递方式，避免 hostname、密码等参数通过 Shell 字符串插值造成命令注入或构建失败；hostname 同时增加格式校验。
- **默认凭据保持不变**：按用户要求，root/WebUI 默认密码及 Wi-Fi 默认密码未修改；刷机后仍应立即改密。

### 2026-10-06 — 首次启动自动配置审计 + 修复 grow-rootfs/LED 未 enable

**审计范围**：`linux-router/vendor`（面板 + install.sh + systemd units）、`rootfs-overlay`
（router-init/grow-rootfs/led/fancontrol、dnsmasq.d、nftables.conf、sysctl、default 配置）、
`build/build-rootfs.sh`（包列表 + enable 清单 + 凭据预置）、`build/rootfs/packages.list`。

**判定结论**：首次启动自动配置链路整体正确——`h5000m-router-init.service` 作为唯一网络编排
入口（幂等、每步故障隔离、600s 超时、Before 面板），创建 WAN(eth1 DHCP v4/v6)、br-lan
(192.168.88.1/24 + ULA)、eth0 入桥、MT7992 双 AP 桥接、reg set CN + rfkill unblock，并拉起
dnsmasq + nftables；10 个关键服务均 enable；凭据三处预置（auth.json/secret_key、
/etc/h5000m-initial-credentials、交付 initial-credentials.txt 且随 artifact/release 分发）；
nftables 单一防火墙后端并 mask networkd/resolved；包列表含 dnsmasq（提供 unit 本体）与
e2fsprogs（提供 resize2fs）。

**后续复审修正（2026-10-07）**：上面的审计遗漏了固件未从下载缓存安装进 rootfs、router-init 同步重启
受其排序约束的 dnsmasq、USB/Wi-Fi 接口晚到以及 LED unit 排序环问题；这些已记录在本文件最新条目并修复。
原审计把 600s 超时与常规执行流程混为一谈；unit 仍保留 600s 总超时上限作为保护，当前初始化不等待
无线/USB 设备，dnsmasq 则由 systemd 在 oneshot 完成后启动。

**修复 1（实质缺陷）**：`h5000m-grow-rootfs.service` 从未 enable——unit 有
`WantedBy=multi-user.target`，但覆盖层只拷 .service 不带 .wants 软链，enable 清单漏项且全仓
无 Wants/Requires 引用，导致首启 `resize2fs` 不执行，p5 引导层不扩满 ~7.2 GiB，`/overlay`
持久化空间永久锁死在镜像大小，与 `make-sd-image.sh` / `make-sysupgrade-tar.sh` 注释描述的
行为直接矛盾。已在 enable 清单补 `systemctl enable h5000m-grow-rootfs.service`（unit 自带
`ConditionPathExists=!/var/lib/h5000m-rootfs-grown`，天然只跑一次）。

**修复 2**：`h5000m-led-boot.service`（sysinit.target）与 `h5000m-led.service`
（multi-user.target）同样漏 enable，状态灯不会按设计工作。已补入 enable 清单，与清单内
已验证可行的 `h5000m-fancontrol.service`（同为 WantedBy=sysinit.target）同构。

**已知风险（用户决定保持现状，仅记录）**：`build-rootfs.sh` 默认凭据为
`ADMIN_PASSWORD=password` / `ROOT_PASSWORD=password`，CI 未传 `--admin-password` /
`--root-password`，故固件 root 与 WebUI admin 初始密码均为 `password`。用户明确选择保持，
刷机后需自行立即改密。AP 默认 SSID `OWRT` / 密码 `12345678`（CN 域，2.4G 与 5G 同名）。

### 2026-10-06 — config 片段健壮性：修复 RFKILL tristate 陷阱 + 清理无效行

- **RFKILL tristate 陷阱**：上游 `CFG80211 depends on "RFKILL || !RFKILL"`，tristate 逻辑下
  `RFKILL=m` 时该条件求值为 m，把 CFG80211 上限锁死为 m——片段的 `CFG80211=y` 被静默降级，
  连带 `MAC80211`/`MT76_CORE`/`MT7921E`/`MT7925E`/`MT7996E` 全链降级。片段 Wi-Fi 段新增
  `CONFIG_RFKILL=y` 解锁，使展开结果不再依赖「是否应用板级补丁」这一环境变量。
- **根因定位（此前归因不完整，此处补正）**：最初观察到「CI=y / 本地=m」，一度归因为上游
  Kconfig 的 tristate 逻辑。真实根因是**复现环境未按 CI 顺序打板级补丁**：纯净
  `linux-6.18.54` 的 `arch/arm64/configs/defconfig` 显式写着 `CONFIG_RFKILL=m`，而 CI 在
  `make defconfig` 之前会应用 459 个板级补丁（其中 Wi-Fi/MT 补丁把 RFKILL 收敛为 y）。
  补齐「解 tar → 打补丁 → 拷 files → defconfig → 加片段 → olddefconfig」全流程后，
  本地展开与 CI 产物**逐项一致**。
- **CI 影响量化**：run 37447911367（修复前）与 run 37453691388（修复后）的导出 config
  **零差异**（`diff` 除工具链能力符号外为空），`Image` 仅 40 字节差异且全部为构建时间戳
  （`#1 SMP Tue Oct 6 11:03:56` vs `10:40:36`），DTB 与 `kernel-mt7987-options.txt` 哈希一致。
  即该修复对 CI 真实产物为**零影响**，属防御性加固（保证换环境/换补丁集时不会静默降级），
  不影响本次实验 C 结论。`modules.tar.zst` 实测 1411 个 `.ko` 中无任何 mt76/mac80211/
  cfg80211 模块，证实 Wi-Fi 驱动确为内建（=y）而非模块。
- **清理无效行**：上游 6.18 无 `CONFIG_MT76` 符号（核心为 `MT76_CORE`，由 MT7921E/MT7996E
  的 select 链置 y），删除该无效行并留注释。
- 复现方法升级：CI 导出 config（12078 行真实展开，12079 含注释行）与本地展开全量 diff
  定位此问题；除 RFKILL 组、两轮提交差量（NR_CPUS/MINORS）、工具链能力探测符号
  （`ARCH_HAS_*`/`CC_HAS_*`/`ARM64_*`/GCC 版本，由宿主编译器决定）外无其他隐藏差量。
- **下载工具教训**：GitHub Actions artifact 的 Azure Blob 签名 URL 有效期仅 10 分钟
  （`se=` 参数），而实测单连接下载仅 ~112 KB/s（38.8 MB 需约 6 分钟）。多线程下载器
  若因分段重试跨越过期点会收到 `HTTP 403 Server failed to authenticate`。可靠做法：
  现取签名 + 立即并发 Range 分段（26 段 × 1.5 MB / 并发 16，约 4 分钟完成），
  并在拼接前逐段校验长度、总长校验通过后再 rename。

### 2026-10-06 — 实验 C 优化轮：config 基座二次对齐（NR_CPUS/MINORS）+ frank-w Debian/Ubuntu 对照补强

- **BPI-R4 Mini 对照修正**（用户纠偏）：其参考基准为 Debian/Ubuntu 发行版构建
  （frank-w/BPI-Router-Images + BPI-Router-Linux），非 OpenWrt feed。R4 Mini/R4 Lite
  （同为 MT7987A）复用 `arch/arm64/configs/mt7988a_bpi-r4_defconfig`，6.17-main 与
  6.18-main 两分支核对基线一致；论坛实跑组合为 bpi-r4lite_6.17.0-main + Debian/Ubuntu。
- **四方对照收敛**：原厂 OpenWrt 6.18.52 filogic、frank-w Debian/Ubuntu defconfig、
  我方修复后 config 三方调度器基座完全一致（PREEMPT_NONE + HZ_100 + 无 mq 调度器 +
  无 CMA）；修复前我方 config 为全部已知对照组中唯一 outlier。mmc 驱动层
  （MMC_MTK/CQHCI/HSQ）由 Kconfig select 链保证，四方一致。
- **config 二次对齐（`build/kernel-conf/h5000m-6.18.config`）**：
  - `CONFIG_NR_CPUS=4`（基座默认 512 → 对齐对照组；MT7987A 核数不超过 4，消除
    per-cpu 预分配与抢占点布局剩余差量）；
  - `CONFIG_MMC_BLOCK_MINORS=8`（基座默认 32 → 对齐对照组；p1-p5 布局下 7 分区上限
    仍充足，不触碰分区表）。
  - 云端 `defconfig → cat 片段 → olddefconfig` 展开验证：两项均生效，实验 C 首轮
    修复项（PREEMPT_NONE/HZ_100/无 mq/无 CMA）与 MMC 驱动链全部保持。
- **CI run 37413514157（零缓存全量构建，HEAD 535c7d4）conclusion=success**，
  修复后固件已产出；本条目提交后手动 dispatch 新一轮构建（缓存跨运行复用 ccache）。

### 2026-10-06 — 内核版本锁声明 + 新增清理缓存工作流（clean-cache.yml）

- **版本锁**：`KERNEL_VERSION=6.18.54` 在 `build.yml` env 与 `build-kernel.sh` 默认值均为
  固定字面量，缓存 key 全部含版本号；`build.yml` env 处补注释明确"禁止改为浮动引用，
  升版需三处同步 + CHANGELOG 记录"，保障差异分析依赖的版本确定性。
- **新增 `.github/workflows/clean-cache.yml`**：手动触发的缓存清理工作流，删除本仓库全部
  Actions 缓存（ccache/kernel-tar/apt-debs/cargo），`confirm=clean` 防误触。清完缓存后
  再手动 Run build.yml 即为完全从零的无缓存全量构建——用于排除 ccache 旧对象干扰实验
  C 修复验证。

### 2026-10-06 — 实验 C：msdc 写挂死差异分析 + 内核 config 对齐对照组 + config 导出失真修复

**分析结论（实验 C）**：对比三方（我方 6.18.54 真实展开 config / ImmortalWrt master filogic 6.18.52 / ctr54188 h5000m-debian 6.12.103 BSP 真实 config）：

1. **config 导出失真（工具链 bug，本次修复）**：`build/build-kernel.sh` 导出的
   `kernel-config-exported.config` 是输入片段（269 行）的 `cp` 拷贝而非内核真实生成的
   `.config`（olddefconfig 展开后约 4784 符号），导致 artifact 中的 config 一直无法用于
   排查。已改为导出 `$KERNEL_SRC/.config`。
2. **HSQ/CQHCI 假说排除**：上游 Kconfig `MMC_MTK` 强制 `select MMC_CQHCI + MMC_HSQ`，
   本地复现 `defconfig → cat 片段 → olddefconfig` 证实真实构建里 `CONFIG_MMC_HSQ=y`、
   `CONFIG_MMC_CQHCI=y`，与 ImmortalWrt 完全一致（此前串口无 HSQ 打印属打印文案出处差异，
   非功能缺失）。
3. **驱动/补丁层排除**：mtk-sd.c 与 mmc_hsq.c 在 6.18.52→6.18.54 间零变更；ImmortalWrt
   generic/mediatek 6.18 补丁集中无触碰 mtk-sd 写路径的补丁；6.18.53 的 mmc core 变更
   （单块写恢复/日期解码/erase 怪癖）与 kernel/dma 变更均为无害修复；双方 DTB mmc 节点逐字节一致。
4. **真实差异收敛到 defconfig 基座**：我方真实展开 config 与两个可运行对照组（原厂
   OpenWrt、h5000m-debian）在写路径行为相关维度全面相左：
   - 调度：我方 `PREEMPT=y + PREEMPT_RCU=y`，对照均为 `PREEMPT_NONE=y`；
   - 时钟粒度：我方 `HZ=1000`，对照均为 `HZ=100`；
   - IO 调度器：我方 `MQ_IOSCHED_DEADLINE=y + MQ_IOSCHED_KYBER=y`（实际 mq-deadline），对照均显式关闭（blk-mq none）；
   - 内存：我方 `DMA_CMA=y`（被 defconfig 的 DRM_ETNAVIV select，MT7987 无此硬件）；
   - 其余（NR_CPUS=512、MMC_BLOCK_MINORS=32、IOMMU/SUSPEND/CGROUP_WRITEBACK 开）为
     defconfig 全家桶，无直接写路径影响（`BLK_DEV_INTEGRITY` 被 SCSI target/hisi_sas
     强制 select，但 eMMC 不注册 integrity profile，无功能影响，接受）。

**修复**（`build/kernel-conf/h5000m-6.18.config`，对齐对照组最小差异集）：
- `CONFIG_PREEMPT=y` → `CONFIG_PREEMPT_NONE=y` + `# CONFIG_PREEMPT is not set`；
- `CONFIG_HZ_1000=y` → `CONFIG_HZ_100=y` + `# CONFIG_HZ_1000 is not set`；
- 新增 `# CONFIG_MQ_IOSCHED_DEADLINE is not set`、`# CONFIG_MQ_IOSCHED_KYBER is not set`；
- 新增 `# CONFIG_DRM_ETNAVIV is not set`、`# CONFIG_DMA_CMA is not set`（去除无意义 CMA 预留）；
- 修复已在云端沙盒 `make ARCH=arm64 olddefconfig` 复现验证：修改项全部生效，
  `MMC_MTK/CQHCI/HSQ`、WWAN/T7XX/PPPOE/SQUASHFS/OVERLAY 等全部关键符号不受影响。

**验证状态**：待 CI 构建新固件 → U-Boot Web failsafe 刷入 → 串口观察过 t=60s 无
msdc 超时。若仍复现，下一步在实机开启 `CONFIG_MMC_DEBUG`/动态调试抓 cmd25 超时前的
DMA 描述符状态，并评估把 config 基线整体切换为 ImmortalWrt filogic config。

### 2026-10-06 — FIT 打包时 fdtput 覆写内嵌 bootargs（补 rw + console，参考 ctr54188/h5000m-debian）

**发现（r31 产物二进制实锤）**：OpenWrt 构建的 DTB 在 `/chosen` 内嵌了 bootargs——
`earlycon=uart8250,mmio32,0x11000000 \t\t\t    root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf`，
与实机串口 cmdline 逐字符一致（含制表符）。即：cmdline 来源是 DTB 内嵌值（或与之相同的
厂商 env），`setenv bootargs` 未必可控，且原值**缺 `rw`**（p5 ro 挂载根源）也**缺
`console=ttyS0,115200n8`**（earlycon 交接后串口无输出、无法登录排查）。

**修复**（`build/make-sd-image.sh`，与参考仓库同思路）：
- 新增 `FIT_BOOTARGS` 配置（默认 `console=ttyS0,115200n8 earlycon=... root=PARTLABEL=rootfs rootwait rw pci=pcie_bus_perf`）；
- FIT 打包时 `fdtput -t s` 覆写 DTB `/chosen/bootargs`，并 `fdtget` 回读校验，不一致即 die；
- 工具检测加入 `fdtput`/`fdtget`；
- init 内 `remount,rw` 兜底保留（防 U-Boot env 覆写 fdt chosen 的未知行为，双保险）。

### 2026-10-06 — 实机第三阶段修复：cmdline 缺 rw 导致 overlay 组装失败 + 救援循环 OOM panic

**进展**：busybox 修复重刷后（上一条目），实机串口确认 init 已正常执行——但 overlay 组装失败，
陷入救援循环约 437 轮后 t=128s OOM panic：`Kernel panic - not syncing: System is deadlocked on memory`。

**根因（串口实锤）**：厂商 U-Boot env 默认 bootargs 不含 `rw`——实测 cmdline 为
`Kernel command line: earlycon=... root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf`，
内核把 p5（引导层 ext4）以 **ro** 挂载（`VFS: Mounted root (ext4 filesystem) readonly`）→
`/overlay/upper` 不可写 → `overlay: filesystem on /overlay/upper is read-only` →
overlay mount EINVAL（Invalid argument）。

**OOM 机理**：旧 `overlay_fail()` 救援失败后无条件重执行 `/sbin/init` → 无限循环；每轮
挂载 SquashFS 泄漏不可回收 slab（`kmalloc-4k` 达 476648KB ≈ 465MiB，loop 设备一路涨到
loop437），1GiB DRAM 耗尽 → busybox 被 oom-kill → init（PID1）再触发 OOM → panic 挂死。

**修复**（`build/make-sd-image.sh` 引导层 /sbin/init + `boot/boot.cmd`）：
- init 挂载 p5 后显式 `mount -o remount,rw /`（三重变体兜底，幂等）——治本：无论
  cmdline 是否带 rw 都能保证 overlay 可写层可用；
- 救援路径加 devtmpfs 计数器（`/dev/.h5000m_rescue_count`，root 只读时也可写），
  限自动重试 3 次；超限降级为**串口应急 shell**（/dev/console 交互，可手动修复），
  彻底消灭无限重执行 OOM 循环；
- 每次重试前 `umount /rmerged /sq` + `losetup -D`，减缓 loop/squashfs 缓存泄漏；
- `boot.cmd` 备用引导路径 bootargs 补 `rw`（与 init 内 remount 双保险）。

**验证状态**：shell 语法校验通过；待 CI 重建 → 重刷 p4+p5 → 实机串口验证（预期：
remount 成功 → overlay 组装成功 → pivot_root → systemd 正常启动）。

### 2026-10-06 — 实机第二阶段修复：busybox 误选 16 字节文本导致 init ENOEXEC panic

**进展**：FIT load/entry 改 0x46000000 后（上一条目），实机串口确认 U-Boot 阶段完全修复——
`Uncompressing Kernel Image to 46000000` → `Starting kernel ...` → Linux 6.18.54 正常启动 →
`VFS: Mounted root (ext4 filesystem) readonly on device 179:5`。

**新故障**：`Starting init: /sbin/init exists but couldn't execute it (error -8)`
（ENOEXEC）→ /etc/init、/bin/init、/bin/sh 依次失败 → `Kernel panic - not syncing:
No working init found`。

**根因（产物验尸 + 云服务器复现 + CI 日志三重实锤）**：Debian trixie
`busybox-static_1.37.0-6+b9_arm64.deb` 内有两个同名文件：
- `usr/bin/busybox`：真身，arm64 静态 ELF 1,975,064 B（魔数 7f454c46 / e_machine 0xB7）；
- `usr/share/initramfs-tools/conf-hooks.d/busybox`：**16 字节文本** `BUSYBOXDIR=/bin`。

`make-sd-image.sh` 用 `find -name busybox` 取第一个命中（遍历顺序不保证），CI 上命中
后者，把 16 字节文本装进引导层 `/usr/bin/busybox`；`/sbin/init`（busybox 脚本）的
shebang 指向它 → exec 失败 ENOEXEC → panic。CI 日志自证：`busybox：16 字节（静态 arm64）`。

**修复**（`build/make-sd-image.sh`）：
- 新增 `bb_is_valid()`：ELF 魔数 `7f454c46` + 体积 ≥512000B；
- 候选选取改为遍历全部同名文件并逐个校验（`mapfile` + 循环，弃用"第一个命中"）；
- 缓存命中同样过校验，坏缓存自动删除重下；
- 装入引导层前对最终 busybox 二进制做终检，失败即 die（带根因说明）。

**验证**：云服务器 193.112.22.19 复现 deb 解包，确认 `usr/bin/busybox`（1.97MiB，AArch64）
与 conf-hooks.d 文本文件并存；修复后筛选逻辑必选中前者。

### 2026-10-06 — 实机串口定位「Unable to allocate memory 0x40000000 for loading OS」：FIT load/entry 改 0x46000000

**根因（串口日志 + bootloader 源码双重实锤）**：实机冷启动两次复现同一失败——FIT 哈希校验
通过、`Uncompressing Kernel Image to 40000000` 后报
`Unable to allocate memory 0x40000000 for loading OS`，随即回退 Web failsafe，内核从未执行。
板上 U-Boot（bl-mt798x `uboot-mtk-20250711`，`mt7987_airpi_h5000m_defconfig`）：
`CONFIG_TEXT_BASE=0x41e00000` 且 `CONFIG_POSITION_INDEPENDENT=y`，自身常驻 0x41e00000；
`bootm_load_os()` 解压完成后按**解压后尺寸**调用 `lmb_alloc_mem(LMB_MEM_ALLOC_ADDR)`
（`boot/bootm.c:714-725`），要求 `[0x40000000, 0x40000000+Size)` 整段空闲——窗口仅 **30 MiB**。
官方 OpenWrt 内核解压后 15,194,120 B（14.5 MiB，p4 LZMA 头解析 + 实机 `/proc/iomem`
`Kernel code 0x40000000-0x40c9ffff` 证实）可放入；本方案内核解压后 35~45 MiB 必越界。
对照仓库 ctr54188/h5000m-debian 同用 0x40000000 能启动，正是靠未压缩小内核留在窗口内。
`CONFIG_SYS_BOOTM_LEN=0x6000000`（96 MiB）为解压上限，未触发，排除。

**修复**：
- `build/make-sd-image.sh`：`FIT_LOAD_ADDR` 0x40000000 → **0x46000000**（2MB 对齐、
  远离 U-Boot 自身区与 FIT 暂存区 0x60000000，空间充足），附根因注释；
- `boot/boot.cmd`：`kernel_addr_r`（FIT 暂存地址）0x46000000 → **0x60000000**——暂存地址
  不得与 FIT 内部 load 地址重合，否则 bootm 解压自重叠（BOOTM_ERR_OVERLAP）；
- `docs/troubleshooting.md` / `docs/first-boot.md`：手动引导 FIT 暂存地址同步改 0x60000000；
- `docs/debian13-partition-plan.md` / `README.md`：load 地址结论与根因说明同步修正。

**刷写通道口径（保持不变并明确）**：保留原厂 BL2/FIP/GPT，仅替换 kernel（p4）、rootfs（p5）
两分区内容——`sysupgrade tar`（CONTROL/kernel/root，与官方同构，U-Boot 网页/运行中
sysupgrade 均可直刷）或 `scripts/install-emmc.sh`（全新刷写/在线升级）两条通道皆然。

### 2026-10-06 — 实机无法启动根因修复（QEMU 虚拟机全链路验收 + 4 项致命缺陷）

背景：用户反馈「之前老产物刷入实机无法正常启动」。本轮在沙箱内搭建 **QEMU ARM64 虚拟机**
（`-machine virt`，引导层 ext4 当 virtio-blk 磁盘，GPT 分区标签 `PARTLABEL=rootfs` 与真机一致）
对固件做端到端启动验证，逐层逼出并修复了 4 项会导致启动失败的缺陷。

#### 🔴 缺陷 1：`/sbin/init` 在 `pivot_root` 后引用失效 —— **直接导致 kernel panic（主凶）**

- **现象**：`/sbin/init: exec: line 40: /usr/bin/busybox: not found`
  → `Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00`
- **根因**：`pivot_root` 之后当前根目录已切换为 OverlayFS 合并视图，而 `busybox` **只存在于
  引导层 ext4**（此刻被移动到 `/tmpold` 下）。init 脚本此后仍用相对新根的路径 `/usr/bin/busybox`
  调用 busybox，导致全部后续调用（含 `mount --move` 与最终 `exec`）失败，init 退出引发 panic。
- **修复**：`pivot_root` 后立即切换引用 `BB=/tmpold/usr/bin/busybox`（主流程与只读救援分支均已修，
  救援分支在 pivot 失败时用 `-x /tmpold/usr/bin/busybox` 判断是否回落原路径）。
- 位置：`build/make-sd-image.sh` 引导层 init heredoc，已附「切勿删除」注释说明复现场景。

#### 🔴 缺陷 2：引导层空闲空间仅 2.8 MiB —— systemd 冷启动必然 ENOSPC

- **根因**：启动时序为「内核挂 p5 引导层 → /sbin/init 组装 OverlayFS → pivot_root → systemd →
  `h5000m-grow-rootfs.service` 才执行 `resize2fs` 扩到分区实际大小」。即 **resize2fs 发生得太晚**，
  systemd 冷启动阶段 OverlayFS 的 upper/work 只能落在引导层镜像内部。
- **实测**：`EXTRA_MB=24` 时引导层 152 MiB，**空闲仅 2.8 MiB**（journal + 5% root 预留吃掉大半），
  内核报 `overlayfs: failed to create directory /overlay/work/work (errno: 28)` 并降级只读挂载
  → `pivot_root` 失败 → 起不来（QEMU 已复现，与实机现象一致）。
- **修复**：`EXTRA_MB` 默认 `24 → 128`，引导层 256 MiB、**空闲 100.2 MiB**，足以支撑到 grow-rootfs 接手。
  代价：sysupgrade 由 ~164 MiB 增至 ~268 MiB，仍在设备 `/tmp`(tmpfs) ≤600 MiB 门槛内。

#### 🔴 缺陷 3：RootFS 未安装 `resize2fs` —— grow-rootfs 服务形同虚设

- **根因**：`h5000m-grow-rootfs` 用 `command -v resize2fs` 判断后才执行（降级写得很稳妥），
  但 RootFS 从未安装 `e2fsprogs`，因此**历史上扩容从未真正发生过**，p5 的 7.2 GiB 始终没被利用。
- **修复**：从 Debian trixie 提取 `e2fsprogs` + `libext2fs2t64`（含 `libext2fs.so.2` / `libe2p.so.2`）
  植入 RootFS 树；`qemu-aarch64-static` 实测 `resize2fs 1.47.2` 可在 arm64 树上正常运行。

#### 🔴 缺陷 4：RootFS 树带着旧架构的 `/etc/fstab` 实体挂载项

- **根因**：现有树是先于新 `rootfs-overlay/` 打出的，`/etc/fstab` 仍含
  `PARTLABEL=rootfs / ext4 errors=remount-ro 0 1`，会让 systemd 把引导层重新挂回 `/` 覆盖 OverlayFS 根；
  同时缺 `usr/local/sbin/h5000m-grow-rootfs` 与 `h5000m-grow-rootfs.service`。
- **修复**：重新应用 `rootfs-overlay/`（fstab 变为纯注释布局说明），grow-rootfs 及 service 就位。

#### 🐛 附带修复：`build/make-sd-image.sh` 的 SIGPIPE 陷阱

- busybox 下载步骤原为 `curl | xz -d | awk '/^Package: busybox-static$/{…exit}'`，
  awk 命中即 `exit` 会让上游 `curl/xz` 收到 **SIGPIPE**；本脚本 `set -Eeuo pipefail`，
  整条流水线返回非 0 并被 `set -e` 捕获 —— 表现为「日志停在『下载 busybox-static』后静默退出」，
  极易误判为网络问题。改为 curl 单独落盘 + awk 命中后清标志读完输入（不提前关闭管道）；
  `find | head -1` 同样加固为 `while read` + 进程替换。

#### ✅ QEMU 虚拟机验收结果

验证环境刻意复刻真机：GPT 分区表（`u-boot-env` / `factory` / `fip` / `kernel` / `rootfs`）、
p4 写 FIT 内核（魔数 `d00dfeed` 校验通过）、p5 写引导层 ext4（超级块 `0xef53`、卷名 `rootfs`），
由 Debian 通用 arm64 内核 6.12.111 + 自造 mini initramfs（`virtio_blk`/`loop`/`ext4`/`squashfs`/
`overlay` + `crc32c`/`crc16`）引导，`switch_root` 交棒给固件自带 `/sbin/init`，后续流程与真机完全一致。

| 验证项 | 结果 |
| --- | --- |
| `findfs PARTLABEL=rootfs` 解析引导层 | ✅ `/dev/vda5` |
| 引导层 ext4 挂载 + `switch_root` 交棒 | ✅ |
| SquashFS 挂载（busybox 自动 loop） | ✅ `loop0: detected capacity change` |
| OverlayFS 组装 + `pivot_root` | ✅ 修复后通过 |
| systemd 启动 | ✅ `Welcome to Debian GNU/Linux 13 (trixie)!`，`systemd 257.13-1~deb13u1` |
| hostname | ✅ `h5000m-debian` |
| Overlay 持久化可写 | ✅ `Populated /etc with preset unit settings` |

> 说明：`systemd-timesyncd` 因 QEMU 无 RTC/NTP 会反复失败并阻塞 graphical target，属虚拟机环境限制，
> 评审时通过内核参数 `systemd.mask=systemd-timesyncd.service` 屏蔽；**真机有 RTC 与 NTP，不受影响**。
> 同理，评审所用 Debian 通用内核把 `ext4`/`squashfs`/`overlay`/`loop`/`virtio_blk` 编为模块（`=m`）
> 因此需要 initramfs；**真机 MT7987A 内核这些均为内置（`=y`，vmlinux 内含 `T crc32c` 符号）**，无需 initramfs。

### 2026-10-06 — CI 构建失败修复：sshd_config 兜底搬出 chroot（多层引号陷阱）

- **现象**（CI run 37386212969，第 10 步「chroot 内最终配置」，2 秒内退出码 **2**）：
  ```
  /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config \
        || sed -i 1i: -c: line 36: syntax error: unexpected end of file
  ```
- **根因：多层引号陷阱**。第 10 步本体是
  `chroot "$ROOTFS_DIR" /bin/bash -e -c ' ... '` 的**单引号整串**，内部靠 `'"$VAR"'`
  注入变量。上一轮 SSH 修复在该串内写入了含**字面单引号**的语句：
  ```bash
  grep -q '^Include ...' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  ```
  这组单引号**提前闭合了外层 `-c` 的字符串**，后续内容泄漏到外层 shell，参数被撕碎 ——
  `sed` 收到分裂的 `1i` 与文件名，正好对应 CI 日志里的 `sed -i 1i`。
- **最小复现佐证**：构造裸单引号版本，报
  `sed: -e expression #1, char 2: expected \ after 'a', 'c' or 'i'`，
  与 CI 现象的参数分裂形态一致。
- **修复**：把 `sshd_config` 兜底**整体移到宿主机侧第 6 步**（直接操作 `$ROOTFS_DIR`
  前缀路径），不再进入 `chroot -c` 单引号串；chroot 内仅保留 `mkdir -p sshd_config.d`
  与写入 `90-h5000m.conf`，并在注释里明示该禁区，避免后人重蹈。
- **为何沙箱当初没发现**：上一轮为省 debootstrap 时间，直接 `rsync` 覆盖了既有的
  `out/rootfs/rootfs` 树，**从未执行 `build-rootfs.sh` 本体** —— 该代码路径只在 CI 首次运行。
  > 教训：绕过构建脚本改产物树，等于绕过了唯一的回归网。

#### 验证方式（沙箱无 binfmt_misc 的替代方案）

沙箱 `/proc/sys/fs/binfmt_misc` 未挂载，**无法真实 chroot 到 arm64**
（实测 `chroot: failed to run command '/bin/bash': Exec format error`）。
改用 **mock chroot 拦截 `-c` 参数**，取得真实投递给 bash 的脚本文本：

| 验证项 | 结果 |
| --- | --- |
| 三处 `chroot -c` 脚本（`bash -n`） | ✅ 全部通过 |
| `build-rootfs.sh` 全流程实跑 | ✅ `exit=0`，走到第 11 步打包完成 |
| 第 10 步脚本语义完整性 | ✅ hostname / localtime / chpasswd / sshd_config.d / 90-h5000m / Linux-Router 均在 |
| 第 6 步兜底实际生效 | ✅ 日志 `sshd_config 主配置就位` |

### 2026-10-06 — QEMU 虚拟机「服务级」验收：再挖 4 项缺陷（SSH 完全不可用为最致命）

背景：上一轮已让系统**能启动**（`Welcome to Debian GNU/Linux 13`），但仅是「活着」。
本轮对启动后的服务做逐项体检（`systemctl --failed` + `journalctl` 定向归因），
又挖出 4 项缺陷 —— 其中 **SSH 完全起不来**对 headless 路由器等于「刷完变砖」，危害高于上一轮的主凶。

#### 🔴 缺陷 5：`/etc/ssh/sshd_config` 从未生成 —— **SSH 完全不可用（本轮最致命）**

- **现象**（虚拟机内真实日志）：
  ```
  sshd[521]: /etc/ssh/sshd_config: No such file or directory
  ssh.service: Control process exited, code=exited, status=1/FAILURE
  ssh.service: Start request repeated too quickly
  ssh.socket: Failed with result 'service-start-limit-hit'
  ```
- **根因**：OpenSSH ≥ 9.9 / Debian 13 起，`sshd_config` **不再是 dpkg conffile**。
  官方模板存放在 `/usr/share/openssh/sshd_config`，改由包 postinst 经 **ucf** 复制到 `/etc/ssh/`。
  本仓库的 RootFS 由 `debootstrap` + chroot 构建，该 ucf 环节不会执行 → 主配置永久缺失。
  连锁后果：`build-rootfs.sh` 写入的 `/etc/ssh/sshd_config.d/90-h5000m.conf`（`PermitRootLogin yes`）
  依赖主配置中的 `Include` 才能生效，主配置不在 → **连认证放宽策略一并失效**。
- **修复**：① 在 `rootfs-overlay/etc/ssh/sshd_config` 显式提供确定性主配置（保留
  `Include /etc/ssh/sshd_config.d/*.conf` 置于文首，确保 `.d` 片段优先）；
  ② `build-rootfs.sh` 增加兜底：若主配置仍缺失则用 openssh 官方模板顶上并补齐 `Include`。
- **为何不依赖 postinst**：确定性构建不应依赖 maintainer script 的副作用 —— 这正是本次翻车的原因。

#### 🔴 缺陷 6：`h5000m-led.sh` 缺可执行位 → systemd `status=203/EXEC`

- **现象**：`h5000m-led-boot.service: Main process exited, code=exited, status=203/EXEC`
- **根因**：`build-rootfs.sh` 的 rsync 带 `--chmod=Fu=rw,Fg=r,Fo=r`，会把覆盖层每个文件**强制剥成
  644**；而 git 对 rootfs-overlay 记录的文件模式**全部是 100644**。原实现靠一段
  **硬编码白名单**逐个 `chmod 0755`（列了 router-init / fancontrol / grow-rootfs / wan-dns 四个），
  **唯独漏了 `h5000m-led.sh`**。
- **隐蔽之处**：`bash -n` 语法检查**不读执行位**，所以「脚本语法验收」全绿也发现不了它。
- **修复**：删除白名单，改为**按内容扫描** —— 凡带 `#!` shebang 的脚本一律 0755，
  并在构建末尾做幂等自检（残留「有 shebang 却无 x」即告警）。
  数据文件（如 `sshd_config`）首行是 `# ` 而非 `#!`，不受影响，保持 0644。

#### 🟡 缺陷 7：LED 脚本在无 LED 硬件环境下返回非 0

- **根因**：`led_set()` 以 `[ -f ... ] && echo ...` 结尾，属性不存在时函数返回 1，
  逐层冒泡令 systemd 判定 failed。场景：非 H5000M 硬件 / 虚拟化环境 / DTS 未导出 `aliases`。
- **修复**：新增 `resolve_led()` 解析封装，解析不到就跳过并 `return 0`；`led_set()` 显式 `return 0`
  切断冒泡；脚本末尾再兜一道 `exit 0`。LED 属装饰性动作，不得让调用方判定失败。

#### 🟡 缺陷 8：`h5000m-router-init.service` 超时阈值过紧（180 s → 600 s）

- **现象**：`unit=h5000m-router-init ... res=failed`（被 SIGTERM 打断，非脚本报错）
- **根因**：该 oneshot 服务一次性完成「等接口 + 建 5 条 NM 连接 + 逐个 `nmcli up` +
  重启 dnsmasq/nftables」，低频 CPU / 慢速存储上远超 180 s。脚本本身对每个步骤只告警、
  结尾恒 `exit 0`，因此失败只可能来自超时。
- **修复**：`TimeoutStartSec=600`。

#### 🐛 附带：e2fsprogs 未进packages.list（可复现性缺口）

上一轮把 `resize2fs` 直接补进了 `out/` 产物树，但没写进 `build/rootfs/packages.list` ——
**重新构建就会丢失、扩容能力再次失效**。本次正式加入清单（`resize2fs` + `libext2fs.so.2` /
`libe2p.so.2` 随之带入）。

#### ✅ 甄别结论：nftables 失败属**验证环境限制**，非固件缺陷

| 观测 | 判定 |
| --- | --- |
| `nft[228]: src/mnl.c:64: Unable to initialize Netlink socket: Protocol not supported` | QEMU 所用 Debian 通用内核把 `nf_tables` 编为模块（`=m`），mini initramfs 未携带 → netlink family 不存在 |
| 真机 MT7987A 内核配置 | `CONFIG_NF_TABLES=y`、`CONFIG_NF_TABLES_INET=y`、`CONFIG_NFT_NAT=y` 及全套 `NETFILTER_XT_*` **均为内置** |
| **结论** | 真机可正常加载 `nftables.conf`；该失败源于验证环境缺 nf_tables 模块，**固件无需修改** |

### 2026-10-06 — CI 编译提速：ARM64 原生 runner + ccache + 下载层缓存（实测基线 117 min → 目标 ~20 min）

- **基线实测**（run 37353387707，x86_64 全链路成功跑到底）：总 117 min，其中
  **构建 Debian 13 RootFS 67.68 min（58%）**、**编译 Linux 内核 46.72 min（40%）**，
  其余所有步骤合计 < 3 min —— 结论：传统手段（拆 job / 并行上传 / 优化依赖安装）收益为零，
  必须打这两处。
- **Runner 改为 ARM64 原生**：`runs-on: ubuntu-24.04-arm`（仓库 public，GitHub 免费额度内）；
  宿主即 arm64 → RootFS debootstrap 免 qemu 二进制翻译、内核免交叉、mt5700 免交叉 linker。
  新增 `workflow_dispatch` 输入 `force_x86_runner`（布尔，默认 false）作为回退开关，
  ARM64 runner 不可用/排队时可手动切回 x86_64（交叉 + qemu 旧路径）。
- **native / foreign 自动判定（`build/build-rootfs.sh`）**：宿主 aarch64/arm64 且目标 arm64 →
  `debootstrap` 一次完成；否则保持 `--foreign` + `qemu-aarch64-static` 第二阶段。
  依赖检查随之调整（qemu 仅 foreign 模式必需）；新增 `--apt-cache-dir`（下载层缓存）；
  `apt-get clean` 从 chroot 内移到回存 .deb 之后执行，保证新下载的包能回存缓存。
- **内核编译提速（`build/build-kernel.sh`）**：新增编译模式判定（native / cross，
  支持 `--native`/`--cross` 强制覆盖）；检测到 ccache 自动启用（支持 `--no-ccache`），
  make 传 `CC="ccache <prefix>gcc" HOSTCC="ccache gcc"`，构建结束打印 ccache 统计；
  `--jobs` 不再被 workflow 固定为 4（默认 `nproc`）；`modules.tar.zst` 由单线程
  `tar --zstd` 改为 `tar -cf - lib | zstd -T0` 多线程。
- **mt5700（`build/build-mt5700.sh`）**：宿主即 arm64 时不设 rustup target、不指定交叉 linker
  （native 目标）；引入 `CARGO_TARGET_ARGS` / `CARGO_LINKER` 并改为显式分支，
  避免依赖 bash 空数组展开；PROVENANCE.txt 的 target 字段在 native 时显示 `host-native`。
- **SquashFS 瘦身副本 `cp -a` → `cp -al`（硬链接）**：零数据拷贝、秒级完成，同时省去数百 MiB
  读写与临时空间；跨文件系统时自动回退 `cp -a`。已核实 `slim_tree` 的清理动作全为 `rm -rf`
  （仅解除本副本链接），不会穿透修改原 RootFS 树。
- **CI 缓存**（全部为**下载层**，不缓存构建产物，结果等同无缓存构建）：
  ccache（key = 内核版本 + hash(patches/dts/kernel-conf/build-kernel.sh) + runner.arch）、
  Debian `.deb` 归档（key = packages.list hash）、cargo registry；
  `debootstrap --cache-dir` 复用下载包；新增 `debootstrap` 支持 trixie 预检（runner 自带
  版本不含 trixie 脚本时自动装 Debian 上游 debootstrap）；两个 job 的 timeout 相应下调
  （内核 330→240 min、镜像 180→150 min）。
- **验证**：四个脚本 `bash -n` 通过；内核源码树实测 ccache 冷/热编译正常（二次出现命中）；
  硬链接语义实测通过（副本删除不穿透原树、符号链接保留、副本近零占用）；
  workflow 经 YAML 解析与 **actionlint 静态检查均无告警**。
- **文档**：README「云编译」段落修正（workflow 实为纯手动触发，并补充提速说明）；
  `docs/build-guide.md` 新增 §3.7.1 提速设计（实测基线表 + 关键实现）与 §3.7.2 缓存观察；
  `docs/troubleshooting.md` 新增 §12 云编译排查表（runner 排队/回退/foreign 误判/ccache 0 命中等）。

### 2026-10-06 — 文档同步至 SquashFS+OverlayFS 架构 + 一键构建链路修复

- **scripts/build.sh 链路修复**（全链改造时遗漏的一键入口）：第 2 步 `build-rootfs.sh`
  加 `--skip-tar`（SquashFS 直接消费树）；新增第 2.5 步调用 `make-squashfs.sh`；
  第 3 步 `make-sd-image.sh` 改传 `--squashfs`（旧 `--rootfs tar.zst` 参数已不存在，
  原链路会直接报"未知参数"）；`--skip-rootfs` 校验改为 RootFS 树存在性；
  产物列表补 `rootfs.squashfs` / 两个 .bin。`bash -n` 语法通过。
- **README.md**：新增"系统架构（SquashFS + OverlayFS）"章节（p5 引导层语义 / 164 MiB
  收益 / 在线升级）；构建命令补 make-squashfs 步骤；Releases 产物更新为
  sysupgrade.bin（≈164 MiB）/ kernel.bin / rootfs.bin / rootfs.squashfs（移除
  tar.zst 与 .bin.zst 解压指引）；首次启动改为"全新刷写 + 在线升级"双命令示例；
  目录结构补 `make-squashfs.sh` 与 `h5000m-grow-rootfs`；验收标准补持久化/可升级条目。
- **docs/architecture.md**：系统总览插入引导层/OverlayFS 层级；新增 §2 存储架构
  （p5 布局、/sbin/init 启动序列、关键保证表、体积收益表）；服务启动顺序补
  init 前置阶段与 h5000m-grow-rootfs；故障矩阵补"OverlayFS 组装失败 → 只读救援模式"行。
- **docs/build-guide.md**：产物清单重写（RootFS 树 + rootfs.squashfs + 引导层镜像 +
  sysupgrade）；依赖补 squashfs-tools；新增 §3.3 SquashFS 章节（瘦身/压缩参数/自检）；
  §3.4 刷写包重写（--squashfs 参数、引导层内容详解、尺寸公式、resize2fs 扩容语义）；
  §3.6 eMMC 刷入改三方法（引导层镜像 / tar.zst 兼容模式 / --rootfs-squashfs 在线升级
  含 .bak 回退）；§3.7 CI 描述更新；验证清单改 SquashFS/引导层逐项检查。
- **docs/first-boot.md**：三方法刷写 + 启动流程插入 /sbin/init 序列（overlay 组装 /
  pivot_root / 救援模式 / grow-rootfs）；验证命令改 overlay 视角（findmnt / 为 overlay、
  /sq 为 squashfs ro）；USB 试运行补引导层 dd 说明（tar 解压 = 兼容模式）。
- **docs/debian13-partition-plan.md**：p5 全文档语义更新为"引导层 ext4"；§6 存放位置
  拆只读基础系统/可写层/引导脚本三行；§9 fstab 同步为布局说明注释（无运行时挂载项）；
  §14 验证补 debugfs 引导层检查与 overlay 启动验证；§15 构建流程补 make-squashfs。
- **docs/troubleshooting.md**：新增 §4「SquashFS / OverlayFS / 只读根」七类故障
  （救援模式进入、根只读、overlay 空间不足、配置丢失、在线升级失败/回退、squashfs
  魔数）；§10 eMMC 固化补在线升级命令；§11 重启恢复补 overlay 检查项。
- **docs/hardware.md**：核对无需改动（无旧架构描述）。

### 2026-10-06 — 固件架构重构：Debian RootFS → SquashFS 只读根 + OverlayFS 持久层（sysupgrade 579 → 164 MiB）

- **背景与目标**：sysupgrade 整包需上传到设备 /tmp（tmpfs 占 RAM）；旧 ext4 固定尺寸镜像
  （540 MiB，更早 1.15 GiB）把空闲空间也封进固件导致 /tmp 放不下。本次从整条构建链改造为
  「Debian 13 Minimal RootFS → SquashFS → OverlayFS 可写层 → H5000M 固件」，同时保持
  BL2 / U-Boot / FIP / u-boot-env / factory / GPT 分区布局与现有启动链 **零改动**。
- **新布局（p5 引导层 ext4，取代整分区 ext4 Debian）**：
  - `/sbin/init`（busybox 引导脚本）：挂 `/squashfs/rootfs.squashfs`（只读）→ 组装
    OverlayFS（lower=/sq，upper/work=p5 引导层 `/overlay`）→ `pivot_root`（旧根保留于
    `/tmpold`，运行期可直接访问 SquashFS 文件）→ 交棒 systemd；
  - OverlayFS 组装失败时进入**只读救援模式**（squashfs 根 + tmpfs，可 SSH 修复，防砖）；
  - `/etc` `/var` `/opt` 等全部写入经 overlay 落在 p5，重启持久保留。
- **构建链改动**：
  1. 新增 `build/make-squashfs.sh`：RootFS 树 → 副本瘦身（apt lists/doc/man/info/locale/日志）
     → `mksquashfs`（默认 zstd -19 -b 256K，`--comp xz` 可选）→ 自检（超块格式 + 抽样 cmp）。
     沙箱实测 514 MiB 树 → zstd **119 MiB** / xz 106 MiB（选 zstd：解压快 5-10 倍，A53 首启友好）；
  2. 重写 `build/make-sd-image.sh`：p5 产物改为引导层 ext4（init + busybox + SquashFS +
     overlay 目录 + /boot 兜底），`mkfs.ext4 -d` 免挂载构建 + e2fsck + debugfs 三重自检；
     busybox-static arm64 自动从 Debian mirror 下载（本地缓存，`--busybox` 可指定）；
  3. `build/build-rootfs.sh`：新增 `--skip-tar`（SquashFS 直接消费树，CI 跳过 tar.zst）；
  4. `build/make-sysupgrade-tar.sh`：root 成员语义更新为引导层镜像，600 MiB 门槛保留；
  5. `scripts/install-emmc.sh`：新增 **`--rootfs-squashfs` 运行中在线升级模式**——仅原子替换
     p5 上的 SquashFS 文件 + 刷新 p4 FIT，overlay 持久化数据全部保留，旧版自动备份
     `rootfs.squashfs.bak`（mv 回即回退）；
  6. 内核 config：`CONFIG_SQUASHFS_ZSTD=y`（XZ/OverlayFS/DEVTMPFS_MOUNT 原已就绪），
     沙箱增量编译 `zstd_wrapper.o` 通过；
  7. workflow：串联 make-squashfs 步骤、依赖加 squashfs-tools、Release 产物
     （sysupgrade + kernel.bin + rootfs.bin + rootfs.squashfs，移除 tar.zst）、
     **新增产物 chown 步骤**（修复旧 run 37353387707 的 upload-artifact EACCES：
     sudo 构建产物为 root 属主，runner 读不了 initial-credentials.txt）。
- **产物体积（沙箱全链实跑）**：kernel FIT 12.4 MiB + 引导层 152 MiB → **sysupgrade.bin
  164 MiB**（v2 slim ext4 579 MiB → 缩小 72%；v1 1.15 GiB → 缩小 86%）；
  设备 /tmp 占用 164 MiB ≪ 600 MiB 约束。字节级闭环校验：sysupgrade 解包 → CONTROL/
  kernel/root 成员 → 引导层内 init/busybox/squashfs 大小全部一致。
- **沙箱验证**：① mksquashfs zstd 超块 + 抽样文件 cmp 一致；② 引导层镜像 e2fsck clean；
  ③ busybox applet（pivot_root/mount/env）核对；④ 两段式真机等价 pivot 序列（引导层成根 →
  pivot 进 merged → `/tmpold/squashfs` 在线升级路径可见）+ chroot(qemu) 执行 arm64 /bin/echo
  全链通过；⑤ overlay 真实挂载与重启持久化端到端列为真机首启验证项（容器无 overlay 挂载权限）。
- **功能兼容**：packages.list 全量保留（NetworkManager / dnsmasq / nftables / hostapd /
  Wi-Fi / Modem / Linux-Router / WebUI / systemd）；fstab 改为布局说明（root 由引导层处理）；
  `h5000m-grow-rootfs` 服务迁入 rootfs-overlay（改用 `findfs PARTLABEL=rootfs` 在线扩容
  p5 引导层至 ~7.2 GiB，作为 overlay 持久层）。

### 2026-10-06 — MT7987 以太网修复：内核 IRQ 三缺陷 + DTS 八中断/板级 MAC（参考 ctr54188/h5000m-debian 真机逆向）

- **来源**：参考仓库 `ctr54188/h5000m-debian`（同型号设备，作者对厂商出货内核 6.6.94 做了
  真机逆向，见其 `docs/ETHERNET-TX-NOTES.md`——kallsyms + 反汇编 + live.dtb 交叉验证）。
- **内核修复（新增 `kernel/patches/997-net-ethernet-mtk_eth_soc-mt7987-eth-irq-fixes.patch`，
  在 750/751 mt7987 支持补丁之上叠加，已适配 6.18.54 枚举与函数名）**：
  1. `mt7987_data.rx.irq_done_mask` 补 `MTK_RX_DONE_INT0`（BIT(16)）——仅清 BIT(14) 会残留
     RX done 位 → **RX IRQ 风暴 + RCU stall**（厂商寄存器行为逆向结论）；
  2. FE 中断分组：MT7987（netsys v3、PPE1 类）必须写 `FE_INT_GRP = 0x210ffff2` 且
     **不触碰 `pdma.int_grp` 分组寄存器**——主线写 `0x21021000`（旧路径）与厂商不一致；
     此项参考仓库 997 补丁未包含，依据其 NOTES 反汇编证据补齐；
  3. 厂商在全部 8 条 eth IRQ 线上注册合并 handler：新增 `mtk_handle_irq_fe`
     （TX+RX 合并处理，非本设备中断源返回 `IRQ_NONE` 防 IRQ 风暴），`mtk_probe` 对
     MT7987 挂满 8 线；`mtk_get_irqs` 按厂商布局填 TX=资源1 / RX=资源2。
- **DTS 修复（`dts/mt7987.dtsi` + `dts/mt7987a-hiveton-h5000m.dts`）**：
  1. eth 节点中断 4 → **8 条**（189/190/191/192 + 196/197/198/199，与厂商 DTB 一致；
     不加 interrupt-names，同厂商 DTB 行为，8 条 IRQ 由 997 补丁按资源序注册）；
  2. gmac2 补 `phy-mode = "internal"` + `fixed-link`（1G 全双工，与已验证厂商 DTB 一致；
     属性顺序已按 dtc 规范置于子节点之前——参考仓库原补丁顺序会被新版 dtc 拒绝）；
  3. 板级 gmac0/gmac1 补 `mac-address`（`0e:c7:2f:5b:6a:84/85`，本地管理地址，来源为
     参考作者真机厂商 DTB；同型号出厂同值，如有独占地址需求可自行修改）；
  4. pcie1 `disabled → okay`（与已验证厂商 DTB 一致，空槽无副作用）。
- **验证**：① 补丁经 `patch -p1 --dry-run` 与 `git apply --check` 双重回放通过；
  ② 沙箱 6.18.54 构建树增量编译 `mtk_eth_soc.o` 通过（gcc 无警告错误）；
  ③ DTS 经 cpp+dtc 编译为 DTB 成功，反解确认 8 条中断值、双 MAC、fixed-link 均已生效。
- **遗留提醒**：本仓库 Wi-Fi（MT7992 hostapd AP）与有线 HNAT flowtable 卸载为参考仓库已
  实现、本仓库未覆盖的功能面，后续按需引入。

### 2026-10-06 — 产出优化：sysupgrade 单文件 + 瘦身（≤600 MiB 内存约束）+ 触发改纯手动

- **背景**：沙箱实测验证（对照参考镜像 `H5000M-.-sysupgrade.bin` 解剖）：
  ① 官方 sysupgrade.bin 为 sysupgrade-tar 格式（CONTROL + kernel FIT + root），sysupgrade 解包后 dd 写 p4/p5；
  ② sysupgrade 会把整包上传到设备 /tmp（tmpfs 占 RAM），此前 1.15 GiB 产出超出设备内存无法刷入，
     约束定为 ≤600 MiB（实测 579 MiB 交付验证通过）。
- **make-sd-image.sh**（默认行为变更）：
  - 新增瘦身模式（默认开启）：清理 apt lists / doc / man / info / 非中英文 locale 翻译；
    `--no-slim` 恢复全量（自动估算尺寸），`--auto-size` 恢复旧估算行为
  - 默认跳过 /boot/Image 冗余副本（p4 FIT 已含同一内核，省 60+ MiB）；`--keep-boot-image` 恢复
  - rootfs 镜像默认 540 MiB（slim 后内容 ~423 MiB，使用率 ~80%）；解压后加 92% 水位防护，
    超限立即失败并给出处置提示（避免解压中途 No space left 难排查）
  - 注入 `h5000m-grow-rootfs.service`（oneshot + marker 防重跑）：首启 resize2fs 在线扩满 p5
    （~7.2 GiB；p5 本为 GPT 全部剩余空间，不触碰分区表）
- **build/make-sysupgrade-tar.sh**（新增）：sysupgrade-tar 单文件封装（`--sort=name` 成员序
  CONTROL→kernel→root 与官方一致；uid/gid 归零、mtime 固定可复现；FIT 魔数预检 + 600 MiB
  内存约束门槛 + CONTROL/成员大小自检）；无 root 依赖，纯 tar。
- **.github/workflows/build.yml**：
  - **触发改纯手动 `workflow_dispatch`**（删除 push / pull_request / schedule）——内核编译 1~2 小时，
    每次推送自动重编几乎不变的内核纯属浪费 runner 时长；出包时 Actions 页面手动 Run 或
    `gh workflow run build.yml`
  - build-image job 新增 "封装 sysupgrade-tar 单文件固件" step；artifact 与 Release 均新增
    sysupgrade.bin（主交付，命名 `H5000M-debian13-<VERSION>-sysupgrade.bin`）
  - Release 发布简化：rootfs 540 MiB < 2 GB 单文件上限，**不再 zstd 压缩**，直接发 rootfs.bin；
    RELEASE-NOTES 重写（sysupgrade -n 推荐刷法 + 首启自动扩容 + 回退说明），
    附 initial-credentials.txt
- **验证**：make-sysupgrade-tar.sh 以沙箱 FIT + slim ext4 实跑，产物与已交付
  `H5000M-debian13-sysupgrade.bin`（579,194,880 B，SHA256 243df178…）同构；脚本全部 LF。

### 2026-10-05 — FIT 打包缺 dtc 导致 mkimage 失败（CI run 37325207380）

- **进展**：mt5700 交叉编译 step 通过（上轮 glibc 头修复生效）；RootFS 构建完成；
  失败点推进到最后的"生成刷写包"——`mkimage 打包 FIT 失败`。
- **根因**：`mkimage -f` 打包 FIT 时会**调用外部 `dtc` 二进制**编译 ITS（并非内嵌）；
  workflow 用 `--no-install-recommends` 安装 u-boot-tools 不会带入
  device-tree-compiler → ITS 编译失败。此前该代码路径从未真正执行到（上上轮死于
  自拷贝、更早轮死于其他错误），本次为首次暴露。沙箱因已装 device-tree-compiler
  1.7.0 而通过（环境差异型失败，与上轮同类）。
- **修复**：workflow apt 增加 `device-tree-compiler`（附注释说明原因）；
  make-sd-image.sh 工具检测加 `dtc`；mkimage 失败时不再吞 stderr（仅屏蔽 stdout），
  die 提示指向 dtc；`SIGN_ARGS=()` 显式空数组初始化（set -u 防御）。

### 2026-10-05 — 交叉编译环境补全：aarch64 glibc 头文件缺失（CI run 37317806045）

- **失败现象**：新 step "交叉编译 luci-app-mt5700" 中 ring 0.17.14 的 C 代码编译报
  `/usr/include/stdint.h:26:10: fatal error: bits/libc-header-start.h: No such file
  or directory`（aarch64-linux-gnu-gcc 编 curve25519.c）。
- **根因**：runner 只装了 `gcc-aarch64-linux-gnu`（编译器本体），未装 aarch64 的
  glibc 头文件包；gcc-cross 的 `stdint.h` 经 `include_next` 落到宿主 x86_64 的
  `/usr/include/stdint.h`，其 `bits/` 头不在 aarch64 搜索路径。沙箱验证时装的是
  `crossbuild-essential-arm64` 元包（含 `libc6-dev-arm64-cross`，提供
  `/usr/aarch64-linux-gnu/include`），故未复现——环境差异型失败。
- **修复**：workflow apt 依赖 `gcc-aarch64-linux-gnu` → `crossbuild-essential-arm64`
  （与 build-kernel job 一致）；build-mt5700.sh 增加前置检查——缺
  `/usr/aarch64-linux-gnu/include/bits/libc-header-start.h` 时 die 并提示安装命令，
  失败信息从 cc-rs 深处提前到脚本入口。
- 内核 job 全绿（未改动）；其余链路不变。

### 2026-10-05 — MT5700M 插件切换为 luci-app-mt5700 Debian 分支（单服务架构）+ 修复 make-sd-image.sh 自拷贝（CI run 37295444686）

**变更 A：mt5700 预装方案重写（"Release ipk + vendor 面板"双服务 → Debian 分支单服务）**

- **新架构**：luci-app-mt5700 `Debian` 分支（commit `76d1f82`）——单一 Rust 后端
  `at-webserver` 2.0.0 一体化承载 **WebUI + HTTP API + WebSocket（0.0.0.0:9000）**，
  移除 OpenWrt/LuCI/ubus/rpcd/UCI 依赖；替代原 `at-webserver-rust`(RPC :8765) +
  `mt5700-web`(面板 :8181) 双服务。
- **二进制来源**：Releases 无 Debian 分支资产（仅 OpenWrt musl ipk/apk），改为
  **CI 内交叉编译**：新增 `build/build-mt5700.sh`，浅克隆 Debian 分支并 **pin commit
  `76d1f82e5a00b6622da15ffb64d8be630073ffb2`**（可复现，升级插件时同步更新）；
  依赖链 tokio/serde/ureq(rustls)——rustls 的 ring 组件含 C/asm 代码，需目标平台
  C 编译器：默认 **aarch64-unknown-linux-gnu**（gcc-aarch64-linux-gnu，构建机
  ubuntu-24.04 glibc 2.39 ≤ Debian 13 的 2.41，向后兼容；rootfs 已含 libgcc-s1），
  musl 静态备选需自备 aarch64-linux-musl-gcc（apt 无此包）。staging 产物
  （二进制 + webui/ + debian/ 配置 + PROVENANCE.txt）经 `--mt5700-dir` 供
  build-rootfs.sh 消费。
- **安装布局**（与上游 debian/install.sh 一致）：`/usr/bin/at-webserver` +
  `/usr/share/mt5700/webui/` + `/etc/mt5700/{config.json,on-uplink.sh}` +
  `/etc/systemd/system/at-webserver.service`（SupplementaryGroups=dialout、
  ProtectSystem=strict + ReadWritePaths）。
- **清理**：删除 rootfs-overlay 的旧 `at-webserver.service`(ExecStart=at-webserver-rust)、
  `mt5700-web.service`、`etc/config/at-webserver`（UCI 残留）、
  `usr/libexec/at-webserver/on-uplink.sh`，以及整个 `build/rootfs/vendor/mt5700/`
  （面板二进制 + LuCI 静态资源 + PROVENANCE.md，约 60 文件）；systemd enable 列表
  移除 mt5700-web.service。
- **端口/防火墙**：motd 模组面板提示 8181 → 9000；nftables 无需改动（`iifname
  "br-lan" accept` 已覆盖 :9000，WAN 侧 policy drop 不变）。
- **CI**：build-image job 新增"交叉编译 luci-app-mt5700 at-webserver"step（RootFS
  构建前执行），build-rootfs.sh 调用加 `--mt5700-dir out/mt5700`。

**变更 B：make-sd-image.sh 修复（run 37295444686 "生成刷写包"失败）**

- 失败现象：`cp: '/tmp/h5000m-img.XXXX/Image.lzma' and '/tmp/h5000m-img.XXXX/Image.lzma'
  are the same file`。
- 根因：`IMAGE_LZMA="$WORK/Image.lzma"`（lzma 压缩已直接输出到该路径）后，ITS
  heredoc 之前遗留一行 `cp -f "$IMAGE_LZMA" "$WORK/Image.lzma"` 自拷贝（源=目标），
  GNU cp 报错退出。`/incbin/("Image.lzma")` 以 `cd "$WORK"` 为 cwd，文件本就在
  正确位置，该行纯冗余 → 删除（DTB 跨目录复制保留）。
- 顺手修复：`die()`/`log()` 定义移至文件入参校验之前（原 79-81 行在函数定义前
  调用 die，触发时报 command not found 而非友好错误信息）。

**本地验证**：`bash -n` 全部脚本通过；FIT 打包段 mkimage 模拟（假 Image/DTB，魔数
d0 0d fe ed 校验）通过；沙箱实测 build-mt5700.sh 完整链路（浅克隆固定 commit →
cargo 交叉编译 aarch64-gnu → staging → ELF/aarch64 自检）通过。

### 2026-10-05 — Release 的 rootfs 镜像改为 .zst 压缩发布（规避 GitHub 单文件 2 GB 上限）

- **产物变更**：Release 中 `H5000M-debian13-<版本>-rootfs.bin`（裸 ext4）替换为
  `H5000M-debian13-<版本>-rootfs.bin.zst`（zstd -12 压缩）。裸 ext4 镜像受 GitHub
  Releases 单文件 2 GB 硬限制约束，本库 rootfs 按"内容 + 512 MiB 余量"自适应估算，
  逼近或超过 2 GB 时 Release 上传会直接失败；ext4 空闲区均为 0，zstd 压缩率极高。
- **刷写流程**：下载后先 `zstd -d H5000M-debian13-<版本>-rootfs.bin.zst` 解压，
  再按原流程 `install-emmc.sh --rootfs <解压出的 .bin>` 刷写；RELEASE-NOTES 已同步。
- **不变项**：kernel.bin 仍为 FIT（内核 LZMA 压缩内嵌，U-Boot bootm 直接启动）；
  Actions Artifact 保留原始 `.bin`（artifact 无 2 GB 单文件限制），本地构建仍产出 `.bin`。
- README 的 Release 产物说明同步更新。

### 2026-10-05 — usrmerge /lib 符号链接被 tar 破坏导致 chroot 崩溃（CI run 37271056282）

**进展**：内核 job 全绿（31 项配置核验 + 全量编译 + 16 项新增配置编译通过）；
build-image 中跨 job 路径、模块校验、**mt5700 预装（首次 CI 验证通过）**均过关。

**失败点**：第 10 步 chroot 报
`aarch64-binfmt-P: Could not open '/lib/ld-linux-aarch64.so.1': No such file or directory`。

**根因**：Debian 13 为 usrmerge 布局（`/lib` 是指向 `/usr/lib` 的符号链接）。
第 9 步 `tar -xf modules.tar.zst -C "$ROOTFS_DIR"` 解压时，存档中的 `lib/` 目录条目
会让 GNU tar **删除目标上的符号链接并重建真实目录** → `/lib` 不再指向 `/usr/lib`，
aarch64 动态链接器消失，chroot 崩溃（第 3/5 步 chroot 正常、第 9 步之后立即崩溃，
佐证破坏点就在 modules 解压）。

**修复**：`build-rootfs.sh` 第 9 步改用
`tar --keep-directory-symlink -I zstd -xf ...`，跟随符号链接写入（模块落到
`/usr/lib/modules`）。本地 usrmerge 复现验证：修复前 `lib` 由符号链接变成真实目录，
修复后符号链接保留、ld.so 可用、模块落点正确。已确认脚本内解压到 `ROOTFS_DIR`
的 tar 仅此一处（其余为 rsync overlay 与最终打包，均不破坏符号链接）。

### 2026-10-05 — 844 cpufreq 补丁适配 6.18.54 + 跨 job 产物路径修复 + 参考 ctr54188/h5000m-debian 补齐配置

**内核补丁（CI run 37264647296：35 秒失败）：**

- **844-cpufreq MT7987 补丁重写**：原补丁针对含 `mt7986_platform_data` 与 `mediatek,mt7988d`
  的内核版本编写，6.18.54 两者皆无 → 两个 hunk 上下文均不匹配，`git apply` 与 `patch` 回退
  双失败，`--strict` 下内核 job 直接终止（旧 CI 靠 `--skip-failed-patches` 跳过，
  MT7987 cpufreq 从未真正启用）。现按 6.18.54 实际源码重排 hunk：插入点移至
  `mt7623_platform_data` 之后、移除不存在的 mt7988d 上下文行；语义不变
  （`proc_max_volt=1023000` + `mediatek,mt7987` DT match）
- **验证**：干净 6.18.54 树全补丁序列（backport/pending/hack/mediatek，200+）应用成功；
  aarch64 交叉编译 `mediatek-cpufreq.o` 通过，`nm` 确认 `mt7987_platform_data` 与
  `mediatek,mt7987` 编入目标文件

**CI 跨 job 产物传递（CI run 37265754864：build-image `cp: cannot stat`）：**

- **根因**：`upload-artifact@v4` 以所有上传路径的公共根为基准保留相对路径；混合上传
  `out/kernel/*` 与 `out/boot/*` 时公共根为 `out/`，artifact 内实际为 `kernel/Image`、
  `boot/boot.scr`，下载侧按扁平路径取值即失败
- **修复**：上传前集中到 `out/kernel-artifacts/` 单一目录；下载侧打印产物结构并按文件名
  兜底定位；顺带复制 `kernel-config-exported.config` / `kernel-mt7987-options.txt`

**参考 ctr54188/h5000m-debian 的优化（配置与 CI）：**

- **内核配置补全**（16 项，均本地验证 olddefconfig 生效 + 交叉编译通过）：
  - WAN 拨号：`PPP` / `PPPOE` / `PPP_ASYNC` / `PPP_MPPE`
  - 硬件流卸载：`NF_FLOW_TABLE` / `NF_FLOW_TABLE_INET` / `NFT_FLOW_OFFLOAD`
  - 2.5G PHY：`MEDIATEK_2P5GE_PHY` / `MTK_NET_PHYLIB`（752 补丁已支持 MT7987，此前未编驱动）
  - 5G 模组 USB WWAN 栈：`WWAN` / `MTK_T7XX` / `USB_NET_QMI_WWAN` / `USB_NET_CDC_MBIM` /
    `USB_WDM` / `USB_ACM` / `USB_SERIAL_OPTION`（MT5700M 等 USB 模组必需）
- **配置回归校验扩充**：`REQUIRED_SYMBOLS` 由 21 项增至 31 项，覆盖上述新增项
  （参考库 README §5.1.1 教训：配置未写进片段会在换环境重编时静默丢失）
- **CI 健壮性**：`cancel-in-progress: true` → `false`（此前已误杀一次完整编译）；
  两个 job 增加 `timeout-minutes`（内核 330 / RootFS 180）
- **产物校验**：RootFS 构建前校验 `modules.tar.zst` 内 `qmi_wwan` / `cdc_mbim` / `option` /
  `mtk_t7xx` 存在（mt7996e / mt76-connac-lib / pwm-fan 为 `=y` builtin 不产生 .ko，
  由 `REQUIRED_SYMBOLS` 按 .config 校验）

**未采纳的参考库方案（附理由）：**

| 参考库方案 | 不采纳原因 |
|---|---|
| hostapd 5GHz 80MHz 配置 | 本库无线走 NetworkManager（`h5000m-router-init.sh` 用 nmcli 建 wlan0/wlan1 AP），无 hostapd |
| 首启 resize2fs + swap 服务 | 用户明确要求分区与 CI 对齐、暂不扩容 |
| eth IRQ 修复（997 补丁，注册 8 条中断线） | 针对 6.12 的驱动级改动，6.18 移植需实机验证，风险高，列入待办 |

### 2026-10-05 — 内核产物收集修复 + RootFS 预装 luci-app-mt5700（局域网可访问）

**编译失败修复（CI run 37258658236：`tar: lib: Cannot stat`）：**

- **modules_install 路径修复**：`build-kernel.sh` 的 `INSTALL_MOD_PATH` 原为相对路径，
  经 `make -C "$KERNEL_SRC"` 切换工作目录后被解析进内核源码树内部
  （`$KERNEL_SRC/out/...`），导致 `$MODULES_ROOT/lib` 不存在、收集产物阶段
  `tar: lib: Cannot stat: No such file or directory`。现统一将 `OUT_DIR` 规范化为绝对路径
  （`mkdir -p` + `cd && pwd`），`make -C` 与 `tar -C` 落点一致
- **modules_install 健壮化**：输出落盘 `work/modinst.log`（不再 `>/dev/null` 静默），
  失败打印日志尾部并终止；新增 `lib/modules` 产出校验
- **modules.tar.zst 名实相符**：打包由 `tar -cJf`（实为 xz）改为 `tar --zstd -cf`（真 zstd），
  与 RootFS 侧 `tar -I zstd -xf` 解压方式匹配（原组合会在 RootFS 步骤解压失败）

**CHANGELOG 已声明但未落地的 12 项修复补齐：**

- **CONFIG_PWM_FAN → CONFIG_SENSORS_PWM_FAN**：6.18 起符号改名
  （drivers/hwmon/Kconfig:1887），配置片段与 `REQUIRED_SYMBOLS` 核验同步更新；
  已在 6.18.54 上本地复现 defconfig+片段+olddefconfig 验证解析为 `=y`
- **补丁应用判定重构**：目录缺失显式 `[SKIP]`；git apply 失败但 patch 回退成功记
  `[OK]（回退）`；仅两者均失败才 `[FAIL]`
- **CI 改传 `--strict`**：补丁失败或关键配置缺失时终止构建（PWM_FAN 符号修复后可安全启用）
- **RootFS 容量自动估算**：`make-sd-image.sh` 未传 `--rootfs-size` 时按 tar 包内容求和
  （+512 MiB 余量、8 MiB 对齐、上限 7372 MiB ≈ eMMC p5 7.2 GiB），移除硬编码 4096 默认值

**RootFS 预装 luci-app-mt5700（对齐 H5000M udev 参考包）：**

- **at-webserver-rust（AT 后端）**：CI 从 Release
  [`v1.14.2`](https://github.com/LianXia233/luci-app-mt5700/releases/tag/v1.14.2) 的
  aarch64 ipk 提取（静态链接 musl，可直接运行于 Debian glibc），URL 锁定于
  `build-rootfs.sh` 的 `MT5700_IPK_URL`
- **mt5700-web（模组管理面板）**：二进制 + `/usr/share/mt5700-panel/www` 静态资源
  vendor 入库 `build/rootfs/vendor/mt5700/`（来源与更新指引见其 `PROVENANCE.md`；
  该二进制暂无公开发布渠道，暂取自 udev 参考包镜像，glibc 动态链接适配 Debian 13）
- **systemd 单元**：`at-webserver.service`（AT 后端）、`mt5700-web.service`
  （面板，`--bind 0.0.0.0 --port 8181 --rpc 127.0.0.1:8765`），chroot 阶段 enable
- **配置**：`/etc/config/at-webserver` 取 ipk 原版（`network_restrict_access '0'` 允许局域网）
- **局域网访问**：面板绑定 0.0.0.0:8181，`nftables.conf` input 策略 drop 下仅 br-lan 放行
  → LAN 可直达，WAN / 5G 上行（enx*/wwan*/usb*）不可达；RPC(8765) 保持本机回环，
  面板服务端代理转发
- **自检**：预装二进制 ELF 魔数 + aarch64 (e_machine=183) 校验（构建机无需运行二进制）
- 分区布局维持 CI 现状（p4 30 MiB FIT + p5 ~7.2 GiB ext4），**不做首启扩容**

### 2026-10-05 — 编译流程健壮性修复（12 项）

依据 H5000M-build-flow-review 所列问题逐项修复（默认密码兜底逻辑保持不变）：

- **补丁核验升级（strict）**：CI 内核编译改传 `--strict`（移除 `--skip-failed-patches`）；
  补丁应用失败或关键配置符号缺失时直接终止构建，不再静默吞错 / 仅告警
- **补丁应用判定重构**：`apply_patch_series` 目录缺失显式 SKIP；git 失败但 patch 回退成功
  记为 OK（标注回退），仅 git / patch 均失败才置 FAIL 并终止
- **CI 缓存策略修正**：`actions/cache` 仅缓存原始源码压缩包
  `out/kernel/linux-${{ env.KERNEL_VERSION }}.tar.xz`（key 按内核版本固定、无 restore-keys）；
  源码树每次干净解压，补丁幂等，同时减小缓存体积、提高命中率
- **模块包压缩名实相符**：`modules.tar.zst` 改 `tar --zstd -cf`（真 zstd），
  RootFS 解压同步 `tar -I zstd -xf`
- **apt 注释过滤**：RootFS 软件包安装命令 `grep -vE '^\s*#'` 剔除 `packages.list` 注释行
- **extlinux 补 earlycon**：extlinux.conf 的 APPEND 补充
  `earlycon=uart8250,mmio32,0x11000000`（与 FIT 刷写包一致）
- **RootFS 容量自动估算**：未传 `--rootfs-size` 时解压探测内容大小 +512 MiB 余量、
  8 MiB 对齐，上限 7372 MiB（eMMC p5 约 7.2 GiB）；CI 移除硬编码 `--rootfs-size 4096`
- **FIT 可选签名**：`make-sd-image.sh` 新增 `--sign-key <dir>`，提供密钥目录时在 ITS config
  注入 `signature-1`（sha256,rsa2048）并以 `mkimage -k` 签名；未提供则维持无签名行为
- **Release 版本号防覆盖**：命名追加 GitHub Run 序号（`%y.%m.%d-r${GITHUB_RUN_NUMBER}`），
  同日 / 同时重跑不再覆盖旧 Release
- **移除调试开关**：删除常开的 `ACTIONS_STEP_DEBUG` / `ACTIONS_RUNNER_DEBUG`
- **cpufreq 补丁兼容修复**：`kernel/patches/844-cpufreq-mediatek-Add-support-for-MT7987.patch`
  修复 6.18.54 下 `proc_fixed_volt` 兼容问题
- 同步更新：`build/build-kernel.sh`、`build/build-rootfs.sh`、`build/make-sd-image.sh`、
  `scripts/build.sh`、`.github/workflows/build.yml`

### 2026-10-04 — LED 控制：复刻官方 OpenWrt 固件方案

- 实测官方固件 `H5000M-.-sysupgrade.bin`（diag.sh / leds.sh / 内核 FIT DTB）：
  - 官方 DTS 与我们一致：`led-3=amber:wlan-2ghz`、`led-4=blue:wlan-5ghz`（gpio-leds，GPIO3/4 active-low）
  - aliases：`led-boot=led-4`（蓝）、`led-failsafe/upgrade=led-3`（琥珀）；系统就绪后无运行 LED
- 新增 `/usr/local/sbin/h5000m-led.sh`：复刻官方 get_dt_led 解析（label→chan-name→color:function）
  与 set_state 行为（boot=蓝灯 100/100 快闪、failsafe=琥珀 50/50、upgrade=琥珀 200/200、done=熄灯）
- 新增 systemd 服务（rootfs-overlay/etc/systemd/system/）：
  - `h5000m-led-boot.service`：启动早期蓝灯快闪（内核 timer trigger，oneshot 退出仍闪烁）
  - `h5000m-led.service`：multi-user.target 后就绪熄灯（done 状态）
- 同步更新：docs/hardware.md（LED 章节）、docs/first-boot.md（默认状态表）

### 2026-10-04 — 默认配置统一：SSH 局域网访问 + 固定默认密码 + 同名双频 WiFi

- Releases 编译产物默认即为「系统默认配置」：
  - **SSH**：root / `password`，仅允许局域网（br-lan）访问；WAN 侧不放行（避免公网暴露）
  - **Wi-Fi**：2.4G 与 5G 同名 **`OWRT`**，密码 **`12345678`**（/etc/default/h5000m-router 与
    h5000m-router-init.sh 兜底默认值同步）
  - **WebUI**：admin / `password`
- 构建默认密码固定为 `password`（`build/build-rootfs.sh`），不再随机生成；
  `/etc/h5000m-initial-credentials` 仍记录首次凭据，提示登录后立即修改
- 同步更新：`docs/first-boot.md`（默认值表与首次登录说明）

### 2026-10-04 — CI 编译产物上传到 GitHub Releases（参考 OpenWrt 发布惯例）

- 容器格式统一为 **`.bin`**（内核 FIT / rootfs ext4），其余命名、版本、校验与 OpenWrt 一致：
  - `H5000M-debian13-<日期>-kernel.bin`（→ p4，FIT，U-Boot bootm 直接启动）
  - `H5000M-debian13-<日期>-rootfs.bin`（→ p5，ext4 RootFS）
  - `H5000M-debian13-<日期>-rootfs.tar.zst`（RootFS 压缩包，可选刷写方式）
  - `sha256sums.txt`（参考 OpenWrt Releases 校验和）
- `.github/workflows/build.yml`：
  - `build-image` job 增加 `permissions: contents: write`
  - 新增「上传固件到 GitHub Releases」步骤（`gh release`，仅非 PR 触发）
  - Release tag 使用 `H5000M-debian13-26.10.04` 日期版本（命名带机型）；同名 tag 先删除后重建（支持每周定时/多次构建覆盖更新）
  - Release Notes 引用 `docs/first-boot.md` 刷写说明；初始凭据仅在 Artifact 交付（不公开上传）
- 新增 `.gitattributes`：仓库强制 **LF 行尾**（`* text=auto eol=lf`，二进制 png/ico 排除），
  Windows 检出同样保持 LF，杜绝 CRLF 导致 BusyBox ash / procd 启动失败


### 2026-10-04 — 刷写包产物改用 .bin 命名（与官方 H5000M-...sysupgrade.bin 风格一致）

- 构建产物由 `h5000m-kernel.fit` / `h5000m-rootfs.ext4.img` 更名为 **`.bin` 格式**：
  - `out/H5000M-debian13-kernel.bin`（内容仍为裸 FIT 镜像，→ p4，U-Boot bootm 直接加载）
  - `out/H5000M-debian13-rootfs.bin`（内容仍为 ext4 镜像，→ p5）
- 同步更新：`build/make-sd-image.sh`、`scripts/install-emmc.sh`、`scripts/build.sh`、
  `boot/boot.cmd`、`.github/workflows/build.yml`（Artifact 产物路径）及全部文档引用
  （README / docs/build-guide / first-boot / troubleshooting / debian13-partition-plan）


### 2026-10-04 — 官方固件实测验证（下载 H5000M sysupgrade.bin 逐项核对启动链）

下载官方固件 `H5000M-.-sysupgrade.bin`（ImmortalWRT SNAPSHOT, mediatek/filogic, aarch64_cortex-a53）
并实测分析，用真实数据验证 / 修正分区方案：

**实测确认（与方案一致）：**

- 固件为新式 sysupgrade tar 包：`sysupgrade-hiveton_h5000m/{CONTROL,kernel,root}`，`BOARD=hiveton_h5000m`
- p4 内容为**裸 FIT 镜像**（魔数 `d00dfeed`），内核 LZMA 压缩；`mkimage -l`：
  `ARM64 OpenWrt FIT` / `Linux-6.18.52` / `kernel-1` + `fdt-1` + `config-1`，每镜像 crc32 + sha1 双哈希
- bootargs（DTB chosen）：`earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf`
- GPT PARTLABEL 定位：`lib/upgrade/platform.sh` 设 `CI_KERNPART="kernel" CI_ROOTPART="rootfs"`，
  `lib/upgrade/emmc.sh` 按 PARTLABEL `find_mmc_part` 后 **dd 仅写 kernel/rootfs 两分区**（与本方案"只写 p4/p5"一致）
- p2 `factory`：DTB `block-partition-factory { partname = "factory"; nvmem-layout }`（Wi-Fi EEPROM）
- 网口映射：`etc/board.d/02_network` → `ucidef_set_interfaces_lan_wan "eth0" eth1`（LAN=eth0 / WAN=eth1）
- MAC 生成：`macaddr_generate_from_mmc_cid mmcblk0`（LAN），WAN=LAN+1
- eMMC：DTB `mmc@11230000` `mmc-card` `non-removable`（无 SD 卡槽）

**修正（基于实测）：**

- FIT **load/entry 地址 0x40000000**（原假设 0x46000000，实测官方 FIT 同值，已修正）
- FIT 节点命名与官方同构：`kernel-1` / `fdt-1` / `config-1` / `hash-1`(crc32) / `hash-2`(sha1)（消除 `@` 单元地址警告）
- bootargs 补 `earlycon=uart8250,mmio32,0x11000000`（与官方 chosen 一致，各处文档/脚本已同步）
- `make-sd-image.sh`：`mkimage` 调用前 `cd` 到工作目录（`.its` 的 `/incbin/()` 为相对路径，修复潜在打包失败）
- 用官方内核数据实测验证：按新 `.its` 生成的 FIT 与官方哈希逐字节一致（crc32 `ffeed093`、sha1 `3ed2ff7d…`）
- `docs/debian13-partition-plan.md` 新增 §1.2「官方固件实测验证」

### 2026-10-04 — 分区方案重构：完整复用现有 OpenWrt eMMC 布局（不重建 / 不重排）

**核心原则落地**：以设备当前正常运行的 OpenWrt 分区布局 / 启动链 / DTS 为唯一基准，
BL2 / U-Boot / FIP / u-boot-env / factory / GPT / eMMC 硬件配置 **零写入、零改动**；
Debian 13 仅复用并替换 kernel（p4）与 rootfs（p5）两个分区的**内容**。

**新增：**

- `docs/debian13-partition-plan.md`：完整分区方案
  - 当前 OpenWrt 分区表（p1 u-boot-env 1MiB / p2 factory 2MiB / p3 fip 4MiB /
    p4 kernel 30MiB / p5 rootfs ~7.2GiB）与启动链对应关系（BootROM → BL2 → FIP →
    U-Boot 读 p4 FIT → bootm → root=PARTLABEL=rootfs 挂载 p5）
  - 不可修改区域清单；Debian 13 最终分区表（与 OpenWrt 完全一致，零结构变化）
  - U-Boot 加载 Debian Kernel 的方式（p4 FIT + bootm，与 OpenWrt 同型，无需 EFI/GRUB）
  - 内核定位 RootFS 的 bootargs、`/etc/fstab`、覆盖区域、备份方案、GPT 备份损坏分析与处理、
    刷写后验证方案

**修改（对齐新分区方案）：**

- `scripts/install-emmc.sh`：**不再创建/重建 GPT**（删除 mklabel/mkpart），仅：
  只读校验现有分区表（含 p5 PARTLABEL=rootfs 校验）→ 写 p4（FIT）→ 写 p5（ext4 /
  解压 tar.zst）→ 回读校验；支持 `--kernel-fit` / `--rootfs` / `--rootfs-img` /
  `--backup-full` / `--backup-p45`；绝不触碰 p1-p3 / GPT / eMMC 硬件配置
- `boot/boot.cmd`：备用引导脚本，主引导为 p4 FIT（现有 U-Boot bootm，无需本脚本）；
  兜底路径从 p5（mmc 0:5）`/boot` 加载 Image + DTB 后 booti
- `build/make-sd-image.sh`：改为生成**刷写包**（`h5000m-kernel.fit` → p4、
  `h5000m-rootfs.ext4.img` → p5），不再创建分区表 / 不写块设备；
  FIT 内核 LZMA 压缩（p4 仅 30MiB），与 OpenWrt 同型；rootfs 内预置 `/boot` 备用引导文件
- `scripts/build.sh`：一键构建步骤 3 改为生成刷写包（移除废弃的 `--dev/--img` 参数）
- `.github/workflows/build.yml`：构建步骤改为生成 `h5000m-kernel.fit` +
  `h5000m-rootfs.ext4.img` 刷写包产物
- 文档：README（分区与启动 / 首次启动 / 目录结构 / 验收标准）、
  docs/build-guide.md（刷写包生成与 eMMC 刷入）、docs/first-boot.md（仅写 p4/p5 流程、
  USB 试运行改为手动制作）、docs/troubleshooting.md（U-Boot 引导 / eMMC 刷入排查对齐新流程）

### 2026-10-04 — 风扇温控 + U-Boot 兼容 + eMMC 刷入 + GitHub Actions 云编译

**风扇控制（参考 luci-app-h5000m-fancontrol 行为）：**

- 内核：`CONFIG_PWM_FAN=y`（pwm-fan hwmon，`/sys/class/hwmon/*/pwm1` + thermal cooling device）
  - `build/kernel-conf/h5000m-6.18.config` 启用 PWM / PWM_MEDIATEK / PWM_FAN
  - `build/build-kernel.sh` 的 `REQUIRED_SYMBOLS` 增加 `CONFIG_PWM_FAN` 核验
  - DTS 删除 cpu-thermal 中风扇相关 cooling-maps（`cpu-active-high/low`、`cpu-passive`），
    保留 CPU 频率缩放与 critical/hot trips，避免内核 governor 与用户空间争抢 PWM
- `rootfs-overlay/usr/local/sbin/h5000m-fancontrol`：Debian 版风扇控制器（systemd 服务）
  - 自动曲线（silent/balanced/performance/custom）、手动 PWM、kernel 仅内核保护模式
  - 温度滞回、降速延迟、启动助推（Start PWM）、传感器/曲线故障保护（Failsafe PWM）
  - 温度来源 max（CPU/PHY/WiFi/5G 模组取最高）或 cpu；接管 thermal zone 策略前先保存并退出恢复
- `rootfs-overlay/etc/default/h5000m-fancontrol`：默认配置（ENABLED/MODE/CURVE/TEMP_SOURCE 等）
- `rootfs-overlay/etc/systemd/system/h5000m-fancontrol.service`：开机自启，失败自动重启
- `build/build-rootfs.sh`：overlay 后 chmod 风扇脚本 + chroot 内 enable 服务

**U-Boot 兼容（不修改 U-Boot 本体）：**

- `boot/boot.cmd`：U-Boot 启动脚本源文件（eMMC → USB 依次尝试，booti 启动）
- `build/make-boot.sh`：用 mkimage 生成 `boot.scr`（ImmortalWrt/OpenWrt Filogic U-Boot 自动加载）
- `build/make-sd-image.sh`：boot 分区自动放入 boot.scr，无 boot.scr 时回退 extlinux 并告警
- `scripts/install-emmc.sh`：eMMC 刷入脚本（GPT：p1 vfat boot + p2 ext4 rootfs，
  可选整盘备份、可选 fw_setenv 设置 U-Boot 环境）

**GitHub Actions 云编译：**

- `.github/workflows/build.yml`：push / PR / workflow_dispatch / 每周定时触发
  - Job 1 内核编译（ubuntu-24.04，内核源码缓存，产物 artifact）
  - Job 2 RootFS + SD 镜像（debootstrap + qemu-user-static，上传发布 artifact）
- `.gitignore`：out/、镜像、凭据、日志等

**文档：**

- README：目录结构、快速开始、云编译、eMMC 固化说明
- docs/build-guide.md：boot.scr 生成、CI、eMMC 刷入
- docs/first-boot.md：install-emmc.sh 固化流程
- docs/hardware.md：风扇控制（DTS/PWM/控制器）
- docs/architecture.md：风扇服务职责与启动顺序
- docs/troubleshooting.md：风扇与启动引导排查

### 2026-10-04 — 初始版本（H5000M → Debian 13 移植）

**新增：**

- 项目骨架：README、docs/（architecture、hardware、build-guide、first-boot、troubleshooting）
- 硬件参考：H5000M DTS（ImmortalWrt master 已验证版本）→ `dts/`
  （mt7987a-hiveton-h5000m.dts + mt7987a.dtsi / mt7987b.dtsi / mt7987.dtsi）
- Linux-Router 源码 vendored → `linux-router/vendor/`（保持上游原始文件，集成层单独放置）
- 内核适配：基于 ImmortalWrt patches-6.18 的 MT7987A 补丁集 → `kernel/patches/`
  （generic/backport、generic/pending、generic/hack、mediatek 四层，按 OpenWrt 标准顺序）
- 固件清单：MT7992（mediatek/mt7996/mt7992_*_23.bin）、MT7987 内置 2.5G PHY（i2p5ge-phy-*.bin）

**内核（M1）：**

- `build/build-kernel.sh`：自动化内核构建（默认 Linux 6.18.54）
  - 按序应用 generic/backport → generic/pending → generic/hack → mediatek 补丁（逐个 `git apply --check`）
  - 复制 OpenWrt files（mtdsplit、mtk_bmt、swconfig 等）→ `kernel/files-generic/`、`kernel/files-mediatek/`
  - 复制 H5000M DTS 并注册 DTB 目标，`olddefconfig` 后核验关键符号，输出 Image / dtb / modules.tar.zst
- `build/kernel-conf/h5000m-6.18.config`：MT7987A 内核配置片段
  （MT7987 pinctrl/clk、mtk_eth_soc、RTL8221B、mt76/MT7992、eMMC、PCIe Gen3、PWM、LVTS thermal、nftables/bridge 全量）

**RootFS（M2）：**

- `build/build-rootfs.sh`：自动化 Debian 13 (Trixie) ARM64 RootFS 构建
  - `debootstrap --foreign trixie` + qemu-user-static 完成第二阶段
  - 安装 `build/rootfs/packages.list`（systemd / NetworkManager / hostapd / dnsmasq / nftables / iproute2 / iw / wireless-regdb / ethtool / bridge-utils / openssh-server 等）
  - 应用 `rootfs-overlay/` 覆盖层 + 集成 Linux-Router + 安装内核/模块 + 生成初始凭据
- `scripts/fetch-firmware.py`：跨平台固件获取（MT7992 / MT7987 PHY 固件，失败可离线重试）

**开箱即用（M3）：**

- `rootfs-overlay/` 运行时配置：
  - `etc/systemd/system/h5000m-router-init.service`：开机编排（WAN/LAN/bridge/Wi-Fi 创建）
  - `usr/local/sbin/h5000m-router-init.sh`：幂等初始化，创建 NM 连接：
    WAN=eth1(DHCP) / br-lan=192.168.88.1/24(+IPv6 ULA) / LAN=eth0(从属) / Wi-Fi AP(2.4G+5G, 桥接 br-lan)
  - `etc/default/h5000m-router`：网络默认配置（网段/SSID/密码/regulatory）
  - `etc/NetworkManager/conf.d/h5000m.conf`：`dns=none`，NM 独占接口管理，DNS 交 dnsmasq
  - `etc/dnsmasq.d/h5000m.conf`：唯一 DHCP+DNS（:53），DHCP 池 + RA/无状态 DHCPv6 + 兜底上游 DNS
  - `etc/nftables.conf`：唯一防火墙/NAT（input drop、WAN 侧仅必要流量、MASQUERADE、IPv6 邻居发现放行）
  - `etc/sysctl.d/90-h5000m-router.conf`：IPv4/IPv6 forwarding、桥接 nf-call 等
  - `etc/systemd/system/router-panel.service` / `router-panel-agent.service`：Linux-Router WebUI 与代理
  - `etc/systemd/system/dnsmasq.service.d/override.conf`：dnsmasq 崩溃自动重启
  - `etc/NetworkManager/dispatcher.d/90-h5000m-wan-dns`：WAN DHCP 后刷新 dnsmasq 上游 DNS
- Linux-Router 集成：预装到 `/opt/linux-router`，修改默认 LAN 网段为 192.168.88.0/24，
  预创建运行账号/数据目录/初始密码，开机自动启动（WebUI http://192.168.88.1）

**镜像与文档（M4/M5）：**

- `build/make-sd-image.sh`：GPT 分区（p1 vfat /boot + p2 ext4 /）生成 USB/SD 启动镜像
- `scripts/build.sh`：一键构建入口（内核 + RootFS + 镜像）
- 文档：docs/architecture.md（服务职责表）、docs/hardware.md（硬件/补丁清单）、
  docs/build-guide.md（构建指南）、docs/first-boot.md（首启不破坏 eMMC）、docs/troubleshooting.md

**已验证/确认：**

- WAN/LAN 物理对应（依据 ImmortalWrt `02_network` + DTS PHY 定义，非名称猜测）：
  - LAN = eth0（gmac0，外置 RTL8221B PHY，远离电源口）
  - WAN = eth1（gmac1，内置 2.5G PHY，靠近电源口）
- 主线上游内核不支持 MT7987A，须使用 ImmortalWrt 6.18 补丁集；MT7992 由 mainline mt76 支持
- Debian 13 仓库不含 MT7992/MT7987 PHY 固件，固件从 linux-firmware / mt76 仓库获取
- nftables ICMPv6 类型名以实际支持为准（`nd-neighbor-advert` / `nd-router-advert`）
- PCIe 符号名以 6.18 为准（`CONFIG_PCIE_MEDIATEK` / `CONFIG_MT76_CORE`）

**网络职责（唯一控制者）：**

| 功能 | 唯一控制者 | 底层实现 |
| --- | --- | --- |
| WAN/LAN/网口/Bridge/Wi-Fi AP | Linux-Router 编排（NM 连接） | NetworkManager |
| DHCP/DNS | dnsmasq（:53，NM `dns=none`） | dnsmasq |
| NAT/防火墙 | nftables（唯一后端） | nftables |
| 服务生命周期 | systemd | systemd |
| WebUI/配置持久化 | Linux-Router | router-panel + agent |

**计划里程碑**

| 里程碑 | 状态 |
| --- | --- |
| M1 内核 | ✅ build-kernel.sh + defconfig + DTS + 补丁集 |
| M2 rootfs | ✅ build-rootfs.sh + packages.list + firmware + overlays |
| M3 开箱即用 | ✅ 路由器配置 + Linux-Router 集成 + systemd 编排 |
| M4 首启介质 | ✅ make-sd-image.sh + scripts/build.sh |
| M5 验证 | ⏳ 沙箱/实机验证（需目标硬件） |
