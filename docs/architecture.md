# Hiveton H5000M Debian 13 路由器系统 — 架构说明

## 1. 系统总览

```
H5000M 上电
  ↓
U-Boot（现有，不修改）
  ↓
Linux Kernel 6.18.x（自定义，含 MT7987A 补丁 + H5000M DTB）
  ↓
p5 引导层 ext4（root=PARTLABEL=rootfs）：/sbin/init（busybox）
  ├── 挂载 /squashfs/rootfs.squashfs（只读基础系统，zstd）
  ├── 组装 OverlayFS：lower=SquashFS，upper/work=p5 /overlay（可写持久层）
  ├── pivot_root（旧根保留于 /tmpold；失败则进入只读救援模式）
  ↓
Debian 13 (Trixie) ARM64 RootFS（systemd，根 = OverlayFS merged）
  ↓
基础网络初始化（h5000m-router-init.service）
  ├── NetworkManager（管理网口、WAN/LAN bridge 与 Wi-Fi AP profiles）
  ├── dnsmasq（DHCP Server + DNS Forwarder + IPv6 RA，由 systemd 后续启动）
  └── nftables（NAT / 防火墙）
Linux-Router（router-panel + agent，提供 WebUI 与网络管理接口）
  ↓
WebUI http://192.168.88.1
```

## 2. 存储架构：只读根（SquashFS）+ OverlayFS 持久层

### 2.1 p5 引导层布局

p5（PARTLABEL=`rootfs`，~7.2 GiB ext4）不再是整分区 Debian rootfs，而是**引导层**：

```
p5 引导层 ext4
├── /sbin/init                  busybox 引导脚本（挂 SquashFS → OverlayFS → pivot_root → systemd）
├── /usr/bin/busybox            静态 busybox（Debian busybox-static arm64）
├── /squashfs/rootfs.squashfs   Debian 13 只读基础系统（zstd 压缩，~120 MiB）
├── /overlay/{upper,work,merged} OverlayFS upper/work/挂载点（p5 剩余空间 = 持久化数据）
└── /boot/                      备用引导文件（DTB / extlinux.conf / boot.scr）
```

### 2.2 启动序列（/sbin/init）

```
内核挂 p5 为根（root=PARTLABEL=rootfs，与旧方案内核行为完全一致）
  ↓ /sbin/init（busybox 静态，无 glibc 依赖）
mount -o ro /squashfs/rootfs.squashfs → /sq
  ↓
mount -t overlay -o lowerdir=/sq,upperdir=/overlay/upper,workdir=/overlay/work /overlay/merged
  ↓
cd /overlay/merged && pivot_root . tmpold    # 旧根（p5 引导层）保留于 /tmpold
  ↓                                          # → /tmpold/squashfs/ 即在线升级用的 SquashFS 路径
mount --move /tmpold/{dev,proc,sys} → 新根
  ↓
exec busybox env -i /sbin/init               # 交棒 systemd（Debian 正常启动）
```

### 2.3 关键保证

| 特性 | 机制 |
| --- | --- |
| 系统完整性 | 基础系统在 SquashFS 中**只读不可变**，意外断电/写坏不影响系统本体 |
| 配置持久化 | `/etc` `/var` `/opt` 等全部写入经 OverlayFS 落 p5 upper，重启保留 |
| 在线升级 | 仅替换 `/tmpold/squashfs/rootfs.squashfs` + 刷 p4 FIT；overlay 数据零丢失；旧版自动备份 `.bak`（mv 回即回退） |
| 空间在线扩容 | `h5000m-grow-rootfs.service`（oneshot）首启 `findfs PARTLABEL=rootfs` + `resize2fs` 把引导层扩到 ~7.2 GiB |
| 防砖救援 | OverlayFS 组装失败 → **只读救援模式**：直接以 SquashFS 为根 + tmpfs upper，可 SSH 登录修复 overlay |

### 2.4 体积收益

| 产物 | 旧方案（整分区 ext4） | 新方案（SquashFS + 引导层） |
| --- | --- | --- |
| rootfs.bin（p5 镜像） | 540 MiB（空闲空间封进固件） | ~152 MiB（引导层，p5 剩余空间刷后首启自动扩容） |
| sysupgrade.bin（上传 /tmp） | 579 MiB（≈600 MiB RAM 门槛边缘） | **~164 MiB**（缩 72%） |
| 只读基础系统 | —（无） | rootfs.squashfs ~120 MiB（zstd -19，514 MiB 树） |

## 3. 硬件适配

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

### 3.1 WAN / LAN 物理确认

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

## 4. 网络管理职责（唯一控制者）

### 4.1 职责表

| 功能 | 唯一控制者 | 底层实现 |
| --- | --- | --- |
| 首启默认 WAN/LAN/Bridge | h5000m-router-init | NetworkManager / Linux bridge |
| WebUI 发起的网络变更 | Linux-Router agent | NetworkManager / nftables / dnsmasq |
| Wi-Fi AP | 初始化脚本创建默认 profile；NetworkManager 管理 | wpa_supplicant AP 模式（hostapd 预装但默认不启用） |
| Wi-Fi 驱动 | Linux Kernel | mt76 |
| DHCP | dnsmasq | dnsmasq |
| DNS | dnsmasq | dnsmasq（:53） |
| NAT / Firewall | nftables 配置；WebUI agent 提供管理入口 | nftables |
| IPv4/IPv6 forwarding | sysctl 配置 | 内核 |
| 路由表 | NetworkManager / Linux-Router agent | iproute2 / 内核 |
| 服务生命周期 | systemd | systemd unit |
| WebUI | Linux-Router | Gunicorn + Flask |
| 配置持久化 | Linux-Router | /var/lib/linux-router |

### 4.2 组件边界

- 默认 AP 使用 `H5000M-AP-2G` / `H5000M-AP-5G` NetworkManager profiles，并桥接至 `br-lan`；不要同时启用 hostapd 管理相同无线接口。
- Linux-Router 中 `DebianRouterHotspot` 是另一种可选热点功能/profile，不是系统首启 AP 的名称；启用前应确认接口/PHY 能力和与默认 AP 的并发关系。
- ❌ systemd-networkd / dhcpcd 管理任何接口（Debian 安装阶段即禁用）
- ❌ systemd-resolved 占用 :53（禁用，DNS 统一交给 dnsmasq）
- ❌ firewalld / ufw（不安装，nftables 为唯一防火墙）
- ❌ 第二套 DHCP Server（仅 dnsmasq 一个 DHCP 实例）

### 4.3 DNS 架构

```
LAN 客户端 ──► 192.168.88.1:53 ──► dnsmasq ──► WAN 上游 DNS（自动获取 / 8.8.8.8 兜底）
```

## 5. 默认网络结构

```
Internet
   ├── WAN eth1（靠近电源的 2.5G 口，DHCP；metric 100，优先）
   └── WAN-5G eth2（MT5700M USB 网卡，DHCP；metric 200，备用）
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

## 6. 服务启动顺序（systemd 依赖编排）

```
内核挂 p5 引导层 → /sbin/init（busybox）：SquashFS → OverlayFS → pivot_root → 救援模式兜底
  ↓
systemd
 ├── sys-kernel 固件加载（mt7992 / mt7987 phy 固件，由内核按需加载）
 ├── h5000m-grow-rootfs.service（oneshot：首启 findfs + resize2fs 在线扩容 p5 至 ~7.2 GiB，marker 防重复）
 ├── h5000m-fancontrol.service（sysinit.target：PWM 风扇温控，温度曲线/手动/故障保护）
 ├── NetworkManager（WAN/LAN 网口管理）
 ├── h5000m-router-init.service（OneShot：创建 WAN/eth2 备用 WAN/LAN/br-lan/Wi-Fi profiles，装配 nftables）
 │    └─ 不阻塞：每步失败仅告警继续，绝不阻止后续步骤
 ├── dnsmasq.service（After/Requires=h5000m-router-init：其完成后启动；DHCP + DNS + IPv6 RA）
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
- **USB WAN 晚到**：`WAN-5G` profile 首启即创建并设为 autoconnect；MT5700 hook 只请求 NetworkManager 激活，不启动第二个 DHCP 客户端。
- **Wi-Fi 晚到**：先创建 AP profiles；驱动/接口晚于初始化服务出现时，由 NetworkManager autoconnect。
- **自动恢复**：按各 unit 配置重启策略；oneshot 初始化服务不设置通用 `Restart=on-failure`。

## 7. 数据面 / 控制面分离

| 层 | 归属 |
| --- | --- |
| Web 管理面 | Linux-Router（WebUI → agent → 调用网络服务） |
| 首启编排 | `h5000m-router-init.service`（默认 NetworkManager profiles 与 nftables 规则） |
| 运行环境 | Debian 13 / systemd |
| 数据面 | Linux kernel（转发、NAT 由 nftables 注入） |
| 底层执行组件 | NetworkManager、wpa_supplicant、dnsmasq、nftables、iproute2（hostapd 预装备用） |

用户只通过 WebUI 管理网络，不要求手动编辑 `/etc/network/interfaces`、`/etc/NetworkManager/*`、`/etc/dnsmasq.conf`、`/etc/hostapd/*`、`/etc/nftables.conf` 完成日常配置。

## 8. 故障隔离矩阵

| 故障 | 影响 | 保证 |
| --- | --- | --- |
| WAN 无网络 | LAN 照常 | dnsmasq/NAT/WebUI 不依赖 WAN 可达性 |
| IPv6 不可用 | IPv4 不受影响 | IPv4/IPv6 分开配置，WAN IPv6 失败不写默认路由 |
| Wi-Fi 启动失败 | 有线 LAN 正常 | AP profile 可晚连接；初始化不等待无线接口，不阻塞 br-lan |
| 单网口异常 | 另一网口正常 | 两接口独立 PHY/MAC，NetworkManager 分别管理 |
| DHCP 异常 | WebUI 仍在 | WebUI 依赖 agent，不依赖 dnsmasq |
| WebUI 异常 | 转发仍工作 | 内核转发 + nftables 已由 bringup 一次性装配 |
| Linux-Router agent 崩溃 | systemd 自动重启 | agent unit 使用 Restart=always + RestartSec=3；WebUI unit 使用 Restart=on-failure |
| OverlayFS 组装失败 | 只读救援模式 | /sbin/init 自动降级：SquashFS 根 + tmpfs upper，SSH 可登录修复 |
| 重启 | 配置恢复 | 写入经 OverlayFS 落 p5 upper 持久保留 + Linux-Router 持久化配置 + NM connection 持久化 |
