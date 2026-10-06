# Hiveton H5000M（MT7987A + eMMC）Debian 13 分区方案

> 原则：以设备当前正在正常运行的 **OpenWrt 分区布局 / 启动链 / DTS** 为唯一基准。
> 不重新设计分区方案；仅将 OpenWrt 的 Kernel / RootFS / 可写空间转换为 Debian 13 所需内容。
> **任何需要修改 BL2 / U-Boot / FIP / u-boot-env / factory 的方案均为不合格。**

---

## 1. 当前 OpenWrt 完整分区表

实机为 **约 14.6 GiB eMMC**（30,535,680 个 512-byte sectors）；分区以设备当前 `sgdisk -p /dev/mmcblk0` 为准。
以下为当前正在运行的 OpenWrt 布局（GPT）：

| 分区 | PARTLABEL | Start (sector) | End (sector) | 大小 | 当前内容 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| p1 | `u-boot-env` | 8192 | 10239 | 1 MiB | U-Boot 环境变量 | **不可修改** |
| p2 | `factory` | 10240 | 14335 | 2 MiB | 出厂校准 / Wi-Fi EEPROM（NVMEM） | **不可修改** |
| p3 | `fip` | 14336 | 22527 | 4 MiB | BL2 + FIP（U-Boot 本体） | **不可修改** |
| p4 | `kernel` | 22528 | 83967 | 30 MiB | OpenWrt FIT 镜像（`fit.itb`） | **复用**（写入 Debian FIT） |
| p5 | `rootfs` | 83968 | 15268830 | ~7.24 GiB | OpenWrt SquashFS + overlay | **复用**（改为引导层 ext4：init + busybox + SquashFS + overlay） |

> 主 GPT：LBA 0（保护 MBR）/ LBA 1（GPT 头）/ LBA 2–33（分区表）。
> 备份 GPT：磁盘末尾最后 33 个扇区（LBA-34 … LBA-1）。
> sector 大小 512 B；实机 p1 从 sector 8192 开始，`1 sector = 512 B`。主 GPT 可读，但实机备份 GPT 校验失败；不要自动改写或重建 GPT。

### 1.1 关键证据（来自当前运行环境）

- `/proc/cmdline`（OpenWrt 当前）：`root=PARTLABEL=rootfs rootwait …`
- DTS `chosen` 节点（[mt7987a-hiveton-h5000m.dts](/workspace/dts/mt7987a-hiveton-h5000m.dts)）：

```
chosen {
    bootargs = "earlycon=uart8250,mmio32,0x11000000
                root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf";
};
```

- 根文件系统定位方式：**`root=PARTLABEL=rootfs`**（内核按 GPT PARTLABEL 解析 `/dev/mmcblk0p5`）。
- eMMC `mmc0` 节点仅定义 `factory` 分区的 NVMEM（Wi-Fi EEPROM），**不含任何固定分区表定义** —— 分区完全由 GPT 控制，因此 U-Boot / 内核均通过 GPT 的 PARTLABEL 工作。

### 1.2 官方固件实测验证（重要）

已下载官方固件 `H5000M-.-sysupgrade.bin`（ImmortalWRT SNAPSHOT，mediatek/filogic，
aarch64_cortex-a53）并实测分析，全部结论与上述分区方案一致，并修正/确认关键参数：

| 项目 | 实测结果（来自官方 sysupgrade.bin） | 与方案一致性 |
| --- | --- | --- |
| 固件格式 | 新式 sysupgrade **tar 包**：`sysupgrade-hiveton_h5000m/{CONTROL,kernel,root}` | — |
| CONTROL | `BOARD=hiveton_h5000m` | 确认板级标识 |
| kernel 分区内容（p4） | **裸 FIT 镜像**，魔数 `d00dfeed`；`mkimage -l` 显示：`ARM64 OpenWrt FIT`，内核 **LZMA 压缩**，**Load/Entry = 0x46000000** | 确认主引导为 p4 FIT（bootm）；官方 FIT 为 0x40000000，本方案必须用 0x46000000：U-Boot 自身常驻 0x41e00000（TEXT_BASE+POSITION_INDEPENDENT），bootm 要求 [0x40000000, 0x40000000+解压尺寸) 整段空闲（窗口仅 30MiB），本内核解压后 35~45MiB 越界 |
| FIT 内核版本 | `Linux-6.18.52`（本方案构建 6.18.x 同系列） | ✅ |
| FIT 哈希 | 每镜像带 `hash-1(crc32)` + `hash-2(sha1)` | 方案 FIT 已补齐 sha1 |
| rootfs 内容（p5） | SquashFS 4.0（xz），OpenWrt 根文件系统 | p5 将被改为 ext4 Debian RootFS |
| bootargs（DTB chosen） | `earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf` | 与方案一致；已同步补充 `earlycon` |
| GPT PARTLABEL 定位 | `lib/upgrade/platform.sh`：`CI_KERNPART="kernel" CI_ROOTPART="rootfs"`；`lib/upgrade/emmc.sh` 用 `find_mmc_part`（按 PARTLABEL）定位分区设备后 **dd 直接写入** | 确认 OpenWrt 仅按 PARTLABEL 写 `kernel`/`rootfs` 两分区，其余区域零写入（与本方案设计一致） |
| factory 分区 | DTB：`block-partition-factory { partname = "factory"; nvmem-layout … }`（Wi-Fi EEPROM 校准） | 确认 p2 不可动 |
| 网口映射 | `etc/board.d/02_network`：`ucidef_set_interfaces_lan_wan "eth0" eth1` | LAN=eth0 / WAN=eth1，与方案一致 |
| MAC 生成 | `macaddr_generate_from_mmc_cid mmcblk0`（LAN=CID 派生，WAN=LAN+1） | 与网络初始化一致（可参考） |
| eMMC 节点 | DTB `mmc@11230000`，`mmc-card`，`non-removable` | 无 SD 卡槽，仅 eMMC，与方案一致 |

> 实测结论：官方 U-Boot 使用 **GPT PARTLABEL 定位 p4（kernel）→ 读取裸 FIT → bootm**
> （内核 LZMA 解压至 load 地址）。官方 FIT 的 load/entry 为 0x40000000（其内核解压后仅
> 14.5MiB，在 U-Boot TEXT_BASE=0x41e00000 之前的 30MiB 窗口内）；本方案内核更大，FIT
> load/entry 必须用 **0x46000000**（同 LZMA、同 crc32+sha1），现有 U-Boot **零改动**直接启动。
> 官方 sysupgrade 也仅覆盖 `kernel`/`rootfs` 两个 GPT 分区，与本方案"只写 p4/p5"完全一致。

---

## 2. 当前启动链对应关系

```
BootROM（SoC 内部，不可修改）
   ↓  从 eMMC 固定偏移读取 BL2
BL2（位于 eMMC 硬件保留区域 / 与 FIP 同区，不在此 GPT 表内）
   ↓
FIP / U-Boot（p3 `fip`，4 MiB）
   ↓
U-Boot 读取 eMMC GPT（主 GPT 正常可读）
   ↓
U-Boot 从 p4（`kernel` 分区，GPT PARTLABEL=kernel）读取 FIT 镜像到内存
   ↓  bootm ${kernel_addr_r}
Kernel（FIT 内：LZMA 压缩 Image + H5000M DTB）
   ↓  解析 bootargs：root=PARTLABEL=rootfs
挂载 p5（`rootfs`，引导层 ext4）→ /sbin/init：SquashFS 只读根 + OverlayFS 可写层
```

**U-Boot 加载 Kernel 的方式（结论，已由官方固件实测确认）**：Filogic（MT7987）平台的
OpenWrt/ImmortalWrt U-Boot 通过 **GPT 分区号 p4 / PARTLABEL `kernel`** 定位 kernel 分区，
将该分区内**裸 FIT 镜像**加载到内存后执行 `bootm`（FIT 方式启动，`CONFIG_FIT` + LZMA）；
FIT 内 kernel 的 `load/entry = 0x46000000`（官方 FIT 为 0x40000000；因 U-Boot 自身
常驻 0x41e00000，0x40000000 起的解压窗口仅 30MiB，本内核解压后 35~45MiB 越界，
故本方案 FIT 必须用 0x46000000），bootm 按该地址解压跳转。
不是 EFI/GRUB、不依赖传统 PC 启动路径。

> 若个别固件版本的 U-Boot 使用 distro boot（`bootflow scan`），其会扫描文件系统分区
> 寻找 `boot.scr` / `extlinux/extlinux.conf`。本项目同时在这两条路径都提供启动文件（见 §8）。

---

## 3. 绝对不能修改的区域

| 区域 | 位置 | 禁止操作 |
| --- | --- | --- |
| BootROM | SoC 内部 | 不可修改 |
| BL2 | eMMC 硬件保留区 | 禁止擦除 / 覆盖 / 移动 |
| U-Boot / FIP | p3 `fip`（4 MiB） | 禁止擦除 / 覆盖 / 移动 / 缩放 / 重建 / 重新格式化 |
| u-boot-env | p1 `u-boot-env`（1 MiB） | 禁止擦除 / 覆盖 / 移动 / 缩放 / 重建 / 重新格式化；**不修改 U-Boot 环境变量** |
| factory | p2 `factory`（2 MiB） | 禁止擦除 / 覆盖 / 移动 / 缩放 / 重建 / 重新格式化 |
| GPT 分区表 | LBA 0–33 + 备份 GPT | **不创建 / 重建 / 重排分区**（无 `mklabel` / `mkpart` / `sgdisk` 写操作） |
| eMMC 硬件配置 | Boot Partition / EXT_CSD / RPMB / GP / Enhanced Area | 禁止 `mmc gp create` / `mmc enh_area set` / `mmc bootpart enable` / `mmc extcsd write` |

以上区域在本次迁移中**零写入**。脚本 [install-emmc.sh](/workspace/scripts/install-emmc.sh) 强制校验后仅操作 p4 / p5。

---

## 4. 可以修改的区域

| 分区 | 说明 |
| --- | --- |
| p4 `kernel`（30 MiB） | **原位置 / 原大小 / 原 GPT 项 / 原启动逻辑复用**，仅把内容从 OpenWrt FIT 替换为 Debian FIT 镜像 |
| p5 `rootfs`（~7.24 GiB） | **原分区不变（Start/End/PARTLABEL=rootfs 均不动）**，仅内容重新格式化为**引导层 ext4**（`/sbin/init` + busybox + `rootfs.squashfs` 只读基础系统 + `/overlay` 可写持久层 + `/boot` 兜底） |

其余空间（p5 之后的磁盘末尾区域）无独立分区，全部并入 p5，**无需新增 Data 分区**（满足"只有确实有必要时才新增"的优先级原则）。

---

## 5. Debian 13 最终分区表

与当前 OpenWrt 布局**完全一致**（零结构变化）：

| 分区 | PARTLABEL | Start (sector) | End (sector) | 大小 | Filesystem | Debian 13 用途 |
| --- | --- | --- | --- | --- | --- | --- |
| p1 | `u-boot-env` | 8192 | 10239 | 1 MiB | 裸（U-Boot env） | 原样保留 |
| p2 | `factory` | 10240 | 14335 | 2 MiB | 裸（校准数据） | 原样保留（Wi-Fi EEPROM） |
| p3 | `fip` | 14336 | 22527 | 4 MiB | 裸（FIP） | 原样保留（BL2/U-Boot） |
| p4 | `kernel` | 22528 | 83967 | 30 MiB | 裸（FIT 镜像，无文件系统） | **Debian Kernel 所在**（H5000M-debian13-kernel.bin） |
| p5 | `rootfs` | 83968 | 15268830 | ~7.24 GiB | **ext4**（卷标 `rootfs`） | **Debian 引导层所在**（init + busybox + rootfs.squashfs + overlay 持久层） |

- **PARTUUID**：保持不变（现有 GPT 中已存在，全部保留；Debian 不依赖 PARTUUID）。
- **PARTLABEL**：保持 `u-boot-env` / `factory` / `fip` / `kernel` / `rootfs` 不变。
- **不新增 Data 分区**：p5 为 ~7.24 GiB；实机磁盘尾部另有约 7.3 GiB 未分配空间，本方案保持其未分配，不自动扩分区或改写 GPT；
  如需大数据存储可后续在 p5 内自建目录或视情况增加分区（本方案不改）。

---

## 6. 各功能存放位置

| 内容 | 位置 |
| --- | --- |
| **Kernel** | p4 `kernel` 分区：裸写入 FIT 镜像 `H5000M-debian13-kernel.bin`（内核 LZMA 压缩 + H5000M DTB，bootm 自动解压）。备用副本：p5 引导层 `/boot/Image` + `/boot/mt7987a-hiveton-h5000m.dtb` |
| **DTB** | 内嵌于 FIT（fdt 节点）；备用：`/boot/mt7987a-hiveton-h5000m.dtb`（p5 引导层内） |
| **RootFS（只读基础系统）** | p5 引导层内 `/squashfs/rootfs.squashfs`（Debian 13 Trixie ARM64，zstd 压缩，~120 MiB，只读不可变） |
| **RootFS（可写层/持久化）** | p5 引导层内 `/overlay/{upper,work}`（OverlayFS upper），`/etc` `/var` `/opt` 等写入全部落此，重启保留；首启 `h5000m-grow-rootfs` 在线扩容 p5 至 ~7.2 GiB |
| **引导脚本** | p5 引导层 `/sbin/init`（busybox 静态）：挂 SquashFS → 组装 OverlayFS → pivot_root → systemd；失败进入只读救援模式 |
| **Data** | p5 引导层 overlay 内（`/var/lib/linux-router`、`/home`、用户数据等），不单独分区 |
| **U-Boot 启动脚本（备用）** | p5 引导层 `/boot/boot.scr`（由 boot/boot.cmd 编译）+ `/boot/extlinux/extlinux.conf` |

---

## 7. U-Boot 如何加载 Debian Kernel

**主路径（复用现有启动链，零改动）**：

```
U-Boot bootcmd（现有，未修改）
  → 从 eMMC GPT 定位 p4（PARTLABEL=kernel）
  → load mmc 0:4 ${kernel_addr_r}（读取裸 FIT）
  → bootm ${kernel_addr_r}
     ├─ 解压 LZMA 内核 → FIT 内 load/entry 地址 0x46000000（官方 FIT 为 0x40000000，
     │  本方案因 30MiB 解压窗口限制改用 0x46000000，详见上文根因说明）
     ├─ 选择 FIT config `conf@h5000m` → fdt（compatible=hiveton,h5000m）
     └─ 传递 bootargs（root=PARTLABEL=rootfs …）
```

FIT 镜像结构与 OpenWrt 完全同型（`type="kernel"` / `flat_dt`、`compression="lzma"`、
默认 config + `compatible` 便于 U-Boot `FIT_BEST_MATCH`），因此现有 U-Boot 无需任何改动即可启动。

**兜底路径（可选）**：若 U-Boot 为 distro boot（`bootflow scan`），自动发现 p5（ext4）后：
优先执行 `/boot/boot.scr`（备用脚本，从 mmc 0:5 加载 `/boot/Image` + DTB 后 `booti`），
其次读取 `/boot/extlinux/extlinux.conf`。两套文件均已预置。

---

## 8. Debian Kernel 如何找到 RootFS

内核启动参数（与当前 OpenWrt 完全一致，来自 DTS `chosen`，U-Boot 无需改写）：

```
root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8
earlycon=uart8250,mmio32,0x11000000
```

- `root=PARTLABEL=rootfs`：内核按 GPT PARTLABEL 定位 `/dev/mmcblk0p5`。
- `rootwait`：等待 eMMC 就绪。
- 因启动参数完全沿用现有机制，**不修改 U-Boot 环境变量、不依赖任何 EFI/GRUB 组件**。

---

## 9. /etc/fstab（Debian 13）

[rootfs-overlay/etc/fstab](/workspace/rootfs-overlay/etc/fstab) 仅作布局说明注释，**无运行时挂载项**：

```
# 根文件系统 = OverlayFS：
#   lower = /sq        （只读 SquashFS：/squashfs/rootfs.squashfs 挂载）
#   upper = /overlay/upper、work = /overlay/work（位于 p5 引导层 ext4，持久化）
# 由引导层 /sbin/init 在内核按 root=PARTLABEL=rootfs 挂载 p5 后组装，
# 经 pivot_root 切换；本文件仅作布局说明，无运行时挂载项（root 由内核 + 引导层 init 处理）。
```

- root 挂载链：内核 `root=PARTLABEL=rootfs` 挂 p5（引导层 ext4）→ `/sbin/init` 组装
  OverlayFS → `pivot_root` 切换，全程无需 fstab 参与；
- 无需其他挂载项（p5 覆盖全部用户区，overlay upper 即持久数据区）。

---

## 10. 启动参数汇总

| 来源 | 内容 |
| --- | --- |
| DTS `chosen/bootargs` | `earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf` |
| 备用引导 APPEND（extlinux） | 同左（追加 `console=ttyS0,115200n8`） |
| U-Boot 环境 | **不修改**（`u-boot-env` 分区原样保留） |

---

## 11. 迁移过程中实际会覆盖哪些区域

| 区域 | 操作 |
| --- | --- |
| p4 `kernel`（30 MiB） | **覆盖**：写入 `H5000M-debian13-kernel.bin`（原 OpenWrt FIT 被替换） |
| p5 `rootfs`（~7.24 GiB） | **覆盖**：格式化为引导层 ext4 并写入 `/sbin/init` + busybox + `rootfs.squashfs` + overlay 目录（原 OpenWrt SquashFS/overlay 全部被替换；p5 分区本身 Start/End 不变，首启在线扩容至 ~7.2 GiB） |
| p1 / p2 / p3 | **零写入** |
| GPT（主 + 备份） | **零写入**（不重建、不重排） |
| eMMC 硬件配置 | **零写入** |

**唯一不可逆变更**：OpenWrt 系统（kernel + rootfs）被 Debian 覆盖。
BL2 / U-Boot / factory / u-boot-env / GPT 均在，可随时通过原厂方式恢复 OpenWrt。

---

## 12. GPT 备份损坏问题分析与处理

**现象**：主 GPT 正常可读，备份 GPT 报损坏提示（常见于 OpenWrt 刷机工具仅写入主 GPT，
或分区未覆盖到磁盘末尾时备份 GPT 校验失败）。

**结论（已分析）**：

1. 备份 GPT 仅位于磁盘末尾最后 33 扇区（LBA-34 … LBA-1），**与任何分区数据不重叠**。
2. 当前布局分区未精确覆盖到磁盘末尾，备份 GPT 校验失败**不影响启动**
   （U-Boot / 内核只使用主 GPT 与 PARTLABEL）。
3. 本次迁移方案**不写 GPT**，因此**不触发、不放大**此问题，也**无需修复**。

**可选安全修复**（非迁移必需，恢复冗余）：

```
# 重建/搬移备份 GPT 到正确位置（仅重写磁盘末尾 33 扇区，不触碰任何分区数据）
sgdisk -e /dev/mmcblk0

# 修复前后校验分区表是否完全一致（应逐字节一致，仅备份 GPT 变化）
sgdisk -p /dev/mmcblk0
```

执行前建议先做 §13 的完整备份；若修复后 `sgdisk -p` 显示任何分区 Start/End 变化，**立即停止**并从备份恢复。

---

## 13. 完整备份方案

### 13.1 迁移前（在 OpenWrt 中执行，建议）

```sh
# 方式 A：整盘备份（实机约 14.6 GiB，最保险）
dd if=/dev/mmcblk0 of=/tmp/h5000m-backup-full.img bs=4M conv=fsync status=progress

# 方式 B：仅备份关键不可变区域 + 将被覆盖的 p4/p5（小且够用）
mkdir -p /tmp/h5000m-backup
dd if=/dev/mmcblk0p1 of=/tmp/h5000m-backup/p1-u-boot-env.img bs=1M conv=fsync status=progress
dd if=/dev/mmcblk0p2 of=/tmp/h5000m-backup/p2-factory.img    bs=1M conv=fsync status=progress
dd if=/dev/mmcblk0p3 of=/tmp/h5000m-backup/p3-fip.img        bs=4M conv=fsync status=progress
dd if=/dev/mmcblk0p4 of=/tmp/h5000m-backup/p4-kernel.img     bs=1M conv=fsync status=progress
dd if=/dev/mmcblk0p5 of=/tmp/h5000m-backup/p5-rootfs.img     bs=4M conv=fsync status=progress
# 保存 GPT（含 PARTUUID）
sgdisk --backup=/tmp/h5000m-backup/gpt.bin /dev/mmcblk0
# 保存当前启动参数 / 挂载关系（排查用）
cat /proc/cmdline > /tmp/h5000m-backup/cmdline.txt
cat /proc/mounts   > /tmp/h5000m-backup/mounts.txt
```

备份文件务必复制到 **PC / U 盘** 再操作（设备刷写前不要只放 eMMC 上）。

### 13.2 脚本内置备份（install-emmc.sh）

```
sudo bash scripts/install-emmc.sh \
  --kernel-fit out/H5000M-debian13-kernel.bin \
  --rootfs-img out/H5000M-debian13-rootfs.bin \
  --backup-full /tmp/h5000m-full.img        # 整盘
  # 或 --backup-p45 /tmp/h5000m-p45          # 仅 p4/p5
```

### 13.3 恢复

```sh
# 恢复整盘
dd if=/tmp/h5000m-backup-full.img of=/dev/mmcblk0 bs=4M conv=fsync status=progress
# 恢复单个分区（例如仅恢复 p4/p5）
dd if=/tmp/h5000m-backup/p4-kernel.img of=/dev/mmcblk0p4 bs=1M conv=fsync status=progress
dd if=/tmp/h5000m-backup/p5-rootfs.img  of=/dev/mmcblk0p5 bs=4M conv=fsync status=progress
# 恢复 GPT（如误操作）
sgdisk --load-backup=/tmp/h5000m-backup/gpt.bin /dev/mmcblk0
```

> 只要 p1/p2/p3/GPT 完好，即使 Debian 引导失败，也可随时从 U 盘 initramfs 恢复。

---

## 14. 刷写完成后的验证方案

```sh
# 1. 分区表未被改动（Start/End/PARTLABEL 与迁移前逐项一致）
sgdisk -p /dev/mmcblk0

# 2. p4 已写入 FIT（魔数 0xd00dfeed）
dd if=/dev/mmcblk0p4 bs=1 count=4 status=none | od -An -tx1   # 应输出 d0 0d fe ed

# 3. p5 为引导层 ext4 且可挂载（内含 init / busybox / squashfs / overlay）
blkid /dev/mmcblk0p5          # 应显示 TYPE="ext4" LABEL="rootfs" PARTLABEL="rootfs"
e2fsck -fn /dev/mmcblk0p5
debugfs -R 'stat /sbin/init' /dev/mmcblk0p5 2>/dev/null | grep Size
debugfs -R 'stat /squashfs/rootfs.squashfs' /dev/mmcblk0p5 2>/dev/null | grep Size

# 4. 启动验证（串口 115200n8）
#    - U-Boot 输出 "Loading FIT image" / bootm 解压内核
#    - 内核日志出现 mmc0 挂载 rootfs、/sbin/init 挂 SquashFS 组装 OverlayFS、systemd 启动
#    - 进入 Debian 后：
cat /proc/cmdline            # root=PARTLABEL=rootfs rootwait ...
findmnt /                    # overlay（upperdir=/overlay/upper ...）
findmnt /sq                  # squashfs ro
df -h /                      # overlay 可写容量（首启扩容后 ~7.2 GiB）
systemctl status h5000m-grow-rootfs h5000m-fancontrol h5000m-router-init dnsmasq router-panel

# 5. 网络/服务自检
curl -sI http://192.168.88.1    # WebUI 可达
```

---

## 15. 构建与刷写流程（产物对应关系）

```
build/build-kernel.sh        → out/kernel/Image + mt7987a-hiveton-h5000m.dtb + modules.tar.zst
build/build-rootfs.sh        → out/rootfs/rootfs/（RootFS 树；默认另打 tar.zst，--skip-tar 跳过）
build/make-squashfs.sh       → out/rootfs/rootfs.squashfs（只读基础系统，zstd，~120 MiB）
build/make-boot.sh           → out/boot/boot.scr（备用引导）
build/make-sd-image.sh       → out/H5000M-debian13-kernel.bin（→ p4）
                               out/H5000M-debian13-rootfs.bin（→ p5 引导层 ext4）
scripts/install-emmc.sh      → 校验现有分区 → 仅写 p4 / p5 → 校验
                               （--rootfs-squashfs 为运行中在线升级：原子替换 SquashFS）
```

---

## 16. 最终原则

- **不破坏** H5000M 原有 OpenWrt 分区设计：p1–p3、GPT、eMMC 硬件配置、U-Boot 全部原样。
- **最大复用**：kernel 分区（p4）与 rootfs 分区（p5）的起始位置、大小、GPT 项、PARTLABEL
  及启动逻辑全部保留，仅替换内容。
- **启动方式延续**：U-Boot 直接从 p4 加载 FIT（`bootm`），内核以 `root=PARTLABEL=rootfs`
  挂载 p5 —— 与当前 OpenWrt 完全同构，Debian 13 无需任何传统 PC 式 EFI/GRUB 组件；
  p5 之上再由引导层 `/sbin/init` 组装 SquashFS（只读根）+ OverlayFS（持久层），
  该层组装对内核与 U-Boot 完全透明。
