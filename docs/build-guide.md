# 构建指南

在 Linux 构建机上生成：

1. Linux 6.18.x 内核（`Image` + H5000M `dtb` + `modules`）
2. Debian 13 (Trixie) ARM64 RootFS
3. SD / USB 启动镜像（可选；H5000M 无 SD 卡槽，写入 USB 盘即可）

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
  kmod cpio rsync parted dosfstools \
  python3
```

## 2. 一键构建

```bash
git clone <本项目> && cd <本项目>
sudo bash scripts/build.sh \
  --kernel-version 6.18.54 \
  --out /path/to/out \
  --hostname h5000m-debian \
  --img h5000m-debian13-usb.img
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
image/
  h5000m-debian13-sd.img.gz   # 写入 USB/SD 盘即可启动
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
  --hostname h5000m
```

脚本流程：

1. 先执行 `scripts/fetch-firmware.py` 拉取 MT7992 / MT7987 PHY 固件到 `build/rootfs/firmware/`；
2. `debootstrap --arch=arm64 --foreign trixie <rootfs>`；
3. 拷贝 `qemu-aarch64-static`，`chroot` 内完成第二阶段；
4. 配置 Debian 13 软件源（`deb.debian.org` stable），`apt-get update`；
5. 安装 `build/rootfs/packages.list` 中全部软件包；
6. 应用 `rootfs-overlay/` 覆盖层（网络配置、Linux-Router 集成、systemd 服务）；
7. 集成 Linux-Router 到 `/opt/linux-router`，预初始化运行账号/数据目录/初始密码；
8. 安装内核产物到 `/boot`、模块到 `/lib/modules`；
9. 配置 systemd 服务 enable、SSH、locale、首次登录凭据；
10. 输出 `debian13-arm64-rootfs.tar.zst` 与 `initial-credentials.txt`。

### 3.3 SD / USB 镜像

```bash
# 生成镜像文件（推荐，可先校验再写入）
sudo bash build/make-sd-image.sh --out /path/to/out --img h5000m-debian13-usb.img
# 写入 USB 盘（危险操作，会覆盖目标盘全部数据）
sudo dd if=/path/to/out/h5000m-debian13-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
```

> H5000M 无 SD 卡槽（DTS 仅定义 eMMC），USB 盘优先；若原厂 U-Boot 不支持 USB 启动，请改用 TFTP（见 `docs/first-boot.md`）。

分区布局（GPT）：

```
p1  vfat  64MB   /boot  （Image、dtb、boot.scr、extlinux.conf）
p2  ext4  剩余    /      （Debian 13 rootfs）
```

boot 分区中的 **`boot.scr`**（U-Boot 脚本）是优先引导入口：ImmortalWrt / OpenWrt
Filogic 系列 U-Boot 会按 `boot.scr -> extlinux (distro boot)` 顺序尝试，因此
**无需修改 U-Boot 本体**即可从 eMMC / USB 引导 Debian。

### 3.4 U-Boot 启动脚本（boot.scr）

```bash
# 由 boot/boot.cmd 编译生成 boot.scr（依赖 u-boot-tools 的 mkimage）
bash build/make-boot.sh --out /path/to/out/boot
```

产物：

```
out/boot/boot.scr     # U-Boot 脚本二进制（放入 boot 分区）
out/boot/boot.cmd     # 脚本源文件副本
```

`boot.cmd` 默认尝试顺序：**eMMC (mmc 0:1) → USB (usb 0:1 / usb 1:1)**，
每个设备从 GPT 分区 1（vfat）加载 `Image` + `mt7987a-hiveton-h5000m.dtb` 后 `booti` 启动。
`make-sd-image.sh` 在制作镜像时若发现 `out/boot/boot.scr` 会自动拷入 boot 分区。

### 3.5 eMMC 刷入（在目标设备上执行）

```bash
sudo bash scripts/install-emmc.sh \
  --rootfs out/rootfs/debian13-arm64-rootfs.tar.zst \
  --boot-dir out/boot --kernel-dir out/kernel \
  --dev /dev/mmcblk0
```

- GPT 分区：p1 boot（vfat，64MiB）+ p2 rootfs（ext4，剩余）
- 可选 `--backup <文件>` 先整盘备份 eMMC
- 若设备上有 `fw_setenv`（u-boot-tools），脚本会顺带设置 U-Boot 环境变量
  （`bootcmd` 优先加载 boot.scr）；没有则提示在 U-Boot 控制台手动引导。
- **先备份 eMMC 再刷入**（原 ImmortalWrt 将被覆盖）。

## 3.6 GitHub Actions 云编译

推送 `main`/`master`、发起 PR、手动 `workflow_dispatch` 或每周定时触发
`.github/workflows/build.yml`：

1. **build-kernel**：ubuntu-24.04 上编译 6.18 内核（含源码缓存）+ 生成 boot.scr，上传 artifact；
2. **build-image**：下载内核产物，debootstrap 构建 Debian 13 RootFS，生成 SD/USB 镜像，上传 artifact。

产物从 Actions 页面「Artifacts」下载：`h5000m-debian13-release`（rootfs、img.gz、内核、boot.scr、初始凭据）。

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
- [ ] rootfs 内 `/usr/lib/firmware/mediatek/mt7996/` 与 `mt7987/` 固件齐全
- [ ] rootfs 内 Linux-Router 服务已 enable
- [ ] SD 镜像可被 `fdisk -l` 识别且分区正确
