# Hiveton H5000M Debian 13 路由器系统 — 架构说明

## 1. 系统总览

```
H5000M 上电
  ↓
U-Boot（现有，不修改）
  ↓
Linux Kernel 6.18.x（自定义，含 MT7987A 补丁 + H5000M DTB）
  ↓
Debian 13 (Trixie) ARM64 RootFS（systemd）
  ↓
Linux-Router（唯一网络控制面 / 路由编排层）
  ├── NetworkManager（WAN/LAN 网口基础管理，受 Linux-Router 编排）
  ├── hostapd（MT7992 Wi-Fi AP 底层）
  ├── dnsmasq（DHCP Server + DNS Forwarder）
  └── nftables（NAT / 防火墙唯一后端）
  ↓
WebUI http://192.168.88.1
```

## 2. 硬件适配

| 硬件 | 内核支持方式 | 说明 |
| --- | --- | --- |
| MediaTek MT7987A SoC | 自定义 6.18 内核 + ImmortalWrt SDK 补丁 | pinctrl / clk / eth / phy / pwm / thermal / cpufreq 补丁 |
| 双 2.5G Ethernet | mtk_eth_soc（补丁） | gmac0 = eth0（RTL8221B），gmac1 = eth1（内置 PHY） |
| RTL8221B PHY | phy_realtek（mainline） | mdio addr 1，C45，GPIO42 reset |
| 内置 2.5G PHY | mtk-2p5ge（补丁） | mdio addr 15，需固件 i2p5ge-phy-*.bin |
| PCIe + MT7992 Wi-Fi | mt76（mainline 6.18 已支持） | pcie0，需 mt7992 固件 |
| eMMC | mmc-mtk（mainline） | 8 线，含 factory 分区 NVMEM（Wi-Fi EEPROM） |
| USB | xhci-mtk（mainline） | ssusb |
| UART | 8250 (mainline) | 115200n8，earlycon |
| GPIO / LED / 按键 | gpio-leds / gpio-keys（mainline） | Reset = GPIO1，WPS = GPIO0 |
| PWM 风扇 | pwm-mediatek（补丁）+ pwm-fan | pwm1 50kHz；`/sys/class/hwmon/*/pwm1` |
| 风扇温控 | h5000m-fancontrol（systemd） | 自动曲线 / 手动 PWM / 故障保护 |

### 2.1 WAN / LAN 物理确认

依据 ImmortalWrt 官方已验证配置（`target/linux/mediatek/filogic/base-files/etc/board.d/02_network`）：

```
hiveton,h5000m)  →  ucidef_set_interfaces_lan_wan eth0 eth1
```

配合 H5000M DTS 中的 PHY 定义：

- **eth0（gmac0，2500base-x）**：外接 **RTL8221B-VB-CG** PHY（DTS 注释：*away from power*，远离电源）→ **LAN**
- **eth1（gmac1，internal）**：**内置 2.5G Ethernet PHY**（DTS 注释：*near power*，靠近电源）→ **WAN**

结论（**不是按 eth0/eth1 名称猜测，而是按 PHY/MAC/物理位置确认**）：

| 物理网口位置 | 内核接口 | 角色 |
| --- | --- | --- |
| 远离电源的 2.5G 口（RTL8221B） | eth0 | **LAN**（192.168.88.1/24） |
| 靠近电源的 2.5G 口（内置 PHY） | eth1 | **WAN**（DHCP 自动获取） |

MAC 分配规则（沿用 ImmortalWrt）：LAN MAC 由 eMMC CID 生成，WAN MAC = LAN MAC + 1。

## 3. 网络管理职责（唯一控制者）

### 3.1 职责表

| 功能 | 唯一控制者 | 底层实现 |
| --- | --- | --- |
| WAN/LAN 角色 | Linux-Router | NetworkManager / iproute2 |
| 网口 | Linux-Router | NetworkManager / iproute2 |
| Bridge | Linux-Router | Linux bridge |
| Wi-Fi AP | Linux-Router | NetworkManager/wpa_supplicant（hostapd 预装备用） |
| Wi-Fi 驱动 | Linux Kernel | mt76 |
| DHCP | Linux-Router | dnsmasq |
| DNS | Linux-Router | dnsmasq（:53） |
| NAT | Linux-Router | nftables |
| Firewall | Linux-Router | nftables |
| IPv4/IPv6 forwarding | Linux-Router | 内核 sysctl |
| 路由表 | Linux-Router | iproute2 / 内核 |
| 服务生命周期 | systemd | systemd unit |
| WebUI | Linux-Router | Gunicorn + Flask |
| 配置持久化 | Linux-Router | /var/lib/linux-router |

### 3.2 明确的禁止项

- ❌ NetworkManager 自行创建热点（Linux-Router 创建 `DebianRouterHotspot` NM 连接时也禁用自己的独立 DHCP，改用 dnsmasq）
- ❌ systemd-networkd / dhcpcd 管理任何接口（Debian 安装阶段即禁用）
- ❌ systemd-resolved 占用 :53（禁用，DNS 统一交给 dnsmasq）
- ❌ firewalld / ufw（不安装，nftables 为唯一防火墙）
- ❌ 第二套 DHCP Server（仅 dnsmasq 一个 DHCP 实例）

### 3.3 DNS 架构

```
LAN 客户端 ──► 192.168.88.1:53 ──► dnsmasq ──► WAN 上游 DNS（自动获取 / 8.8.8.8 兜底）
```

## 4. 默认网络结构

```
Internet
   │
   ▼
WAN（eth1，靠近电源的 2.5G 口，DHCP 自动获取 IPv4/IPv6）
   │
┌────┴─────┐
│ Debian 13│
│ Linux-   │
│ Router   │
└────┬─────┘
     │
LAN（eth0，远离电源的 2.5G 口，192.168.88.1/24）
     │
  br-lan（Linux Bridge）
     ├── eth0（LAN 有线）
     └── Wi-Fi AP（MT7992 2.4G/5G，同一二层网络）
            │
            └── Wi-Fi 客户端从 LAN DHCP 获取地址、使用 LAN 网关
```

**Wi-Fi 与 LAN 同网段**：Wi-Fi AP（MT7992 2.4G/5G）作为 `br-lan` 的从属接口（NM 连接 `H5000M-AP-2G/5G`，AP 模式由 wpa_supplicant 提供），与有线 LAN 处于同一二层网络；由同一 dnsmasq 分配 192.168.88.x 地址，可访问 Internet 和 LAN 内设备，不存在独立的 Wi-Fi NAT 网络。

> Wi-Fi AP 后端说明：Linux-Router 与开机初始化均通过 NetworkManager 管理 Wi-Fi AP（wpa_supplicant 实现 AP 模式）。`hostapd` 已预装，作为独立 AP 后端备用（用户可禁用 NM AP 后改用 `hostapd@.service`），但系统默认不启用 hostapd.service，避免与 NM 争抢接口。

## 5. 服务启动顺序（systemd 依赖编排）

```
systemd
 ├── sys-kernel 固件加载（mt7992 / mt7987 phy 固件，由内核按需加载）
 ├── h5000m-fancontrol.service（sysinit.target：PWM 风扇温控，温度曲线/手动/故障保护）
 ├── NetworkManager（WAN/LAN 网口管理）
 ├── h5000m-router-init.service（OneShot：创建 WAN/LAN/br-lan/Wi-Fi 连接，装配 nftables）
 │    └─ 不阻塞：每步失败仅告警继续，绝不阻止后续步骤
 ├── dnsmasq.service（Requires=h5000m-router-init：等待 br-lan 建立；DHCP + DNS + IPv6 RA）
 ├── router-panel-agent.service（Linux-Router 代理，root 权限执行网络操作）
 ├── router-panel.service（WebUI，Gunicorn :80；Requires=router-panel-agent）
 └── ssh / systemd-timesyncd
```

> 风扇服务独立于网络栈（`DefaultDependencies=no`，`After=systemd-modules-load.service`），
> 在 sysinit 阶段尽早接管 PWM；DTS 已删除内核风扇 cooling-maps，PWM 完全由用户空间独占，
> 退出/崩溃时恢复内核 thermal 策略，critical 温度保护始终由内核 trips 兜底。

关键点：

- **WAN 获取失败不阻塞 LAN**：NetworkManager 对 WAN 使用 DHCP，失败时 LAN 侧服务照常运行。
- **Wi-Fi 失败不阻塞有线**：Wi-Fi AP 为独立 NM 连接（H5000M-AP-2G/5G），创建或启动失败仅告警。
- **DHCP 失败不阻塞 WebUI**：dnsmasq 独立服务，WebUI 服务依赖的是 agent，不依赖 dnsmasq。
- **WebUI 失败不阻塞转发**：内核转发由 sysctl + nftables 生效，与 WebUI 无关。
- **自动恢复**：所有服务 `Restart=on-failure` + `RestartSec=3`，systemd 自动拉起。

## 6. 数据面 / 控制面分离

| 层 | 归属 |
| --- | --- |
| 控制面 | Linux-Router（WebUI 修改 → agent → 调用 NetworkManager/nftables/dnsmasq/hostapd） |
| 运行环境 | Debian 13 / systemd |
| 数据面 | Linux kernel（转发、NAT 由 nftables 注入） |
| 底层执行组件 | NetworkManager、hostapd、dnsmasq、nftables、iproute2 |

用户只通过 WebUI 管理网络，不要求手动编辑 `/etc/network/interfaces`、`/etc/NetworkManager/*`、`/etc/dnsmasq.conf`、`/etc/hostapd/*`、`/etc/nftables.conf` 完成日常配置。

## 7. 故障隔离矩阵

| 故障 | 影响 | 保证 |
| --- | --- | --- |
| WAN 无网络 | LAN 照常 | dnsmasq/NAT/WebUI 不依赖 WAN 可达性 |
| IPv6 不可用 | IPv4 不受影响 | IPv4/IPv6 分开配置，WAN IPv6 失败不写默认路由 |
| Wi-Fi 启动失败 | 有线 LAN 正常 | hostapd 独立服务，不阻塞 br-lan |
| 单网口异常 | 另一网口正常 | 两接口独立 PHY/MAC，NetworkManager 分别管理 |
| DHCP 异常 | WebUI 仍在 | WebUI 依赖 agent，不依赖 dnsmasq |
| WebUI 异常 | 转发仍工作 | 内核转发 + nftables 已由 bringup 一次性装配 |
| Linux-Router 崩溃 | 自动恢复 | Restart=on-failure + RestartSec=3 |
| 重启 | 配置恢复 | Linux-Router 持久化配置 + NM connection 持久化 |
