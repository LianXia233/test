# 首次启动指南（复用现有 eMMC 分区，U-Boot 不改）

H5000M 已有可工作的 U-Boot（p3 `fip`）。**不修改 U-Boot / GPT / p1-p3 / eMMC 硬件配置**，
Debian 13 与 OpenWrt 共用完全相同的分区布局与启动链：

```
p1 u-boot-env | p2 factory | p3 fip | p4 kernel（FIT） | p5 rootfs（引导层 ext4：init + busybox + SquashFS + overlay）
```

- 主引导：现有 U-Boot 从 **p4** 读取 `H5000M-debian13-kernel.bin`（FIT）并 `bootm`；
- 根分区：内核以 `root=PARTLABEL=rootfs` 挂载 **p5**（引导层 ext4），随后 p5 上的
  `/sbin/init` 挂载只读基础系统 `rootfs.squashfs`、组装 OverlayFS（可写层 = p5 剩余空间，
  重启持久）后交棒 systemd。

完整方案见 [docs/debian13-partition-plan.md](debian13-partition-plan.md)。

> 硬件说明：H5000M 的 DTS 仅定义 eMMC（`mmc0`，non-removable），**没有 SD 卡槽**。
> 刷写/启动介质一律为 eMMC 本身；如需先在 USB/TFTP 上试运行，见第 6 节备用方案。

## 1. 准备工作（构建产物）

在 Linux 构建机生成刷写包（见 [docs/build-guide.md](build-guide.md)）：

```
out/H5000M-debian13-kernel.bin        # → p4
out/H5000M-debian13-rootfs.bin   # → p5（引导层：init + busybox + rootfs.squashfs + overlay）
out/rootfs/rootfs.squashfs           # 只读基础系统（在线升级用，包含在 rootfs.bin 内）
out/rootfs/initial-credentials.txt
```

## 2. 备份（必须先做）

进入设备（OpenWrt initramfs / Debian live / 已启动的 Debian），先完整备份：

```bash
# 整盘备份（8 GiB，最保险）
dd if=/dev/mmcblk0 of=/tmp/emmc-full.img bs=4M conv=fsync status=progress

# 或仅备份关键区域 + 将被覆盖的 p4/p5（更小）
mkdir -p /tmp/bk
for i in 1 2 3 4 5; do
  dd if=/dev/mmcblk0p$i of=/tmp/bk/p$i.img bs=4M conv=fsync status=progress
done
sgdisk --backup=/tmp/bk/gpt.bin /dev/mmcblk0
```

备份文件务必拷贝到 **PC / U 盘**，不要只放在 eMMC 上。

## 3. 刷写 Debian 到 eMMC（仅写 p4 / p5）

```bash
# 方法一：引导层 ext4 镜像（推荐，SquashFS+OverlayFS 完整架构）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/H5000M-debian13-kernel.bin \
  --rootfs-img /path/to/out/H5000M-debian13-rootfs.bin \
  --dev /dev/mmcblk0 --yes

# 方法二：rootfs tar.zst（兼容模式：p5 直接展开纯 Debian 树，无只读根/在线升级能力）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/H5000M-debian13-kernel.bin \
  --rootfs /path/to/out/rootfs/debian13-arm64-rootfs.tar.zst \
  --dev /dev/mmcblk0 --yes

# 方法三：在线升级（仅当设备已在运行 SquashFS+OverlayFS 架构；不重启、配置/数据全保留）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/H5000M-debian13-kernel.bin \
  --rootfs-squashfs /path/to/out/rootfs/rootfs.squashfs \
  --dev /dev/mmcblk0 --yes
```

脚本只做：**校验现有分区表（只读）→ 写 p4（FIT）→ 写 p5 → 校验**。
不会 `mklabel`、不会重排分区、不会触碰 p1-p3 / GPT / U-Boot / eMMC 硬件配置。

- 方法一：p5 格式化为引导层 ext4（`mkfs.ext4 -d` 内容直写），e2fsck 校验；
- 方法二：p5 格式化后解压 tar（整层重写 = 恢复出厂，overlay 旧配置不保留）；
- 方法三：**在线升级模式**——复制新 `rootfs.squashfs` 到 p5（经 `/tmpold/squashfs/` 路径）→
  hsqs 魔数校验 → 旧版 `mv` 为 `rootfs.squashfs.bak` → 新版原子替换 → 回读校验。
  运行中的系统继续使用旧 SquashFS（overlay 引用旧 inode，安全），**重启后新系统生效**；
  回退 = `mv /tmpold/squashfs/rootfs.squashfs.bak rootfs.squashfs`（挂载 p5 后操作）。

## 4. 启动流程

```
上电 → BootROM → BL2 → FIP(U-Boot) → U-Boot 读 p4 FIT → bootm
  → Linux 6.18 → root=PARTLABEL=rootfs 挂载 p5（引导层 ext4）
  → /sbin/init（busybox）：挂 /squashfs/rootfs.squashfs（ro）
      → 组装 OverlayFS（lower=SquashFS，upper/work=/overlay）
      → pivot_root（旧根保留于 /tmpold；失败则进入只读救援模式：SquashFS 根 + tmpfs，可 SSH 修复）
  → systemd（Debian 13）
  → h5000m-grow-rootfs（首启 resize2fs 在线扩容 p5 至 ~7.2 GiB）
  → NetworkManager（WAN=eth1 DHCP / LAN=eth0 桥接）
  → h5000m-router-init（创建 br-lan / WAN / Wi-Fi 连接，装配 nftables）
  → dnsmasq（DHCP + DNS + IPv6 RA，192.168.88.1:53）
  → h5000m-fancontrol（PWM 风扇温控）
  → Linux-Router（router-panel-agent + router-panel WebUI）
  → http://192.168.88.1
```

## 5. 默认状态（首次启动即生效）

| 项目 | 默认值 |
| --- | --- |
| WAN | eth1（靠近电源的 2.5G 口），DHCP 自动 IPv4/IPv6 + 默认路由 |
| LAN | eth0（远离电源的 2.5G 口），192.168.88.1/24，IPv6 ULA fd88:88::1/64（RA 通告） |
| DHCP Server | 192.168.88.100 - 192.168.88.200 |
| DNS | dnsmasq 192.168.88.1:53（WAN DHCP DNS + 兜底 1.1.1.1/8.8.8.8/223.5.5.5） |
| NAT / Firewall | nftables 已装配（LAN→WAN masquerade；input 策略 drop） |
| Wi-Fi | 双频 AP（NM 连接，桥接进 br-lan）：2.4G / 5G 同名 `OWRT`，密码 `12345678` |
| WebUI | http://192.168.88.1 （admin / password，见 /etc/h5000m-initial-credentials） |
| SSH | 端口 22，root / password（仅局域网访问，WAN 侧不放行；见 /etc/h5000m-initial-credentials） |
| LED | 参考官方固件：启动早期蓝色状态灯快闪；系统就绪后熄灭（h5000m-led.service 编排） |

## 6. 首次登录

```bash
# 串口或 SSH 登录，读取初始凭据（root / WebUI 默认密码均为 password，已写入该文件）
cat /etc/h5000m-initial-credentials
```

- WebUI：浏览器打开 http://192.168.88.1 ，用户名 `admin`；
- 登录后请立即在 WebUI「系统 → 安全」修改密码，并 `passwd root` 修改 root 密码。

## 7. 验证

```bash
cat /proc/cmdline            # root=PARTLABEL=rootfs rootwait ...
findmnt /                    # overlay（upperdir=/overlay/upper ...），lowerdir 含 /sq
findmnt /sq                  # /dev/mmcblk0p5[/squashfs/rootfs.squashfs] squashfs ro
df -h /                      # 根可写容量 ≈ p5 引导层剩余空间（首启扩容后 ~7.2 GiB）
lsblk -o NAME,PARTLABEL,FSLABEL,SIZE,MOUNTPOINT
ip -br addr                 # eth0 / eth1 / br-lan
systemctl status h5000m-grow-rootfs h5000m-fancontrol h5000m-router-init dnsmasq router-panel
curl -sI http://192.168.88.1
```

## 8. 回退到 ImmortalWrt

```bash
# 恢复整盘
dd if=/tmp/emmc-full.img of=/dev/mmcblk0 bs=4M conv=fsync status=progress

# 或仅恢复 p4/p5（若 p1-p3 与 GPT 未被改动）
dd if=/tmp/bk/p4.img of=/dev/mmcblk0p4 bs=4M conv=fsync status=progress
dd if=/tmp/bk/p5.img of=/dev/mmcblk0p5 bs=4M conv=fsync status=progress
```

## 9. 备用方案：USB / TFTP 试运行（不破坏 eMMC）

> 若想在固化前先验证 Debian，可从 USB / TFTP 引导；原厂 U-Boot 需支持相应启动方式。

### 方式 A：USB 盘

> 默认刷写包（`H5000M-debian13-kernel.bin` + `H5000M-debian13-rootfs.bin`）面向 **eMMC 复用现有分区**，
> 不再生成通用 USB/SD 镜像。如需 USB 试运行，按下述手动步骤制作（仅用于临时验证盘）。
> 注意：tar 直接解压为**纯 Debian 树（兼容模式）**，无引导层/只读根；
> 如需在 USB 上体验完整 SquashFS+OverlayFS 架构，可 `dd if=H5000M-debian13-rootfs.bin of=/dev/sdX1`。

```bash
# 在 PC 上制作 USB 试运行盘（警告：以下命令仅针对临时 USB 盘 /dev/sdX，
# 绝不可以在设备的 eMMC /dev/mmcblk0 上执行！）
sudo sgdisk --zap-all /dev/sdX
sudo sgdisk -n 1:0:0 -t 1:8300 -c 1:rootfs /dev/sdX
sudo mkfs.ext4 -L rootfs /dev/sdX1
sudo mount /dev/sdX1 /mnt/usb
sudo tar --numeric-owner --xattrs --acls -I zstd \
  -xf /path/to/out/rootfs/debian13-arm64-rootfs.tar.zst -C /mnt/usb
sudo cp /path/to/out/kernel/Image /mnt/usb/boot/Image
sudo cp /path/to/out/kernel/mt7987a-hiveton-h5000m.dtb /mnt/usb/boot/
sudo cp /path/to/out/boot/boot.scr /mnt/usb/boot/ 2>/dev/null || true
sync && sudo umount /mnt/usb
```

> 要求 U-Boot 支持 USB 启动（`bootflow scan` 自动尝试 `/boot/boot.scr` / extlinux）。
> 若 U-Boot 不支持 USB 引导，请使用方式 B（TFTP）。

### 方式 B：TFTP（需确认原厂 U-Boot 支持）

```
setenv ipaddr 192.168.1.2
setenv serverip 192.168.1.1
setenv bootargs earlycon=uart8250,mmio32,0x11000000 console=ttyS0,115200n8 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf
tftpboot 0x46000000 Image
tftpboot 0x44000000 mt7987a-hiveton-h5000m.dtb
booti 0x46000000 - 0x44000000
```

> TFTP 只加载内核/DTB；RootFS 仍需在 USB / eMMC 上（解压方式见 build-guide）。

## 10. 手动引导（U-Boot 控制台，应急）

若自动引导失败，串口进入 U-Boot 手动引导：

```bash
# 主路径：从 p4 加载 FIT 并 bootm（与 OpenWrt 相同）
setenv bootargs 'earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8'
load mmc 0:4 0x46000000
bootm 0x46000000

# 兜底路径：从 p5 的 /boot 加载备用镜像（ext4，distro boot 用）
load mmc 0:5 0x47000000 /boot/boot.scr
source 0x47000000
```
