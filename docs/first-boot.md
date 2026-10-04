# 首次启动指南（不破坏 eMMC 中的 ImmortalWrt）

H5000M 已有可工作的 U-Boot。**不修改 U-Boot**，首次测试优先从 **USB / TFTP** 引导，
保持 eMMC 中的 ImmortalWrt 原样，可随时回退。

> 硬件说明：H5000M 的 DTS 仅定义 eMMC（`mmc0`，non-removable），**没有 SD 卡槽**。
> 因此首启介质为 USB 盘或 TFTP；若原厂 U-Boot 支持 USB 启动（`usb start` / `usbboot`），
> 用 USB 盘最方便。

## 1. 准备启动介质

### 方式 A：USB 盘（推荐，若 U-Boot 支持 USB）

```bash
# 生成镜像文件（无需真实 U 盘）
sudo bash build/make-sd-image.sh --out /path/to/out --img h5000m-debian13-usb.img
# 写入 USB 盘（会覆盖目标盘全部数据！）
sudo dd if=/path/to/out/h5000m-debian13-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
```

镜像布局（GPT）：

```
p1  vfat   64MiB  LABEL=H5000MBOOT  分区名 boot    -> Image / dtb / boot.scr / extlinux
p2  ext4   剩余   LABEL=H5000MROOT  分区名 rootfs  -> Debian 13 rootfs
```

boot 分区中的 **`boot.scr`**（U-Boot 脚本，由 `build/make-boot.sh` 从 `boot/boot.cmd` 生成）
兼容 ImmortalWrt / OpenWrt Filogic 系列 U-Boot 的自动加载流程：U-Boot 会优先执行
`boot.scr`，按 **eMMC → USB** 顺序从各设备 boot 分区加载 `Image` + DTB 后 `booti` 启动。

内核通过 `root=PARTLABEL=rootfs` 定位根文件系统（与 H5000M DTS bootargs 一致）。

### 方式 B：TFTP（需确认原厂 U-Boot 的 tftpboot 支持）

1. 搭建 TFTP 服务器，放置：

```
/tftpboot/
  Image                    # 内核
  mt7987a-hiveton-h5000m.dtb
```

2. 串口进入 U-Boot，执行（示例，以实际 U-Boot 环境变量为准；`booti` 为 ARM64 Image 启动）：

```
setenv ipaddr 192.168.1.2
setenv serverip 192.168.1.1
setenv bootargs console=ttyS0,115200n8 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf
tftpboot 0x46000000 Image
tftpboot 0x44000000 mt7987a-hiveton-h5000m.dtb
booti 0x46000000 - 0x44000000
```

> TFTP 只加载内核/DTB；RootFS 仍需放在 USB / eMMC 上（RootFS 解压方式见第 6 节）。
> 具体加载地址以原厂 U-Boot 内存布局为准。

## 2. 启动流程

```
上电 → U-Boot → 从 USB/TFTP 读取 Image + DTB → Linux 6.18
  → Debian 13 rootfs（systemd）
  → NetworkManager（WAN=eth1 DHCP / LAN=eth0 桥接）
  → h5000m-router-init（创建 br-lan / WAN / Wi-Fi 连接，装配 nftables）
  → dnsmasq（DHCP + DNS + IPv6 RA，192.168.88.1:53）
  → Linux-Router（router-panel-agent + router-panel WebUI）
  → http://192.168.88.1
```

## 3. 默认状态（首次启动即生效）

| 项目 | 默认值 |
| --- | --- |
| WAN | eth1（靠近电源的 2.5G 口），DHCP 自动 IPv4/IPv6 + 默认路由 |
| LAN | eth0（远离电源的 2.5G 口），192.168.88.1/24，IPv6 ULA fd88:88::1/64（RA 通告） |
| DHCP Server | 192.168.88.100 - 192.168.88.200 |
| DNS | dnsmasq 192.168.88.1:53（WAN DHCP DNS + 兜底 1.1.1.1/8.8.8.8/223.5.5.5） |
| NAT / Firewall | nftables 已装配（LAN→WAN masquerade；input 策略 drop） |
| Wi-Fi | 双频 AP（NM 连接，桥接进 br-lan）：`H5000M-2.4G` / `H5000M-5G`，密码 `h5000m123` |
| WebUI | http://192.168.88.1 （admin / 见 /etc/h5000m-initial-credentials） |
| SSH | 端口 22，root / 见 /etc/h5000m-initial-credentials |

## 4. 首次登录

```bash
# 串口或 SSH 登录，读取初始凭据（root 与 WebUI 密码均在构建时随机生成并写入该文件）
cat /etc/h5000m-initial-credentials
```

- WebUI：浏览器打开 http://192.168.88.1 ，用户名 `admin`；
- 登录后请立即在 WebUI「系统 → 安全」修改密码，并 `passwd root` 修改 root 密码。

## 5. 回退到 ImmortalWrt

- USB 启动时不触碰 eMMC 写操作，原 eMMC 中的 ImmortalWrt 不受影响；
- 拔掉 USB 后上电，U-Boot 回到默认引导顺序（eMMC）即可恢复 ImmortalWrt；
- 若要固化 Debian 到 eMMC，请先完整备份 eMMC（`dd if=/dev/mmcblk0 of=emmc-backup.img bs=4M conv=fsync`），再按第 6 节操作。

## 6. 安装 Debian 到 eMMC（可选，需先备份）

> 固化会覆盖 eMMC 中原 ImmortalWrt，**务必先完整备份**：
> `dd if=/dev/mmcblk0 of=emmc-backup.img bs=4M conv=fsync`

### 方式 A：使用 install-emmc.sh（推荐）

在 H5000M 上（Debian 已从 USB 启动）或 USB live 环境执行：

```bash
sudo bash scripts/install-emmc.sh \
  --rootfs debian13-arm64-rootfs.tar.zst \
  --boot-dir out/boot --kernel-dir out/kernel \
  --dev /dev/mmcblk0 [--backup /path/to/emmc-backup.img] [--yes]
```

脚本自动完成：GPT 分区（p1 boot vfat + p2 rootfs ext4）→ 解压 rootfs →
写入 boot.scr / Image / DTB → 可选 fw_setenv 设置 U-Boot 环境变量
（`bootcmd` 优先 `load mmc 0:1 ${scriptaddr} boot.scr; source ${scriptaddr}`）。

### 方式 B：手动

```bash
sudo mkdir -p /mnt/h5000m
# eMMC 需要至少 2 个分区：p1 boot(vfat) + p2 rootfs(ext4, 分区名 rootfs)
# 分区完成后：
sudo tar --numeric-owner --xattrs --acls -xJf debian13-arm64-rootfs.tar.zst -C /mnt/h5000m
sudo cp -a /mnt/h5000m/boot/. /boot-partition/
```

分区名/标签要求：

```
p1: 分区名 boot    （任意 vfat，建议 LABEL=H5000MBOOT）→ 放 Image / dtb / boot.scr / extlinux
p2: 分区名 rootfs  （ext4，建议 LABEL=H5000MROOT）     → 解压 rootfs
```

### 手动引导（U-Boot 控制台）

若 U-Boot 未自动加载 boot.scr，可手动执行：

```
setenv bootargs root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8
setenv scriptaddr 0x47000000
load mmc 0:1 ${scriptaddr} boot.scr
source ${scriptaddr}
```

## 7. 常见检查命令

```bash
ip -br addr                 # 查看接口与地址
ip route                    # 默认路由
nft list ruleset            # 防火墙规则
systemctl status dnsmasq router-panel router-panel-agent h5000m-router-init
nmcli connection show       # WAN / br-lan / H5000M-AP-2G / H5000M-AP-5G
iw dev                      # Wi-Fi 接口
cat /sys/class/thermal/thermal_zone*/temp
cat /etc/h5000m-initial-credentials
```
