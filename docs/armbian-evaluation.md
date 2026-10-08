# Armbian 可行性评估（AP3000M 移植期间插入的一次调研）

> 状态：**仅评估，未改动任何构建逻辑**。本文回答「仓库能不能换成 Armbian 的 Debian」。
> 提出时间：2026-10-09，与 AP3000M（MT7981B）多板移植并行。
>
> ⚠️ **前提提醒：当前项目仍在测试中，两板实机均未通过** —— AP3000M 的**内核 job 已云编译
> 通过**（`c3f861d`），但 RootFS + 刷写包 job 仍在构建，**当前无可用产物**（此前内核阶段
> 连续失败两次：缺 Kconfig 注册 → 修复后 `depends` 引用了非 Kconfig 符号 `HRTIMER`）；
> H5000M 全链路云编译虽成功，但**从未在真机刷写验收**，多板化改造后的回归也未做
> （详见 [ci-status.md](ci-status.md) 与 [../CHANGELOG.md](../CHANGELOG.md)）。
> **⚠️ 云编译成功 ≠ 实机可用**，本项目至今没有任何一块板卡完成实机验收。
> 本文的评估结论建立在"现有自维护内核树最终可用"的假设上；若该假设不成立，
> 结论需重新审视。

## 1. 先厘清问题：当前实现已经是什么

`build/build-rootfs.sh` 当前的实际取值（读代码得到，非推测）：

| 项 | 当前值 | 出处 |
| --- | --- | --- |
| 架构 | `ARCH="arm64"` | `build/build-rootfs.sh:62` |
| 发行版 | `SUITE=trixie`（Debian 13） | `build/build-rootfs.sh` |
| 镜像源 | `MIRROR="https://deb.debian.org/debian"` | `build/build-rootfs.sh:63` |
| 构建方式 | arm64 宿主 native；x86 宿主 `--foreign` + qemu 二阶段 | `build/build-rootfs.sh:167-174` |
| 产物 | `debian13-arm64-rootfs.tar.zst` | `build/build-rootfs.sh:105` |

**结论 1**：仓库已经是「ARM64 架构 + Debian 13 官方源」。这恰好就是 **Armbian 的发行版内容来源**——Armbian 的 Debian 镜像底层同样是 Debian 官方 arm64 包，只是额外叠加 BSP 与工具。

**结论 2**：因此「换成 Armbian 的 Debian」只可能有两层含义，收益与代价相差一个数量级：

| 含义 | 动作 | 收益 | 代价 | 建议 |
| --- | --- | --- | --- | --- |
| **A. 换镜像源** | `--mirror` 换成 Armbian / 国内镜像 | CI 下载提速、摆脱跨国延迟 | 一行参数，零风险 | ✅ 随时可做 |
| **B. 换发行版** | 改用 Armbian Build Framework（`armbian/build`） | 拿到 Armbian 的板级 BSP、ATF/U-Boot 构建链、`armbian-config` | 见 §3，与现有架构**互斥** | ❌ 不建议 |

## 2. 路线 A：换镜像源（立即可用）

脚本已有 `--mirror` 开关且强制 HTTPS（`build/build-rootfs.sh:91`、`:115`）：

```bash
sudo bash build/build-rootfs.sh --mirror https://mirrors.tuna.tsinghua.edu.cn/debian
sudo bash build/build-rootfs.sh --mirror https://mirrors.ustc.edu.cn/debian
```

需要留意的一点：**Debian arm64 在官方源里是 `main`（非 ports），国内各镜像站的 `/debian` 路径对 arm64 支持完整**，无需切 `/debian-ports`。若只改默认值（不改脚本逻辑），后续 CI 缓存命中的就是新源的 `.deb`，切换当天会全量重下。

## 3. 路线 B：换 Armbian 发行版（不推荐，理由如下）

### 3.1 Armbian 对 MT798x 的支持定位

实测 `armbian/build` 仓库（main 分支）：

| 检查项 | 结果 |
| --- | --- |
| 板卡总数 | 425 |
| 名称含 `7981` / `7988` / `mtk` / `router` | **0 个** |
| Filogic 家族 | 存在，`config/sources/families/filogic.conf`（平台级，非板级） |
| 唯一沾边的板 | `config/boards/bananapir4.csc` —— **`.csc` 后缀 = Community Supported**（社区自维护，非官方承诺），且是 **MT7988A**，不是 MT7981B |
| Filogic 内核 | `KERNELSOURCE=https://github.com/chainsx/linux-filogic.git`（legacy 分支，6.12.35）/ `frank-w/BPI-Router-Linux`（current 6.12） |
| 发行版支持 | `trixie` 在列（`config/distributions/`），这点可用 |

也就是说：**Armbian 里没有 AP3000M（MT7981B）这块板，也没有任何 MT7981 板**。用 Armbian 不等于"得到更好的 MT7981 支持"，而是"接手一套为 MT7988 写的 BSP，再自己补 MT7981 板级"。

### 3.2 与现有架构的冲突点（逐条）

| 冲突项 | 本仓库现状 | Armbian 做法 | 影响 |
| --- | --- | --- | --- |
| **引导层** | SquashFS 只读基础系统 + OverlayFS 可写层 + `pivot_root`（`build/make-sd-image.sh:367-491`） | ext4 整分区 + `SRC_EXTLINUX` + `armbian-install` | Armbian **没有** SquashFS+overlay 这一套，需自行重写引导层，`sysupgrade`（164 MiB）与在线升级能力全部要重新实现 |
| **分区表** | 复用设备现有 GPT：`p1 u-boot-env / p2 factory / p3 fip / p4 kernel / p5 rootfs`，**不动 BL2/FIP/u-boot-env/GPT** | `IMAGE_PARTITION_TABLE=gpt` + `packages/blobs/filogic/gpt` **模板覆盖**，且 `write_uboot_platform()` 会 `dd` 写 bl2.img、重写 FIP、**重刷分区表** | 直接违反「U-Boot 不修改 / GPT 零改动」这一硬约束，且会**覆盖**设备原有 u-boot-env 与 factory 分区 |
| **内核版本** | 自编译 6.18.54 + ImmortalWrt MT7987/MT7981 补丁集（`kernel/patches/`） | 6.12.35（legacy）/ 6.12（current）/ 6.16（edge），来自 chainsx 或 frank-w 的 fork | 版本回落 6.12/6.16，现有 `build/kernel-conf/*-6.18.config`、`CONFIG_ARM64_PSEUDO_NMI` 挂死可诊断性加固等全部作废 |
| **U-Boot / ATF** | 一概不改（沿用出厂） | 从 `mtk-openwrt/arm-trusted-firmware` + `u-boot v2025.04` **重新编译** bl2/fip | 板砖风险显著上升；且 AP3000M 的 `ATF_TARGET_MAP` 需要自己写（filogic.conf 只支持 `mt7981`/`mt7988` 两种 `BOOT_SOC`，`DRAM_USE_DDR4=1` 等参数需实测标定） |
| **用户空间** | Debian + NetworkManager + dnsmasq + nftables + 自研 `h5000m-*`/`ap3000m-*` 服务，纯净无冗余 | Debian + **`armbian-firstrun`、`armbian-config`、`armbian-bsp-cli-*`、`armbian-zsh`、`armbian-motd`** 等 | 与 `router-init` 职责重叠；`armbian-firstrun` 会抢首启流程，需逐项禁用 |
| **生态** | `luci-app-*` 系列插件、FM350/MT5700 模组调试链路 | 无 OpenWrt 生态 | 现有插件工作无法复用 |

### 3.3 评估结论

> **不建议**把发行版整体换成 Armbian。
>
> 理由倒不是 Armbian 不好，而是**它提供的价值（板级 BSP + ATF/U-Boot 编译）恰好是本项目明确不要的两样**：本项目刻意「不改 U-Boot、复用出厂 GPT、自编译 6.18 内核」，而 Armbian 的设计前提就是"重新烧 ATF+U-Boot+GPT 来安装"。同时它**并不提供 MT7981B 板级支持**（0 块板），换过去之后板级活儿一点没少，反而多了一套要拆的 BSP 层。
>
> **可取的只有路线 A**（换镜像源），以及从 Armbian 借鉴两个**思路**而非代码：
> 1. `SRC_CMDLINE` 显式声明内核 cmdline —— 本项目已用 `FIT_BOOTARGS` + `fdtput` 覆写做到（`build/make-sd-image.sh:112`）；
> 2. 内核 config 按「家族 + 分支」命名（`linux-filogic-current.config`）—— 与本项目 `h5000m-6.18.config` / `ap3000m-6.18.config` 的按板命名是同一思路。

## 4. 如果仍然想走路线 B：最小侵入方案

保留可信的部分，只借 Armbian 的**内核与补丁来源**，不引入其构建框架：

1. 从 `patch/kernel/archive/filogic-6.16/patches.armbian/` 挑选 MT7981/MT7988 相关补丁（如 `mtk_eth_soc` IRQ 重构系列），与本项目现有补丁集做**去重合并**后放进 `kernel/patches/`；
2. 内核版本仍锁 6.18.54（当前已验证），不跟随 Armbian 的 6.12/6.16；
3. 引导层、分区策略、服务面**全部不动**。

即：「借补丁，不借框架」。这一条若要做，建议**等到 AP3000M 多板移植完成、构建链路稳定之后**单独立项。

## 5. 待你决策的点

| 编号 | 待定 | 影响 |
| --- | --- | --- |
| D1 | 是否采纳路线 A（换镜像源） | 一行默认值；若采纳，我会同时更新 CI 与文档 |
| D2 | 若采纳 A，用哪个镜像站（清华 / 中科大 / 阿里 / Armbian 自建） | 影响 `.deb` 下载速度与缓存命中 |
| D3 | 是否采纳 §4 的「借补丁不借框架」 | 独立小任务，建议在 AP3000M 之后 |

> 本文仅为评估，不构成对现有脚本的任何修改。AP3000M 多板移植按原计划继续。
