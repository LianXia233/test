# 构建指南

> ## ⚠️ 警告：项目仍在测试中，**两板实机均未通过**
>
> 本文档描述的多板构建流程**尚未实机验证通过**。当前状态：
>
> | 板卡 | 云编译（内核） | 云编译（RootFS+刷写包） | **实机验证** |
> | --- | --- | --- | --- |
> | H5000M (MT7987A) | ✅ 成功 | ✅ 成功 | ⚠️ **未验证** |
> | AP3000M (MT7981B) | ✅ 成功（`c3f861d`） | ❌ **失败**（根因已修复，待重跑） | ⚠️ **未验证** |
>
> - **AP3000M**：曾**三次失败，三个阶段各不相同** —— ① ② 内核编译阶段（缺
>   `drivers/hwmon/Kconfig` 注册 → 修复后 `depends` 引用了非 Kconfig 符号 `HRTIMER`），
>   两者**均已修复**（run `37843516159`（`c3f861d`）的内核 job 已通过）；③ **RootFS
>   构建阶段**失败 —— MT7981 固件「路径 + 清单」双错（路径应为平铺
>   `mediatek/mt7981_*.bin` 而非子目录，上游 404；且漏了主固件 `mt7981_wm.bin`），
>   **根因已定位并已修复**（实跑拉取 3/3 成功），待重跑 CI 复验。
>   **当前无任何可用产物**。
> - **H5000M**：云编译通过仅说明能构建出镜像，刷写后能否启动、网络能否连通**均未验收**。
>
> **⚠️ 云编译成功 ≠ 实机可用。本项目至今没有任何一块板卡完成实机验收。**
>
> 状态单一真源见 [ci-status.md](ci-status.md)（run id / job / 步骤级证据）。
>
> **请勿用本文档产出的镜像刷机**（两板均不例外）。根因与修复记录见
> [../CHANGELOG.md](../CHANGELOG.md) 的「AP3000M 首次/二次云编译失败」条目。
>
> 下文命令已按多板化（`--board` 参数）更新；若发现仍有旧命名单体残留，
> 以 `scripts/build.sh --help` 与 `boards/*.board` 为准。

在 Linux 构建机上生成（每块板卡各产出一套）：

1. Linux 6.18.x 内核（`Image` + 板级 `dtb` + `modules`）
2. Debian 13 (Trixie) ARM64 RootFS 树
3. **只读基础系统** `rootfs.squashfs`（RootFS 树瘦身 + zstd 压缩）
4. **刷写包**：`<BOARD_UPPER>-debian13-kernel.bin`（写入 p4 kernel 分区，FIT）+
   `<BOARD_UPPER>-debian13-rootfs.bin`（写入 p5 rootfs 分区，**引导层 ext4**：
   `/sbin/init` + busybox + `rootfs.squashfs` + `/overlay` 可写层 + `/boot` 兜底）

**已支持板卡**（见 `boards/*.board`）：

| board ID | 机型 | SoC | DTB | 内核配置 |
| --- | --- | --- | --- | --- |
| `h5000m` | Hiveton H5000M | MT7987A (4 核) | `mt7987a-hiveton-h5000m.dtb` | `h5000m-6.18.config` |
| `ap3000m` | Airpi AP3000M | MT7981B (2 核) | `mt7981b-airpi-ap3000m.dtb` | `ap3000m-6.18.config` |

> **分区原则**：完全复用各板现有 OpenWrt 的 eMMC 分区布局与启动链
> （BL2 / U-Boot / FIP / u-boot-env / factory / GPT / eMMC 硬件配置一律不动）。
> 完整方案见 [debian13-partition-plan.md](debian13-partition-plan.md)。

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
  --board h5000m \                 # 或 ap3000m
  --kernel-version 6.18.54 \
  --out /path/to/out
```

> `--board` 为**必填**。省略时脚本报错并列出 `boards/*.board` 中的可选板卡。
> hostname 默认取板级的 `BOARD_HOSTNAME`（`h5000m-debian` / `ap3000m-debian`），
> 可用 `--hostname` 覆盖。
>
> LAN 网段固定为 192.168.88.1/24（见 `boards/overlay.d/<board>/etc/default/router.conf`
> 与通用层 `rootfs-overlay/etc/default/router.conf`），无需在命令行指定。
>
> **初始口令**：不指定 `--admin-password` / `--root-password` 时，两者都为出厂默认值
> `password`（不是随机生成）。这是公开已知值，**首次登录后必须立即修改**：
>
> ```bash
> # WebUI：系统设置 → 修改密码
> # SSH / 串口：
> passwd root
> ```
>
> 凭据同时落盘在设备上的 `/etc/<board>-initial-credentials`（chmod 600）。
> 该文件的**副本不再进入构建产物与 GitHub Release**，避免公开分发默认口令。
> 生产环境请用 `--root-password` / `--admin-password` 指定自己的初始值。

产物（`/path/to/out/`）：

```
kernel/
  Image
  <BOARD_DTB>.dtb              # h5000m: mt7987a-hiveton-h5000m.dtb
                               # ap3000m: mt7981b-airpi-ap3000m.dtb
  modules.tar.zst
  kernel-<board>-soc-options.txt   # SoC 选项快照（按板隔离，避免 artifact 互相覆盖）
rootfs/
  rootfs/                     # RootFS 树（build-rootfs.sh 产出，SquashFS 直接消费）
  rootfs.squashfs             # 只读基础系统（zstd，~120 MiB；瘦身由 make-squashfs.sh 完成）
  initial-credentials.txt     # 首次登录凭据（chmod 600）
boot/
  boot.scr                    # 备用引导脚本（distro boot 兜底）
<BOARD_UPPER>-debian13-kernel.bin      # → 刷入 p4（kernel 分区，U-Boot bootm 直接加载）
<BOARD_UPPER>-debian13-rootfs.bin      # → 刷入 p5（rootfs 分区，引导层 ext4）
<BOARD_UPPER>-debian13-sysupgrade.bin  # sysupgrade 自校验包（CONTROL+kernel+root，≈164 MiB）
```

## 3. 分步构建

### 3.1 内核

```bash
bash build/build-kernel.sh \
  --board h5000m \
  --kernel-version 6.18.54 \
  --config build/kernel-conf/h5000m-6.18.config \
  --out /path/to/out/kernel
```

脚本流程：

1. 从 kernel.org 下载 `linux-6.18.54.tar.xz`；
2. 按序应用 `kernel/patches/` 中的 ImmortalWrt 补丁（`git apply --check` 逐个验证）；
3. 复制 `dts/` 与配套 dtsi 到 `arch/arm64/boot/dts/mediatek/`，并注册板级 DTB；
4. 复制 defconfig，`make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig`；
5. 编译 `Image`、`dtbs`、`modules_install`；
6. 叠加板级内核源码层 `kernel/files-boards/<board>/`（ap3000m 含 `airpi-gpio-fan` 风扇驱动，
   并在 `drivers/hwmon/{Makefile,Kconfig}` 双注册）；
7. 输出 `Image` / `<BOARD_DTB>.dtb` / `modules.tar.zst`。

> 补丁来源：ImmortalWrt master `target/linux/mediatek/patches-6.18/`。
> 若 `--kernel-version` 与补丁上下文不匹配导致某个补丁失败，脚本会打印失败补丁名并退出，
> 请调整版本号（`6.18.x` 系列）后重试。

### 3.2 RootFS

```bash
sudo bash build/build-rootfs.sh \
  --board h5000m \
  --out /path/to/out \
  --kernel-dir /path/to/out/kernel
```

脚本流程：

1. 先执行 `scripts/fetch-firmware.py` 拉取**本板所需**固件到 `build/rootfs/firmware/`
   （H5000M：6 个 MT7992 Wi-Fi + 2 个 MT7987 2p5g PHY；AP3000M：2 个 MT7981 wmac 固件）；
2. debootstrap：宿主为 arm64/aarch64 时走 **native** 模式一次完成（免 qemu 翻译）；
   否则 `--arch=arm64 --foreign trixie <rootfs>` + qemu 第二阶段（x86 宿主兼容路径）；
   传 `--apt-cache-dir` 可复用已下载的 `.deb`（见 §3.7.1）；
3. 拷贝 `qemu-aarch64-static`，`chroot` 内完成第二阶段；
4. 配置 Debian 13 软件源（`deb.debian.org` stable），`apt-get update`；
5. 安装 `build/rootfs/packages.list` 中全部软件包；
6. 应用 `rootfs-overlay/` 通用覆盖层，再叠加 `boards/overlay.d/<board>/` 板级层
   （网络配置、Linux-Router 集成、systemd 服务、`/etc/fstab` 使用 `PARTLABEL=rootfs`；
   板级层同名文件**内容**覆盖通用层，unit 名本身不带板级前缀）；
   并把下载的固件安装到 Debian firmware 对应路径并校验非空；
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
  [--extra-mb 24] [--busybox /path/to/busybox] [--mirror https://deb.debian.org/debian]
```

输出（对应现有 eMMC 分区，**不创建任何分区表**）：

```
out/<BOARD_UPPER>-debian13-kernel.bin        → dd 到 p4（kernel，30 MiB）
out/<BOARD_UPPER>-debian13-rootfs.bin   → dd 到 p5（rootfs，引导层 ext4 镜像，~152 MiB）
```

- `<BOARD_UPPER>-debian13-kernel.bin`：内核 LZMA 压缩 + H5000M DTB 的 FIT 镜像，**与 OpenWrt 同型**
  （U-Boot 现有 `bootm` 流程原样加载），p4 无需文件系统；
- `<BOARD_UPPER>-debian13-rootfs.bin`：**p5 引导层 ext4 镜像**，内含：
  - `/sbin/init`：busybox 引导脚本（挂 SquashFS → 组装 OverlayFS → pivot_root → systemd；
    OverlayFS 组装失败自动进入只读救援模式）；
  - `/usr/bin/busybox`：静态 busybox（脚本自动从 Debian mirror 下载 busybox-static arm64
    并提取，支持 `--busybox` 指定本地文件，构建机缓存于 `out/rootfs/.cache/busybox`）；
  - `/squashfs/rootfs.squashfs`：只读基础系统；
  - `/overlay/{upper,work,merged}`：OverlayFS 可写层（p5 引导层 ext4 = 持久化数据，
    首启由 `router-grow-rootfs` 在线扩容至 4 GiB）；
  - `/boot`：引导文件。`boot.scr` 与 DTB 始终落盘；`extlinux.conf` 与其引用的 `Image`
    仅在加 `--keep-boot-image` 时落盘（默认省空间不生成 ~60 MiB 的重复内核，二者同进同退）。

  镜像以 `mkfs.ext4 -d` 免挂载构建，经 e2fsck + debugfs 三重自检（init / busybox /
  squashfs 逐项存在且大小与源一致）。

> 引导层尺寸公式：`(SquashFS + busybox 字节数) 上取整 MiB + 24 MiB 余量`，再 8 MiB 对齐。
> p5 实际容量（~7.2 GiB）与镜像尺寸无关——刷入后自动 `resize2fs` 扩容至 **4 GiB**（2026-10-09 起不再扩满；正常刷写路径在刷写时离线完成）。

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
  --kernel-fit /path/to/out/<BOARD_UPPER>-debian13-kernel.bin \
  --rootfs-img /path/to/out/<BOARD_UPPER>-debian13-rootfs.bin \
  --dev /dev/mmcblk0 [--backup-full /tmp/emmc-full.img] [--yes]

# 方法二：rootfs tar.zst（兼容模式：p5 直接展开为纯 Debian 树，无引导层/只读根）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/<BOARD_UPPER>-debian13-kernel.bin \
  --rootfs /path/to/out/rootfs/debian13-arm64-rootfs.tar.zst \
  --dev /dev/mmcblk0 [--yes]

# 方法三：在线升级（系统已以 SquashFS+OverlayFS 架构运行时，无需重启/失联）
sudo bash scripts/install-emmc.sh \
  --kernel-fit /path/to/out/<BOARD_UPPER>-debian13-kernel.bin \
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

推送后不会自动触发（仅手动 `workflow_dispatch` 或 `workflow_call`）。**三层入口，实现只有一份**：

| 入口 | 文件 | board | 命令 |
| --- | --- | --- | --- |
| H5000M 专用（推荐） | `build-h5000m.yml` | 写死 `h5000m` | `gh workflow run build-h5000m.yml` |
| AP3000M 专用（推荐） | `build-ap3000m.yml` | 写死 `ap3000m` | `gh workflow run build-ap3000m.yml` |
| 多板合一 | `build.yml` | `board` 输入 | `gh workflow run build.yml -f board=ap3000m` |

两个 `build-<board>.yml` 是**薄壳**：不含任何 job 定义，仅以
`uses: ./.github/workflows/build.yml` 调用基座并写死 `board`。这样 Actions 侧边栏
一眼可见是哪个板卡、并发组/Release tag/Artifact 名按板卡隔离、误选板卡的风险归零
（两板内核配置与 DTB 不同，选错会出砖）；而实现只有一份，改一处两板同时生效。
薄壳须显式授予 `contents: write`（`workflow_call` 权限只收窄不放大，否则建 Release 失败）。

基座 job 有两个：

1. **内核 6.18**：解析板级参数（`boards/board-lib.sh` → job outputs）→ 编译内核
   （含源码 tar 缓存 + ccache）+ 生成 boot.scr → 整理为扁平目录并上传 artifact；
2. **RootFS + 刷写包**：下载内核产物 → 校验关键内核模块已产出 → 交叉编译 mt5700 →
   `debootstrap` 构建 Debian 13 RootFS 树（`--skip-tar`）→ `make-squashfs.sh` 生成只读
   基础系统（zstd）→ `make-sd-image.sh` 生成引导层镜像与 FIT → 组装
   `<BOARD_UPPER>-debian13-sysupgrade.bin`（≈164 MiB）→ chown 修正产物属主 →
   上传 artifact 并发布 Release。

发布成功后自动执行历史 Release 清理：按发布时间倒序保留最近 `keep_releases` 个
（手动触发的输入，默认 `3`，填 `0` 关闭），其余 Release 连同资产与 tag 一并
删除。设计要点：

| 保护措施 | 作用 |
| --- | --- |
| `skip_release=true` 时整体跳过 | 没发新 Release 就不删旧 Release |
| 输入非法（非整数/负数）按不清理处理并告警 | 手滑输入不会把历史 Release 删光 |
| 刚发布的 tag 必在保留集内 | 切片从第 `keep_releases+1` 个开始，不会误删本次产物 |
| 跳过 `draft` | 不动尚未发布的草稿 |
| 先删 Release 再删 tag | 删 Release 不会自动清 tag，反序会留孤儿 tag |
| 每次删除打 `::warning` | Actions 页面可审计删了什么 |

单个 Release 含四个大件约 660 MiB，曾堆积到 11 个 / 8.1 GiB，故改为构建后自动清理。
若需手动清空全部历史 Release，用 `gh release list` 配合 `gh release delete <tag> --yes`
逐个处理，并同步删除对应 tag。

> 安全提示：旧版本 Release 曾附带 `initial-credentials.txt`（明文出厂口令）。当前
> `build.yml` 已不再把该文件放入 Release，出厂凭据只存在于设备内
> `/etc/<board>-initial-credentials`（0600）。仓库为 public，历史上传过的凭据文件任何人
> 都可下载，若曾使用过非默认口令应立即轮换。

产物从 Actions 页面「Artifacts」下载：`<BOARD_UPPER>-debian13-release`
（板卡由入口决定：薄壳已写死；合一入口用 `board` 输入选择，缺省 `h5000m`）
（kernel.bin、rootfs.bin、rootfs.squashfs、sysupgrade.bin、boot.scr、初始凭据）。

### 3.7.1 编译提速设计（实测基线 → 优化）

基线实测（run 37353387707，x86_64 runner 全链路）：

| 步骤 | 实测 | 优化手段 | 预期 |
| --- | --- | --- | --- |
| 构建 Debian 13 RootFS | **67.7 min** | ARM64 原生 runner：debootstrap native 模式，免去 qemu-user 二进制翻译 | ~8-15 min |
| 编译 Linux 内核 | **46.7 min** | ccache 跨运行复用（首次 miss、后续分钟级）；`--jobs` 取 nproc 动态并发 | 命中时 ~3-8 min |
| mt5700 cargo 编译 | 0.9 min | ARM64 上为宿主原生目标，免 rustup target add 与交叉 linker；缓存 cargo registry | ~0.5 min |
| 其余（检出/依赖/下载/打包/上传） | < 3 min 合计 | deb 下载层缓存 + debootstrap `--cache-dir` + modules.tar.zst 走 zstd -T0 多线程 | 基本不变 |

关键实现：

- **Runner 选择**：`runs-on: ${{ inputs.force_x86_runner && 'ubuntu-24.04' || 'ubuntu-24.04-arm' }}`。
  手动触发可勾选 `force_x86_runner` 回退 x86_64（ARM64 runner 不可用/排队时）。
- **native / foreign 自动判定**（`build/build-rootfs.sh`）：宿主为 aarch64/arm64 且目标 arm64
  → `debootstrap` 一次完成；否则 `--foreign` + `qemu-aarch64-static` 第二阶段（旧路径）。
  原生模式下宿主就是目标架构，无需 qemu 也不需要交叉工具链。
- **内核编译模式**（`build/build-kernel.sh`）：宿主 arm64 → native（`CROSS_COMPILE` 置空），
  否则交叉；支持 `--native` / `--cross` 强制覆盖、`--no-ccache` 关闭缓存。
- **ccache 缓存**：`CCACHE_DIR` 指向 workspace，key =
  `ccache-<arch>-<内核版本>-hash(patches/dts/kernel-conf/build-kernel.sh)`；
  输入任一变化即重建缓存，**不会出现配置变了还复用旧目标的脏命中**。
- **下载层缓存**（不缓存构建产物）：`--apt-cache-dir` 复用 Debian `.deb`（debootstrap 侧用
  `--cache-dir`），另缓存 cargo registry。安装动作每次真实执行，结果等同无缓存构建。
- **SquashFS 瘦身副本**：`cp -al` 硬链接代替 `cp -a`（零数据拷贝、省数百 MiB 读写与空间）；
  瘦身操作全为 `rm -rf`（仅解链接），不影响原 RootFS 树。

### 3.7.2 首次运行与缓存观察

- 首次（冷缓存）：内核需完整编译；第二次起 ccache 命中后耗时大幅下降，
  日志末尾会打印 `ccache 统计`（关注 Cacheable calls / Hits 比例）。
- `.deb` 缓存命中时日志出现「预置 N 个缓存 .deb → chroot archives（免重复下载）」。
- RootFS 步骤首行会打印 `构建模式：native/foreign（宿主 Arch=...）`，据此确认走了原生路径。
- 若 ARM64 runner 排队过久或不可用，勾选 `force_x86_runner` 重跑（耗时回到基线水平）。

## 4. 内核版本说明

- 默认 `6.18.54`（ImmortalWrt snapshot 当前使用的 6.18.x 系列）。
- 主线上游内核 **不支持 MT7987A / MT7981B**（pinctrl/clk/eth 等驱动需 ImmortalWrt SDK 补丁），
  因此必须使用补丁内核；
- Wi-Fi：H5000M 的 MT7992 与 AP3000M 的 MT7981B 内置 wmac 均由 mainline mt76 支持，
  无需外部驱动包；AP3000M 另有板级源码层 `airpi-gpio-fan`（GPIO 软 PWM 风扇驱动）。

## 5. 固件获取

```bash
python3 scripts/fetch-firmware.py --out build/rootfs/firmware [--board h5000m|ap3000m]
```

| 板卡 | 固件 | 来源（linux-firmware） |
| --- | --- | --- |
| H5000M | MT7992 Wi-Fi（6 个：dsp / eeprom ×2 / rom_patch / wa / wm） | `mediatek/mt7996/mt7992_*_23.bin` |
| H5000M | MT7987 内置 2.5G PHY（2 个） | `mediatek/mt7987/i2p5ge-phy-*.bin` |
| AP3000M | MT7981B wmac（2 个） | `mediatek/mt7981/mt7981_{wa,rom_patch}.bin` |

> AP3000M 的 Wi-Fi EEPROM **不走固件文件**：由 DTS 的 `nvmem-cells` 从 eMMC
> factory 分区（`eeprom@0`）读取（见 `dts/mt7981b-airpi-ap3000m.dts`）。

该脚本使用 Python 标准库（urllib），跨平台（Windows/macOS/Linux 均可运行），并按板卡
`BOARD_EXTRA_FIRMWARE` 挑选清单。RootFS 构建流程会自动调用它，随后将固件安装至 RootFS
并检查存在且非空；此处手动运行仅用于离线预取/刷新缓存。

## 6. 验证清单（构建后，按板卡各查一遍）

**通用项**（两板相同）：

- [ ] `Image` 为 arm64（`file Image` 显示 `ARM aarch64`）
- [ ] `Image` 含本板 SoC 驱动：`strings Image | grep -i mt7987`（H5000M）/
      `strings Image | grep -i mt7981`（AP3000M）
- [ ] `kernel/` 下存在 `<BOARD_DTB>.dtb`
- [ ] `<BOARD_UPPER>-debian13-kernel.bin` 首 4 字节为 FIT 魔数 `d0 0d fe ed`，且体积 < 30 MiB
- [ ] `rootfs.squashfs` 首 4 字节为 `hsqs`，`unsquashfs -s` 显示 Compression zstd / Block 262144
- [ ] `<BOARD_UPPER>-debian13-rootfs.bin` 可 `e2fsck -fn` 通过；debugfs 确认含
      `/sbin/init`、`/usr/bin/busybox`、`/squashfs/rootfs.squashfs`、`/overlay/{upper,work,merged}`
- [ ] rootfs 内 Linux-Router 服务已 enable；`/usr/local/sbin/router-grow-rootfs` 存在
- [ ] 首启相关服务已 enable：`router-init` / `router-fancontrol` / `router-grow-rootfs` /
      `router-led-boot` / `router-led`（unit 名**不带板级前缀**，板级差异走同名内容覆盖）
- [ ] `kernel/kernel-<board>-soc-options.txt` 存在（SoC 选项快照，按板隔离，避免 artifact 互相覆盖）
- [ ] `<BOARD_UPPER>-debian13-sysupgrade.bin` 体积 ≤ 600 MiB（当前 ≈164 MiB）

**板级项**：

| 板卡 | 固件检查 | DTB 检查 |
| --- | --- | --- |
| H5000M | `/usr/lib/firmware/mediatek/mt7996/` 的 6 个 MT7992 文件 + `mt7987/` 的 2 个 2p5g PHY 文件齐全且非空（构建脚本强制检查） | dtb 名 `mt7987a-hiveton-h5000m.dtb` |
| AP3000M | `/usr/lib/firmware/mediatek/mt7981/` 的 wmac 固件齐全且非空 | dtb 名 `mt7981b-airpi-ap3000m.dtb`；风扇模块 `airpi_gpio_fan.ko` 已产出 |

> **AP3000M 特别说明**：`airpi_gpio_fan` 是**板级内核源码层**
> （`kernel/files-boards/ap3000m/drivers/hwmon/airpi-gpio-fan/`），必须在
> `drivers/hwmon/` 下**同时**注册 `Makefile` 与 `Kconfig` 两处 —— 只注册 Makefile 会让
> 符号不存在、`.config` 的 `=m` 被 `olddefconfig` **静默丢弃**（2026-10-09 两次 CI 失败
> 的真实根因，且两次原因不同）。该不变量由
> `scripts/tests/test-board-kconfig-registration.sh` 在质量门强制校验。

**待实机复核**（云编译**测不到**，必须上机）：

- [ ] 真实 GPT 分区表（`sgdisk -p`）与 `boards/<board>.board` 的
      `BOARD_P4_SECTORS_*` / `BOARD_P5_SECTORS_START` 是否一致
      （不一致时 `install-emmc.sh` 会硬拦拒绝刷写，届时改 board 文件即可）
- [ ] U-Boot `bdinfo` 实际地址与 `BOARD_FIT_LOAD_ADDR`（`0x46000000`）是否冲突
- [ ] AP3000M 风扇：16GB 版 `modprobe airpi_gpio_fan` 后 `/sys/kernel/duty_cycle` 是否出现、
      `fangpio=540` 是否准确；8GB 版 `pwm1` 的实际 hwmon 序号
