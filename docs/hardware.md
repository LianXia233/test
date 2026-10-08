# Hiveton H5000M 硬件适配说明

> ## ⚠️ 警告：项目仍在测试中，尚未跑通
>
> - **AP3000M (MT7981B)：❌ 未跑通** —— 内核编译连续失败两次（缺 Kconfig 注册 →
>   修复后 `depends` 引用了非 Kconfig 符号 `HRTIMER`）。最新修复仍在等待 CI 验证。
> - **H5000M (MT7987A)：⚠️ 云编译通过，但实机尚未验证** —— `c21fc66` 只是"能构建出镜像"，
>   刷写后能否正常启动、网络能否连通、功能是否正常**均未验收**。多板化改造后的
>   回归同样未做。
>
> **⚠️ 云编译成功 ≠ 实机可用。本项目至今没有任何一块板卡完成实机验收。**
>
> 本文档中的 AP3000M 相关内容（`boards/ap3000m.board`、`dts/mt7981b*`、
> `build/kernel-conf/ap3000m-6.18.config`、`kernel/files-boards/ap3000m/`、
> AP3000M 风扇链路）均为**未验证状态**，请勿据此刷机或用于生产。
> 根因与修复记录见 [../CHANGELOG.md](../CHANGELOG.md)。


本文以 ImmortalWrt master 已验证的硬件定义为唯一参考：

- DTS：`target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts`（本项目已复制到 `dts/`）
- 内核：`target/linux/mediatek/filogic/config-6.18` + `patches-6.18/`
- 固件：`package/firmware/linux-firmware/mediatek.mk`、`package/kernel/mt76/Makefile`

## 1. 设备树（DTS）

直接复用已验证的 `mt7987a-hiveton-h5000m.dts`，**未改动**任何已验证定义：

- GPIO 按键：reset = GPIO1，wps = GPIO0（gpio-keys）
- LED：GPIO3（amber，WLAN 2.4G）、GPIO4（blue，WLAN 5G）（gpio-leds）
  - 软件可控制两个指示灯（GPIO3/GPIO4）；LED1（5G 模块）、LED5（电源）为硬件直控
  - DTS aliases：`led-boot=led-4`（蓝）、`led-failsafe/upgrade=led-3`（琥珀），与官方固件一致
  - 控制脚本：`/usr/local/sbin/h5000m-led.sh`（复刻官方 diag.sh/leds.sh 方案）
  - systemd：`h5000m-led-boot.service`（启动早期蓝灯快闪）→ `h5000m-led.service`（就绪后熄灯）
- 网络：
  - `gmac0`：2500base-x，PHY handle = `phy0`（RTL8221B，mdio addr 1，GPIO42 reset）
  - `gmac1`：internal，PHY handle = `phy1`（内置 2.5G PHY，mdio addr 15）
- eMMC：`mmc0` 8 线 48MHz，`card@0` 分区含 `factory` NVMEM（Wi-Fi EEPROM，0x0 0x1e00）
- PCIe：`pcie0`（GPIO36 reset），下游 `mt7992@0,0` 引用 `eeprom_factory_0`
- PWM 风扇：`pwm1` 50kHz（pwm-fan，`/sys/class/hwmon/*/pwm1`）
- USB：`ssusb` + `tphyu3port0`
- UART0：115200n8 earlycon

> **风扇策略（2026-10-04 新增）**：`mt7987a-hiveton-h5000m.dts` 在 `&fan` 节点后追加
> `&{/thermal-zones/cpu-thermal/cooling-maps}` 的 `/delete-node/` 片段，移除
> `cpu-active-high` / `cpu-active-low` / `cpu-passive` 三个**风扇**冷却映射，保留
> `cpu-active-hot`（CPU 频率缩放）与 hot/critical trips。原因：PWM 输出由用户空间
> `h5000m-fancontrol` 独占管理，避免内核 thermal governor 与用户空间争抢同一 PWM；
> CPU 保护（频率缩放 + critical 关机）不受影响。

### 1.1 新增 DTS 需要的配套 dtsi

H5000M DTS `#include "mt7987a.dtsi"`。内核构建时需要把 ImmortalWrt 中的以下文件一并放入
`arch/arm64/boot/dts/mediatek/`：

- `mt7987a.dtsi`
- `mt7987.dtsi`
- `mt7987b.dtsi`（mt7987.dtsi 若引用）
- `thermal-trips-cooling-maps.dtsi`（mt7987a.dtsi 若引用）

并在该目录 `Makefile` 的 `dtb-$(CONFIG_ARCH_MEDIATEK)` 中加入：

```
mediatek/mt7987a-hiveton-h5000m.dtb
```

## 2. 内核补丁（来自 ImmortalWrt patches-6.18）

以下补丁为 **MT7987A 必需**，构建脚本自动按序应用：

| 补丁 | 作用 |
| --- | --- |
| `001-clk-mediatek-add-MUX_CLR_SET-macro.patch` | 时钟宏（依赖） |
| `360-pinctrl-add-pinctrl-driver-for-mt7987-from-sdk.patch` | MT7987 pinctrl 驱动 |
| `361-clk-mediatek-add-clock-driver-for-mt7987-from-sdk.patch` | MT7987 时钟驱动 |
| `070-v7.0-pinctrl-mediatek-enable-ies_present-flag-for-MT798x.patch` | pinctrl MT798x 标志 |
| `740-net-pcs-mtk_lynxi-add-mt7987-support.patch` | PCS 驱动 MT7987 |
| `750-net-ethernet-mtk_eth_soc-add-mt7987-support.patch` | 以太网驱动 MT7987 |
| `751-net-ethernet-mtk_eth_soc-revise-hardware-configuration-for-mt7987.patch` | 以太网硬件配置修正 |
| `752-net-phy-mtk-2p5ge-add-support-for-mt7987.patch` | 内置 2.5G PHY 驱动 |
| `733-net-phy-realtek-support-LED-polarity-on-RTL8221B.patch` | RTL8221B LED 极性 |
| `821-add-pwm-feature-for-mt7987.patch` | PWM 驱动 MT7987 |
| `831-thermal-drivers-mediatek-lvts_thermal-Add-MT7987-support.patch` | 热管理 |
| `830-thermal-drivers-mediatek-lvts_thermal-Add-irq_enable-support.patch` | 热管理（依赖） |
| `844-cpufreq-mediatek-Add-support-for-MT7987.patch` | cpufreq |
| `610-pcie-mediatek-fix-clearing-interrupt-status.patch` | PCIe 中断修正 |
| `710-pci-pcie-mediatek-add-support-for-coherent-DMA.patch` | PCIe 一致性 DMA（mt76 需要） |
| `966-pcie-mediatek-gen3-Add-WIFI-HW-reset-flow.patch` | PCIe Wi-Fi 硬件复位流程 |
| `920-block-partitions-msdos-add-OF-node-by-partition-numb.patch` | eMMC 分区名 → OF 节点（factory NVMEM 依赖） |
| `173-dts-mt7988a-Add-built-in-ethernet-phy-firmware-node.patch` | 内置 PHY 固件节点（dtsi 依赖） |

> 注意：`750/751/752` 与 `173` 之间存在 dtsi 上下文依赖，必须按编号顺序应用，且内核版本需与
> ImmortalWrt 当前 6.18.x 一致（构建脚本默认 6.18.54，可用 `--kernel-version` 覆盖）。
> 若个别补丁在目标版本上冲突，构建脚本会停止并提示，可升级/降级 `--kernel-version` 后重试。

mt76 补丁（`package/kernel/mt76/patches/100-wifi-mt76-mt7996-Use-tx_power-from-default-fw-if-EEP.patch`）：
mainline 6.18 mt76 已支持 MT7992，此补丁为 EEPROM 缺失时的发射功率回退，可选应用。

## 3. 固件

| 固件 | 来源 | 安装路径 |
| --- | --- | --- |
| MT7992 Wi-Fi（`mt7992_dsp_23.bin`、`mt7992_eeprom_23.bin`、`mt7992_eeprom_23_2i5i.bin`、`mt7992_rom_patch_23.bin`、`mt7992_wa_23.bin`、`mt7992_wm_23.bin`） | linux-firmware 仓库 `mediatek/mt7996/` | `/usr/lib/firmware/mediatek/mt7996/` |
| MT7987 内置 2.5G PHY（`i2p5ge-phy-DSPBitTb.bin`、`i2p5ge-phy-pmb.bin`） | linux-firmware 仓库 `mediatek/mt7987/` | `/usr/lib/firmware/mediatek/mt7987/` |
| wireless-regdb（`regulatory.db`） | Debian 13 `wireless-regdb` 包 | `/usr/lib/firmware/wireless/` |

固件由 `scripts/fetch-firmware.py` 从 linux-firmware 拉取并放置到
`build/rootfs/firmware/`，rootfs 构建时安装。**不依赖 Debian 13 firmware-mediatek 包版本**
（Trixie 冻结版本不含 mt7987 2p5g PHY 固件，mt7992 固件也以仓库最新为准）。

Wi-Fi EEPROM：DTS 将 MT7992 EEPROM 源绑定到 eMMC `factory` 分区 NVMEM（`nvmem-cells`）；
构建会同时打包上表所列固件。注意：当前实机观测来自 OpenWrt，曾出现 `eeprom load fail, use default bin`
告警；这不等同于 Debian 镜像已验证 EEPROM 校准正常。首次 Debian 启动后应检查内核日志、接口、AP 与射频状态，
不得仅凭驱动/固件已编译或打包宣称 Wi-Fi 已在 Debian 实机验收通过。

## 4. 内核配置要点（defconfig 片段）

见 `build/kernel-conf/`。关键选项：

```
CONFIG_ARCH_MEDIATEK=y
CONFIG_PINCTRL_MT7987=y
CONFIG_COMMON_CLK_MT7987=y      # 取决于补丁定义符号名
CONFIG_NET_MEDIATEK_SOC=y
CONFIG_MEDIATEK_GE_PHY=y        # 2p5ge 内置 PHY
CONFIG_REALTEK_PHY=y            # RTL8221B
CONFIG_PHY_MTK_TPHY=y
CONFIG_MTD_BLOCK=y
CONFIG_MMC=y
CONFIG_MMC_MTK=y
CONFIG_PCI=y
CONFIG_PCI_MEDIATEK_GEN3=y
CONFIG_PCIE_MEDIATEK=y
CONFIG_MT76=y / =m
CONFIG_MT7925E / MT7996E 等 mt76 子模块（含 mt7992）
CONFIG_PWM=y / CONFIG_PWM_MEDIATEK=y
CONFIG_PWM_FAN=y                  # pwm-fan（风扇 hwmon + thermal cooling device）
CONFIG_THERMAL=y
CONFIG_MTK_LVTS_THERMAL=y
CONFIG_ARM_MEDIATEK_CPUFREQ=y
CONFIG_XHCI_MTK=y
CONFIG_NVMEM=y
CONFIG_OF_OVERLAY=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER=y
CONFIG_NF_TABLES=y
CONFIG_NF_NAT=y
CONFIG_NETFILTER_XT_MATCH_*（iptables 兼容，Linux-Router 依赖）
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IPV6=y
CONFIG_WIREGUARD=m（可选）
```

## 5. WAN / LAN 与 MAC

- LAN MAC / WAN MAC：由**用户空间**按板载 eMMC CID 派生（LAN = `02:<sha256(cid)[0:3]>:00:00`，
  WAN = LAN + 1），实现在 `/usr/local/sbin/h5000m-router-init.sh` 的 `derive_base_mac()`，
  并通过 NetworkManager 的 `ethernet.cloned-mac-address` 应用；首次算出的结果持久化在
  `/etc/h5000m-mac.conf`，后续开机直接复用。
- **不使用** OpenWrt 的 `macaddr_generate_from_mmc_cid`：这是 ImmortalWrt/OpenWrt 用户空间的
  `02_network` 钩子，Debian 分支里没有这套机制（历史文档曾误记）。
- DTS **不再写死** `mac-address`（`dts/mt7987a-hiveton-h5000m.dts` 的 `&gmac0` / `&gmac1`）：
  固定值会让所有刷了同一固件的设备共用同一组 MAC，接进同一个二层网络就冲突。
- 接口命名：eth0 = LAN，eth1 = WAN（内核按 gmac 顺序命名，U-Boot 传入 DTB 时 eth0/eth1 即对应 gmac0/gmac1）

## 6. 风扇控制（router-fancontrol，多板）

通用层脚本名为 `router-fancontrol`（2026-10-09 由 `h5000m-fancontrol` 更名，见 CHANGELOG），
所有板卡共用一套控制策略；**差异只在 PWM 后端**，由板级的 `PWM_BACKEND` 选择。

### 6.1 后端选型（三选一）

| 后端 | PWM 节点 | 用于 |
| --- | --- | --- |
| `hwmon` | `/sys/class/hwmon/hwmon*/pwm1` | H5000M（`pwm-fan` 驱动）；AP3000M **8GB 版** |
| `pwmchip` | `/sys/class/pwm/pwmchip*/pwm*/duty_cycle` | PWM 控制器直接导出的板卡（备选路径） |
| `softpwm` | `/sys/kernel/duty_cycle` | AP3000M **16GB 版**（GPIO 位翻转软 PWM） |

`PWM_BACKEND=auto`（缺省）时按硬件自动判定，规则与官方 AP3000M 插件一致：

```
读 /sys/block/mmcblk0/size（512B 扇区）
  > 25 000 000（≈12.8 GiB）→ 16GB 版 → softpwm
  否则                      → 依次尝试 hwmon → pwmchip → 回退 softpwm
读不到容量                   → 有硬件 PWM 节点就走硬件，否则按 16GB 版尝试 softpwm
```

### 6.2 H5000M 硬件链路

```
MT7987 PWM1 (50kHz) -> pwm-fan 驱动 -> /sys/class/hwmon/hwmon*/pwm1（0~255）
                                    -> thermal cooling_device（type=pwm-fan）
PWM_BACKEND=hwmon（板级钉死）
温度源：CPU（thermal_zone / lvts）、PHY、Wi-Fi（mt7992 hwmon）、5G 模组（/run/mt5700m/temperature）
```

### 6.3 AP3000M 硬件链路（两版本差异）

依据官方 `LianXia233/luci-app-airpi3000m-fancontrol`（专为 `airpi,ap3000m` 定制）：

| eMMC | 驱动 | PWM 节点 | 说明 |
| --- | --- | --- | --- |
| **16GB** | `airpi-gpio-fan`（GPIO 540 位翻转软 PWM） | `/sys/kernel/duty_cycle` | 主板**未引出**硬件 PWM 引脚；约 66.7 Hz（`period=15000` μs），256 级 |
| **8GB** | 内核 `pwm-fan` | `hwmon/*/pwm1` | 上游 DTS `&fan { pwms = <&pwm 2 40000 0>; }` |

> **为什么软 PWM 驱动要在本仓库编译**
> 上游 `kmod-airpi-gpio-fan` 的 README 记录了实机踩坑：即使 vermagic 完全一致，外部 `.ko`
> 仍可能因 `struct module` 大小/偏移不匹配被内核拒载，报
> `.gnu.linkonce.this_module section size must match ...`，根因是
> `CONFIG_MODULES_TREE_LOOKUP` / `EVENT_TRACING` / `DEBUG_INFO_BTF_MODULES` / `BPF_EVENTS`
> 这四个**配置项**改变了结构体布局（上游 .ko 按官方 SDK 配置编译）。
> 本仓库自行编译内核，模块与 vmlinux 出自同一次 `make`，配置天然一致，该风险归零 —— 因此
> 驱动源码直接 vendored 到 `kernel/files-boards/ap3000m/drivers/hwmon/airpi-gpio-fan/`
> （板级内核源码层），以 `CONFIG_AIRPI_GPIO_FAN=m` 随内核构建。

### 6.4 软件栈（Debian systemd 服务）

- `/usr/local/sbin/router-fancontrol`：控制器脚本（POSIX sh，无额外依赖）
  - 自动曲线（silent/balanced/performance/custom）、手动 PWM、kernel 仅内核保护模式
  - 温度滞回（HYSTERESIS）、降速延迟（DOWN_DELAY）、启动助推（START_PWM/START_BOOST_MS）
  - 传感器 / 曲线校验失败进入故障保护（FAIL_PWM，默认 255）
  - 温度来源 max（CPU/PHY/WiFi/5G 取最高）或 cpu
  - 接管 CPU thermal zone 策略（user_space）前先保存原策略，退出/崩溃时恢复（step_wise 等）
- `/usr/local/sbin/router-fancontrol-modprobe`：**驱动模块预加载钩子**
  - 通用层为空操作；AP3000M 板级层覆盖为「按 eMMC 容量决定是否 modprobe `airpi_gpio_fan`」
  - 由 unit 的 `ExecStartPre` 调用；加载失败返回非 0 → 服务显式失败（而非风扇静默不转）
- `/etc/default/router-fancontrol`：配置文件（等价 OpenWrt UCI；板级层覆盖差异项）
  - 通用项：`ENABLED` / `MODE` / `CURVE*` / `TEMP_SOURCE` / `MANUAL_PWM` / `INTERVAL` 等
  - 后端项：`PWM_BACKEND`（auto/hwmon/pwmchip/softpwm）
  - 软 PWM 项：`AIRPI_FAN_GPIO`（缺省 540）、`AIRPI_FAN_PERIOD`（缺省 15000 μs）、
    `AIRPI_FAN_FORCE`（留空=自动，调试用强制 softpwm/pwm）
- `/etc/systemd/system/router-fancontrol.service`：开机自启（sysinit.target），失败自动重启

### 6.5 常用命令

```bash
systemctl status router-fancontrol              # 服务状态
/usr/local/sbin/router-fancontrol status        # 实时状态（含 pwm_backend / softpwm_loaded 等）
systemctl restart router-fancontrol             # 修改 /etc/default 后生效

# AP3000M 16GB 版诊断：确认软 PWM 链路
cat /sys/block/mmcblk0/size                     # > 25000000 判为 16GB 版
lsmod | grep airpi_gpio_fan                     # 模块是否加载
cat /sys/kernel/duty_cycle                      # 当前占空比（0~255）
echo 128 > /sys/kernel/duty_cycle               # 手动置 50%（应急验证风扇会转）

# 强制覆盖后端（怀疑容量判定有误时）
echo 'AIRPI_FAN_FORCE=softpwm' >> /etc/default/router-fancontrol
systemctl restart router-fancontrol
```
