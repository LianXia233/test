# 构建指南

在 Linux 构建机上生成：

1. Linux 6.18.x 内核（`Image` + H5000M `dtb` + `modules`）
2. Debian 13 (Trixie) ARM64 RootFS 树
3. **只读基础系统** `rootfs.squashfs`（RootFS 树瘦身 + zstd 压缩）
4. **刷写包**：`H5000M-debian13-kernel.bin`（写入 p4 kernel 分区，FIT）+
   `H5000M-debian13-rootfs.bin`（写入 p5 rootfs 分区，**引导层 ext4**：
   `/sbin/init` + busybox + `rootfs.squashfs` + `/overlay` 可写层 + `/boot` 兜底）

> **分区原则**：完全复用 H5000M 现有 OpenWrt 的 eMMC 分区布局与启动链
> （BL2 / U-Boot / FIP / u-boot-env / factory / GPT / eMMC 硬件配置一律不动）。
> 完整方案见 [docs/debian13-partition-plan.md](debian13-partition-plan.md)。

## 1. 构建机要求

- Linux x86_64 或 aarch64（**建议 x86_64**）
- 至少 8GB 内存、20GB 可用磁盘
- 依赖（Debian/Ubuntu）：

```bash
sudo apt-get update
sudo apt-get install -y \
  git curl wget xz-utils zstd \
  build-essential bison flex libssl-dev bc \
  crossbuild-essential-arm64 \
  debootstrap qemu-user-static \
  u-boot-tools \
  kmod cpio rsync \
  squashfs-tools \
  python3
```

## 2. 一键构建

```bash
git clone <本项目> && cd <本项目>
sudo bash scripts/build.sh \
  --kernel-version 6.18.54 \
  --out /path/to/out \
  --hostname h5000m-debian
```

> LAN 网段固定为 192.168.88.1/24（见 `rootfs-overlay/etc/default/h5000m-router`），
> 无需在命令行指定。WebUI/root 初始密码不指定时由脚本随机生成，
> 构建完成后查看 `out/rootfs/initial-credentials.txt`。

产物（`/path/to/out/`）：

```
kernel/
  Image
  mt7987a-hiveton-h5000m.dtb
  modules.tar.zst
rootfs/
  rootfs/                     # RootFS 树（build-rootfs.sh 产出，SquashFS 直接消费）
  rootfs.squashfs             # 只读基础系统（zstd，~120 MiB；瘦身由 make-squashfs.sh 完成）
  initial-credentials.txt     # 首次登录凭据（chmod 600）
boot/
  boot.scr                    # 备用引导脚本（distro boot 兜底）
H5000M-debian13-kernel.bin             # → 刷入 p4（kernel 分区，U-Boot bootm 直接加载）
H5000M-debian13-rootfs.bin        # → 刷入 p5（rootfs 分区，引导层 ext4）
H5000M-debian13-sysupgrade.bin         # sysupgrade 自校验包（CONTROL+kernel+root，≈164 MiB）
```

## 3. 分步构建

### 3.1 内核

```bash
bash build/build-kernel.sh \
  --kernel-version 6.18.54 \
  --config build/kernel-conf/h5000m-6.18.config \
  --out /path/to/out/kernel
```

脚本流程：

1. 从 kernel.org 下载 `linux-6.18.54.tar.xz`；
2. 按序应用 `kernel/patches/` 中的 ImmortalWrt 补丁（`git apply --check` 逐个验证）；
3. 复制 `dts/` 与配套 dtsi 到 `arch/arm64/boot/dts/mediatek/`，并修改该目录 `Makefile` 注册 H5000M DTB；
4. 复制 defconfig，`make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig`；
5. 编译 `Image`、`dtbs`、`modules_install`；
6. 输出 `Image` / `mt7987a-hiveton-h5000m.dtb` / `modules.tar.zst`。

> 补丁来源：ImmortalWrt master `target/linux/mediatek/patches-6.18/`。
> 若 `--kernel-version` 与补丁上下文不匹配导致某个补丁失败，脚本会打印失败补丁名并退出，
> 请调整版本号（`6.18.x` 系列）后重试。

### 3.2 RootFS

```bash
sudo bash build/build-rootfs.sh \
  --out /path/to/out \
  --hostname h5000m \
  --kernel-dir /path/to/out/kernel
```

脚本流程：

1. 先执行 `scripts/fetch-firmware.py` 拉取 MT7992 / MT7987 PHY 固件到 `build/rootfs/firmware/`；
2. `debootstrap --arch=arm64 --foreign trixie <rootfs>`；
3. 拷贝 `qemu-aarch64-static`，`chroot` 内完成第二阶段；
4. 配置 Debian 13 软件源（`deb.debian.org` stable），`apt-get update`；
5. 安装 `build/rootfs/packages.list` 中全部软件包；
6. 应用 `rootfs-overlay/` 覆盖层（网络配置、Linux-Router 集成、systemd 服务、`/etc/fstab` 使用 `PARTLABEL=rootfs`）；
7. 集成 Linux-Router 到 `/opt/linux-router`，预初始化运行账号/数据目录/初始密码；
8. 安装内核产物到 `/boot`、模块到 `/lib/modules`；
9. 配置 systemd 服务 enable、SSH、locale、首次登录凭据；
10. 输出 RootFS 树 `out/rootfs/rootfs/` 与 `initial-credentials.txt`；
    默认同时打包 `debian13-arm64-rootfs.tar.zst`（传 `--skip-tar` 则跳过，
    SquashFS 链路直接消费树，CI 即如此）。

### 3.3 只读基础系统 SquashFS

```bash
sudo bash build/make-squashfs.sh \
  --out /path/to/out \
  --rootfs-dir /path/to/out/rootfs/rootfs \
  [--comp zstd|xz] [--no-slim] [--in-place]
```

脚本流程：

1. 默认对 RootFS 树做**副本瘦身**（`cp -a` 到临时目录后精简，原树不动；`--in-place` 直改）：
   清理 apt lists、doc/man/info/locale（保留 en\*/zh\*）、var/log 等；
2. `mksquashfs`：默认 `-comp zstd -Xcompression-level 19 -b 262144`（xz 体积再小约 12%
   但解压慢 5-10 倍，A53 首启解压体验差，故默认 zstd）；
3. 自检：`unsquashfs -s` 超块校验（Compression / Block size）+ 抽样文件与源树 `cmp` 一致。

输出：`out/rootfs/rootfs.squashfs`（实测 514 MiB 瘦身后 → zstd ~120 MiB）。

### 3.4 刷写包（FIT + p5 引导层 ext4 镜像）

```bash
sudo bash build/make-sd-image.sh \
  --out /path/to/out \
  --kernel-dir /path/to/out/kernel \
  --squashfs /path/to/out/rootfs/rootfs.squashfs \
  --boot-dir /path/to/out/boot \
  [--extra-mb 24] [--busybox /path/to/busybox] [--mirror http://deb.debian.org/debian]
```

输出（对应现有 eMMC 分区，**不创建任何分区表**）：

```
out/H5000M-debian13-kernel.bin        → dd 到 p4（kernel，30 MiB）
out/H5000M-debian13-rootfs.bin   → dd 到 p5（rootfs，引导层 ext4 镜像，~152 MiB）
```

- `H5000M-debian13-kernel.bin`：内核 LZMA 压缩 + H5000M DTB 的 FIT 镜像，**与 OpenWrt 同型**
  （U-Boot 现有 `bootm` 流程原样加载），p4 无需文件系统；
- `H5000M-debian13-rootfs.bin`：**p5 引导层 ext4 镜像**，内含：
  - `/sbin/init`：busybox 引导脚本（挂 SquashFS → 组装 OverlayFS → pivot_root → systemd；
    OverlayFS 组装失败自动进入只读救援模式）；
  - `/usr/bin/busybox`：静态 busybox（脚本自动从 Debian mirror 下载 busybox-static arm64
    并提取，支持 `--busybox` 指定本地文件，构建机缓存于 `out/rootfs/.cache/busybox`）；
  - `/squashfs/rootfs.squashfs`：只读基础系统；
  - `/overlay/{upper,work,merged}`：OverlayFS 可写层（p5 剩余空间 = 持久化数据，首启由
    `h5000m-grow-rootfs` 在线扩容至 ~7.2 GiB）；
  - `/boot`：备用引导（DTB / extlinux.conf / boot.scr，供 distro boot 兜底）。

  镜像以 `mkfs.ext4 -d` 免挂载构建，经 e2fsck + debugfs 三重自检（init / busybox /
  squashfs 逐项存在且大小与源一致）。

> 引导层尺寸公式：`(SquashFS + busybox 字节数) 上取整 MiB + 24 MiB 余量`，再 8 MiB 对齐。
> p5 实际容量（~7.2 GiB）与镜像尺寸无关——刷入后首启自动 `resize2fs` 扩满。

### 3.5 U-Boot 启动脚本（备用引导，可选）

```bash
# 由 boot/boot.cmd 编译生成 boot.scr（依赖 u-boot-tools 的 mkimage）
bash build/make-boot.sh --out /path/to/out/boot
```

产物：`out/boot/boot.scr` + `out/boot/boot.cmd`。

> **主引导不依赖 boot.scr**：现有 U-Boot 直接从 p4 加载 FIT 并 `bootm`。
> `boot.scr` 仅作为 distro boot（`bootflow scan`）U-Boot 的兜底路径，
> 由 `make-sd-image.sh` 自动放入 rootfs 的 `/boot/boot.scr`。

### 3.6 eMMC 刷入（在目标设备上执行，仅写 p4 / p5）

```bash
# 方法一：引导层 ext4 镜像（推荐，SquashFS+OverlayFS 完整架构）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/H5000M-debian13-kernel.bin \
  --rootfs-img /path/to/out/H5000M-debian13-rootfs.bin \
  --dev /dev/mmcblk0 [--backup-full /tmp/emmc-full.img] [--yes]

# 方法二：rootfs tar.zst（兼容模式：p5 直接展开为纯 Debian 树，无引导层/只读根）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/H5000M-debian13-kernel.bin \
  --rootfs /path/to/out/rootfs/debian13-arm64-rootfs.tar.zst \
  --dev /dev/mmcblk0 [--yes]

# 方法三：在线升级（系统已以 SquashFS+OverlayFS 架构运行时，无需重启/失联）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/H5000M-debian13-kernel.bin \
  --rootfs-squashfs /path/to/out/rootfs/rootfs.squashfs \
  --dev /dev/mmcblk0 [--yes]
```

`install-emmc.sh` 会：

1. **只读**读取现有 GPT，校验 p4（kernel）/ p5（rootfs）存在且 p5 的 PARTLABEL 为 `rootfs`；
2. **绝不**执行 `mklabel` / `mkpart` / GPT 写操作 / `mmc` 写操作，**绝不**触碰 p1-p3；
3. 可选备份（`--backup-full` 整盘 / `--backup-p45` 仅 p4+p5）；
4. 写入 p4（FIT）+ p5，完成后回读校验 FIT 魔数与 e2fsck：
   - 方法一：格式化 p5 为引导层 ext4 并写入镜像内容，e2fsck 校验；
   - 方法二：格式化 p5 后解压 tar（p5 整层重写 = 恢复出厂，overlay 旧配置不保留）；
   - 方法三：**在线升级模式**——p5 挂载检查跳过（系统运行中，overlay 引用旧 inode 属正常），
     经 `/tmpold/squashfs/` 路径将新 `rootfs.squashfs` 复制到 p5 → hsqs 魔数校验 →
     旧版 `mv` 为 `.bak` → 新版原子 `mv` 替换 → 回读魔数。运行中系统继续使用旧 SquashFS
     inode（安全），重启后生效；配置/数据全保留；回退 = `mv rootfs.squashfs.bak rootfs.squashfs`。

> 方法一/二必须在 **OpenWrt initramfs / Debian live / 已启动的 Debian** 中执行（p5 未挂载状态）；
> 方法三在运行中的 Debian 上直接执行（前提：当前系统本身就是 SquashFS+OverlayFS 架构，脚本会探测）。

## 3.7 GitHub Actions 云编译

推送 `main`/`master`、发起 PR、手动 `workflow_dispatch` 或每周定时触发
`.github/workflows/build.yml`：

1. **build-kernel**：ubuntu-24.04 上编译 6.18 内核（含源码缓存）+ 生成 boot.scr，上传 artifact；
2. **build-image**：下载内核产物，debootstrap 构建 Debian 13 RootFS 树（`--skip-tar`），
   `make-squashfs.sh` 生成只读基础系统（zstd），`make-sd-image.sh` 生成引导层镜像与 FIT，
   组装 `H5000M-debian13-sysupgrade.bin`（≈164 MiB），chown 修正产物属主后上传 artifact。

产物从 Actions 页面「Artifacts」下载：`h5000m-debian13-release`
（kernel.bin、rootfs.bin、rootfs.squashfs、sysupgrade.bin、boot.scr、初始凭据）；
编译完成自动发布 Release（产物名带日期与 Run 序号 + sha256sums.txt）。

## 4. 内核版本说明

- 默认 `6.18.54`（ImmortalWrt snapshot 当前使用的 6.18.x 系列）。
- 主线上游内核 **不支持 MT7987A**（pinctrl/clk/eth 等驱动需 ImmortalWrt SDK 补丁），因此必须使用补丁内核；
- MT7992 Wi-Fi：mainline mt76 已支持，无需外部驱动包。

## 5. 固件获取

```bash
python3 scripts/fetch-firmware.py --out build/rootfs/firmware
```

- MT7992：linux-firmware `mediatek/mt7996/mt7992_*_23.bin`（含 dsp/eeprom/rom_patch/wa/wm）
- MT7987 2p5g PHY：linux-firmware `mediatek/mt7987/i2p5ge-phy-*.bin`

该脚本使用 Python 标准库（urllib），跨平台（Windows/macOS/Linux 均可运行）。

## 6. 验证清单（构建后）

- [ ] `Image` 为 arm64 且含 MT7987A 驱动（`strings Image | grep -i mt7987`）
- [ ] `mt7987a-hiveton-h5000m.dtb` 生成成功
- [ ] `H5000M-debian13-kernel.bin` 首 4 字节为 FIT 魔数 `d0 0d fe ed`，且体积 < 30 MiB
- [ ] `rootfs.squashfs` 首 4 字节为 `hsqs`，`unsquashfs -s` 显示 Compression zstd / Block 262144
- [ ] `H5000M-debian13-rootfs.bin` 可 `e2fsck -fn` 通过；debugfs 确认含
      `/sbin/init`、`/usr/bin/busybox`、`/squashfs/rootfs.squashfs`、`/overlay/{upper,work,merged}`
- [ ] rootfs 内 `/usr/lib/firmware/mediatek/mt7996/` 与 `mt7987/` 固件齐全
- [ ] rootfs 内 Linux-Router 服务已 enable；`/usr/local/sbin/h5000m-grow-rootfs` 存在
- [ ] `H5000M-debian13-sysupgrade.bin` 体积 ≤ 600 MiB（当前 ≈164 MiB）
