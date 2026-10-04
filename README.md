# Hiveton H5000M Debian 13 路由器系统

将 Hiveton H5000M（MediaTek MT7987A）完整移植为 **Debian 13 (Trixie) ARM64** 开箱即用路由器系统，集成 **Linux-Router** WebUI。

- 内核：Linux 6.18.x（含 ImmortalWrt MT7987A 验证补丁 + H5000M DTB）
- 用户空间：Debian 13 Trixie ARM64（官方 stable，systemd）
- 网络控制面：Linux-Router（唯一网络控制面，统一编排 NetworkManager / hostapd / dnsmasq / nftables）
- 验收目标：开机即路由器，`http://192.168.88.1` 管理 WAN / LAN / DHCP / DNS / Wi-Fi / 防火墙 / NAT / 路由

## 硬件支持

| 硬件 | 状态 |
| --- | --- |
| MT7987A SoC（ARM64, Cortex-A53） | ✅ 自定义 6.18 内核 |
| 双 2.5G Ethernet（RTL8221B + 内置 PHY） | ✅ |
| eMMC（8 线，含 factory NVMEM Wi-Fi EEPROM） | ✅ |
| PCIe + MT7992 Wi-Fi（2.4G/5G） | ✅ mt76 |
| USB / UART / GPIO / LED / 按键 | ✅ |
| PWM 风扇 + 智能温控 | ✅ pwm-fan + h5000m-fancontrol（自动曲线 / 手动 / 故障保护） |

**WAN / LAN 物理确认**（依据 ImmortalWrt 已验证配置 + H5000M DTS PHY 定义，非猜测）：

- **LAN = eth0**（远离电源的 2.5G 口，RTL8221B），`192.168.88.1/24`
- **WAN = eth1**（靠近电源的 2.5G 口，内置 PHY），DHCP 自动获取

详见 [docs/architecture.md](docs/architecture.md) 与 [docs/hardware.md](docs/hardware.md)。

## 快速开始（构建）

在 **Linux x86_64/arm64 构建机**上执行：

```bash
# 一键构建（内核 + RootFS + 刷写包）
sudo bash scripts/build.sh --kernel-version 6.18.54 --out /path/to/out

# 分步构建
bash build/build-kernel.sh --kernel-version 6.18.54 --out /path/to/out/kernel
bash build/make-boot.sh --out /path/to/out/boot     # 生成 boot.scr（备用引导，主引导为 p4 FIT）
sudo bash build/build-rootfs.sh --out /path/to/out
sudo bash build/make-sd-image.sh --out /path/to/out   # 生成刷写包：H5000M-debian13-kernel.bin + H5000M-debian13-rootfs.bin
```

构建机依赖：`git curl xz bison flex libssl-dev bc crossbuild-essential-arm64 debootstrap qemu-user-static u-boot-tools`。

## 云编译（GitHub Actions）

仓库已配置 `.github/workflows/build.yml`，推送到 `main`/`master` 或手动触发 `workflow_dispatch`
即自动完成：内核编译（6.18 + MT7987A 补丁）→ boot.scr 生成 → Debian 13 RootFS → 刷写包
（`H5000M-debian13-kernel.bin` → p4、`H5000M-debian13-rootfs.bin` → p5），产物以上传 Artifact 方式交付
（含 `initial-credentials.txt` 首次登录凭据）。

## 分区与启动（复用现有 OpenWrt 布局，不改 U-Boot）

以设备当前正常运行的 OpenWrt 分区布局 / 启动链为**唯一基准**，仅将 Kernel / RootFS 区域
转换为 Debian 13 内容。**BL2 / U-Boot / FIP / u-boot-env / factory / GPT / eMMC 硬件配置一律不动**：

```
p1 u-boot-env | p2 factory | p3 fip | p4 kernel（FIT） | p5 rootfs（ext4）
```

- 主引导：现有 U-Boot 从 **p4** 读取 `H5000M-debian13-kernel.bin`（FIT）并 `bootm`（与 OpenWrt 同型）；
- 根分区：内核以 `root=PARTLABEL=rootfs` 挂载 **p5**（ext4 Debian 13）；
- 启动链：BootROM → BL2 → FIP(U-Boot) → p4 FIT → Kernel → p5 Debian，逐级原样复用。

完整方案见 [docs/debian13-partition-plan.md](docs/debian13-partition-plan.md)。

## 首次启动（兼容当前 U-Boot，不破坏 eMMC 中的 ImmortalWrt）

1. 构建刷写包（`H5000M-debian13-kernel.bin` + `H5000M-debian13-rootfs.bin`）；
2. 进入设备（OpenWrt initramfs / Debian live），**先完整备份**（整盘 dd 或逐分区备份）；
3. 执行 `scripts/install-emmc.sh`，脚本**仅写 p4（FIT）+ p5（ext4）**，其余区域零写入；
4. 重启后由现有 U-Boot 直接引导 Debian 13；WAN 自动 DHCP、LAN 自动 DHCP+DNS+NAT、
   Wi-Fi 默认开启、风扇自动温控、WebUI 就绪；
5. 若要回退 ImmortalWrt，用备份恢复 p4 / p5 即可（p1-p3 与 GPT 未被改动）。

```bash
# 在 H5000M 上（OpenWrt initramfs / Debian live / 已启动的 Debian）执行
sudo bash scripts/install-emmc.sh \
  --kernel-fit out/H5000M-debian13-kernel.bin \
  --rootfs-img out/H5000M-debian13-rootfs.bin \
  --dev /dev/mmcblk0 [--backup-full /tmp/emmc-full.img] [--yes]
```

详见 [docs/first-boot.md](docs/first-boot.md)。

## 目录结构

```
.
├── README.md
├── CHANGELOG.md
├── docs/                        # 文档
│   ├── architecture.md          # 架构与网络职责
│   ├── hardware.md              # 硬件适配
│   ├── debian13-partition-plan.md # 分区方案（复用现有 eMMC 布局）
│   ├── build-guide.md           # 构建指南
│   ├── first-boot.md            # 首次启动（仅写 p4/p5）
│   └── troubleshooting.md       # 故障排查
├── dts/                         # H5000M 设备树（已验证，作为硬件参考）
├── boot/
│   └── boot.cmd                 # U-Boot 备用引导脚本源文件（编译为 boot.scr）
├── build/
│   ├── build-kernel.sh          # 内核构建（6.18.54 + ImmortalWrt 补丁集）
│   ├── build-rootfs.sh          # Debian 13 ARM64 rootfs 构建
│   ├── make-boot.sh             # 生成 boot.scr（备用引导）
│   ├── make-sd-image.sh         # 生成刷写包（p4 FIT + p5 ext4 镜像）
│   ├── kernel-conf/             # 内核 defconfig 片段
│   └── rootfs/
│       └── packages.list        # Debian 13 软件包清单
├── rootfs-overlay/              # rootfs 覆盖层（开箱即用配置）
│   ├── etc/                     # NM / dnsmasq / nftables / sysctl / systemd
│   │   ├── NetworkManager/      # dns=none，接口独占
│   │   ├── dnsmasq.d/           # 唯一 DHCP+DNS(:53)
│   │   ├── nftables.conf        # 唯一防火墙/NAT
│   │   ├── default/             # h5000m-router / h5000m-fancontrol 配置
│   │   └── systemd/system/      # h5000m-router-init / h5000m-fancontrol / router-panel / agent
│   └── usr/local/sbin/          # h5000m-router-init.sh、h5000m-fancontrol（风扇温控）
├── kernel/
│   ├── patches/                 # MT7987A 内核补丁（ImmortalWrt 4 层）
│   ├── files-generic/           # OpenWrt 通用源码（mtdsplit 等）
│   └── files-mediatek/          # OpenWrt mediatek 源码
├── linux-router/vendor/         # Linux-Router 项目源码（vendored）
├── scripts/
│   ├── build.sh                 # 一键构建入口
│   ├── fetch-firmware.py        # 固件获取（跨平台）
│   └── install-emmc.sh          # eMMC 刷入脚本（仅写 p4/p5，兼容当前 U-Boot）
└── .github/workflows/build.yml  # GitHub Actions 云编译
```

## 验收标准

1. H5000M 由现有 U-Boot 从 **p4 FIT** 直接引导 Debian 13，**BL2 / U-Boot / FIP / u-boot-env /
   factory / GPT / eMMC 硬件配置零改动**，分区表 Start/End/PARTLABEL 与迁移前逐项一致；
2. 首次启动即完成：WAN DHCP、LAN 192.168.88.1/24 DHCP+DNS+NAT、IPv4/IPv6 forwarding、
   防火墙、MT7992 Wi-Fi AP（2.4G/5G，与 LAN 同网段）、Linux-Router 与 WebUI 全部自动运行；
3. LAN/Wi-Fi 客户端自动获取 IP/网关/DNS，直接访问 Internet；
4. `http://192.168.88.1` 可管理 WAN、LAN、DHCP、DNS、Wi-Fi、防火墙、NAT、路由；
5. 系统中不存在两个组件同时管理同一网络资源（NetworkManager / hostapd / dnsmasq / nftables
   均由 Linux-Router 统一编排）；
6. 故障隔离：WAN 断网、IPv6 失效、Wi-Fi 失败、单网口异常均不影响其他功能；
   网络服务崩溃由 systemd 自动恢复；
7. 回退能力：备份的 p4 / p5 可随时恢复，恢复后 ImmortalWrt 原样可用（p1-p3 未动）。

## 版本约束

- **Debian 13 (Trixie) ARM64 stable**，不使用 Debian 12 / Testing / Unstable；
- **U-Boot 不修改**：沿用 H5000M 现有 U-Boot，仅适配其引导方式；
- 内核补丁与 DTS 以 ImmortalWrt master（`target/linux/mediatek/`）已验证版本为准；
- 不安装任何 OpenWrt 用户空间组件（OpenWrt 组件仅作内核参考来源）。

## 更新文档

每次内容变更同步维护 [CHANGELOG.md](CHANGELOG.md)。
