# 更新文档 (Changelog)

本项目遵循用户规则：任何对仓库的推送/更新，必须同步更新本文档。

## [Unreleased]

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
