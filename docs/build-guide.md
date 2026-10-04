# 构建指南

在 Linux 构建机上生成：

1. Linux 6.18.x 内核（`Image` + H5000M `dtb` + `modules`）
2. Debian 13 (Trixie) ARM64 RootFS
3. **刷写包**：`h5000m-kernel.fit`（写入 p4 kernel 分区）+ `h5000m-rootfs.ext4.img`（写入 p5 rootfs 分区）

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
  debian13-arm64-rootfs.tar.zst
  initial-credentials.txt     # 首次登录凭据（chmod 600）
boot/
  boot.scr                    # 备用引导脚本（distro boot 兜底）
h5000m-kernel.fit             # → 刷入 p4（kernel 分区，U-Boot bootm 直接加载）
h5000m-rootfs.ext4.img        # → 刷入 p5（rootfs 分区，ext4）
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
10. 输出 `debian13-arm64-rootfs.tar.zst` 与 `initial-credentials.txt`。

### 3.3 刷写包（FIT + RootFS ext4 镜像）

```bash
sudo bash build/make-sd-image.sh \
  --out /path/to/out \
  --kernel-dir /path/to/out/kernel \
  --rootfs /path/to/out/rootfs/debian13-arm64-rootfs.tar.zst \
  --boot-dir /path/to/out/boot \
  --rootfs-size 4096
```

输出（对应现有 eMMC 分区，**不创建任何分区表**）：

```
out/h5000m-kernel.fit        → dd 到 p4（kernel，30 MiB）
out/h5000m-rootfs.ext4.img   → dd 到 p5（rootfs，~7.24 GiB）
```

- `h5000m-kernel.fit`：内核 LZMA 压缩 + H5000M DTB 的 FIT 镜像，**与 OpenWrt 同型**
  （U-Boot 现有 `bootm` 流程原样加载），p4 无需文件系统；
- `h5000m-rootfs.ext4.img`：ext4 根文件系统镜像，内含 `/boot` 备用引导
  （`boot.scr` / `extlinux.conf` / `Image` / DTB，供 distro boot 兜底）。

### 3.4 U-Boot 启动脚本（备用引导，可选）

```bash
# 由 boot/boot.cmd 编译生成 boot.scr（依赖 u-boot-tools 的 mkimage）
bash build/make-boot.sh --out /path/to/out/boot
```

产物：`out/boot/boot.scr` + `out/boot/boot.cmd`。

> **主引导不依赖 boot.scr**：现有 U-Boot 直接从 p4 加载 FIT 并 `bootm`。
> `boot.scr` 仅作为 distro boot（`bootflow scan`）U-Boot 的兜底路径，
> 由 `make-sd-image.sh` 自动放入 rootfs 的 `/boot/boot.scr`。

### 3.5 eMMC 刷入（在目标设备上执行，仅写 p4 / p5）

```bash
# 方法一：使用 ext4 镜像（推荐）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/h5000m-kernel.fit \
  --rootfs-img /path/to/out/h5000m-rootfs.ext4.img \
  --dev /dev/mmcblk0 [--backup-full /tmp/emmc-full.img] [--yes]

# 方法二：使用 rootfs tar.zst（脚本内部挂载解压）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/h5000m-kernel.fit \
  --rootfs /path/to/out/rootfs/debian13-arm64-rootfs.tar.zst \
  --dev /dev/mmcblk0 [--yes]
```

`install-emmc.sh` 会：

1. **只读**读取现有 GPT，校验 p4（kernel）/ p5（rootfs）存在且 p5 的 PARTLABEL 为 `rootfs`；
2. **绝不**执行 `mklabel` / `mkpart` / GPT 写操作 / `mmc` 写操作，**绝不**触碰 p1-p3；
3. 可选备份（`--backup-full` 整盘 / `--backup-p45` 仅 p4+p5）；
4. 写入 p4（FIT）+ p5（ext4），完成后回读校验 FIT 魔数与 e2fsck。

> 必须在 **OpenWrt initramfs / Debian live / 已启动的 Debian** 中执行（p5 未挂载状态）。

## 3.6 GitHub Actions 云编译

推送 `main`/`master`、发起 PR、手动 `workflow_dispatch` 或每周定时触发
`.github/workflows/build.yml`：

1. **build-kernel**：ubuntu-24.04 上编译 6.18 内核（含源码缓存）+ 生成 boot.scr，上传 artifact；
2. **build-image**：下载内核产物，debootstrap 构建 Debian 13 RootFS，生成刷写包
   （`h5000m-kernel.fit` + `h5000m-rootfs.ext4.img`），上传 artifact。

产物从 Actions 页面「Artifacts」下载：`h5000m-debian13-release`
（rootfs、kernel.fit、rootfs.ext4.img、内核、boot.scr、初始凭据）。

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
- [ ] `h5000m-kernel.fit` 首 4 字节为 FIT 魔数 `d0 0d fe ed`，且体积 < 30 MiB
- [ ] `h5000m-rootfs.ext4.img` 可 `e2fsck -fn` 通过
- [ ] rootfs 内 `/usr/lib/firmware/mediatek/mt7996/` 与 `mt7987/` 固件齐全
- [ ] rootfs 内 Linux-Router 服务已 enable
- [ ] rootfs 内 `/etc/fstab` 根挂载为 `PARTLABEL=rootfs`
