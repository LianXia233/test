# 更新文档 (Changelog)

本项目遵循用户规则：任何对仓库的推送/更新，必须同步更新本文档。

## [Unreleased]

### 2026-10-05 — Release 的 rootfs 镜像改为 .zst 压缩发布（规避 GitHub 单文件 2 GB 上限）

- **产物变更**：Release 中 `H5000M-debian13-<版本>-rootfs.bin`（裸 ext4）替换为
  `H5000M-debian13-<版本>-rootfs.bin.zst`（zstd -12 压缩）。裸 ext4 镜像受 GitHub
  Releases 单文件 2 GB 硬限制约束，本库 rootfs 按"内容 + 512 MiB 余量"自适应估算，
  逼近或超过 2 GB 时 Release 上传会直接失败；ext4 空闲区均为 0，zstd 压缩率极高。
- **刷写流程**：下载后先 `zstd -d H5000M-debian13-<版本>-rootfs.bin.zst` 解压，
  再按原流程 `install-emmc.sh --rootfs <解压出的 .bin>` 刷写；RELEASE-NOTES 已同步。
- **不变项**：kernel.bin 仍为 FIT（内核 LZMA 压缩内嵌，U-Boot bootm 直接启动）；
  Actions Artifact 保留原始 `.bin`（artifact 无 2 GB 单文件限制），本地构建仍产出 `.bin`。
- README 的 Release 产物说明同步更新。

### 2026-10-05 — usrmerge /lib 符号链接被 tar 破坏导致 chroot 崩溃（CI run 37271056282）

**进展**：内核 job 全绿（31 项配置核验 + 全量编译 + 16 项新增配置编译通过）；
build-image 中跨 job 路径、模块校验、**mt5700 预装（首次 CI 验证通过）**均过关。

**失败点**：第 10 步 chroot 报
`aarch64-binfmt-P: Could not open '/lib/ld-linux-aarch64.so.1': No such file or directory`。

**根因**：Debian 13 为 usrmerge 布局（`/lib` 是指向 `/usr/lib` 的符号链接）。
第 9 步 `tar -xf modules.tar.zst -C "$ROOTFS_DIR"` 解压时，存档中的 `lib/` 目录条目
会让 GNU tar **删除目标上的符号链接并重建真实目录** → `/lib` 不再指向 `/usr/lib`，
aarch64 动态链接器消失，chroot 崩溃（第 3/5 步 chroot 正常、第 9 步之后立即崩溃，
佐证破坏点就在 modules 解压）。

**修复**：`build-rootfs.sh` 第 9 步改用
`tar --keep-directory-symlink -I zstd -xf ...`，跟随符号链接写入（模块落到
`/usr/lib/modules`）。本地 usrmerge 复现验证：修复前 `lib` 由符号链接变成真实目录，
修复后符号链接保留、ld.so 可用、模块落点正确。已确认脚本内解压到 `ROOTFS_DIR`
的 tar 仅此一处（其余为 rsync overlay 与最终打包，均不破坏符号链接）。

### 2026-10-05 — 844 cpufreq 补丁适配 6.18.54 + 跨 job 产物路径修复 + 参考 ctr54188/h5000m-debian 补齐配置

**内核补丁（CI run 37264647296：35 秒失败）：**

- **844-cpufreq MT7987 补丁重写**：原补丁针对含 `mt7986_platform_data` 与 `mediatek,mt7988d`
  的内核版本编写，6.18.54 两者皆无 → 两个 hunk 上下文均不匹配，`git apply` 与 `patch` 回退
  双失败，`--strict` 下内核 job 直接终止（旧 CI 靠 `--skip-failed-patches` 跳过，
  MT7987 cpufreq 从未真正启用）。现按 6.18.54 实际源码重排 hunk：插入点移至
  `mt7623_platform_data` 之后、移除不存在的 mt7988d 上下文行；语义不变
  （`proc_max_volt=1023000` + `mediatek,mt7987` DT match）
- **验证**：干净 6.18.54 树全补丁序列（backport/pending/hack/mediatek，200+）应用成功；
  aarch64 交叉编译 `mediatek-cpufreq.o` 通过，`nm` 确认 `mt7987_platform_data` 与
  `mediatek,mt7987` 编入目标文件

**CI 跨 job 产物传递（CI run 37265754864：build-image `cp: cannot stat`）：**

- **根因**：`upload-artifact@v4` 以所有上传路径的公共根为基准保留相对路径；混合上传
  `out/kernel/*` 与 `out/boot/*` 时公共根为 `out/`，artifact 内实际为 `kernel/Image`、
  `boot/boot.scr`，下载侧按扁平路径取值即失败
- **修复**：上传前集中到 `out/kernel-artifacts/` 单一目录；下载侧打印产物结构并按文件名
  兜底定位；顺带复制 `kernel-config-exported.config` / `kernel-mt7987-options.txt`

**参考 ctr54188/h5000m-debian 的优化（配置与 CI）：**

- **内核配置补全**（16 项，均本地验证 olddefconfig 生效 + 交叉编译通过）：
  - WAN 拨号：`PPP` / `PPPOE` / `PPP_ASYNC` / `PPP_MPPE`
  - 硬件流卸载：`NF_FLOW_TABLE` / `NF_FLOW_TABLE_INET` / `NFT_FLOW_OFFLOAD`
  - 2.5G PHY：`MEDIATEK_2P5GE_PHY` / `MTK_NET_PHYLIB`（752 补丁已支持 MT7987，此前未编驱动）
  - 5G 模组 USB WWAN 栈：`WWAN` / `MTK_T7XX` / `USB_NET_QMI_WWAN` / `USB_NET_CDC_MBIM` /
    `USB_WDM` / `USB_ACM` / `USB_SERIAL_OPTION`（MT5700M 等 USB 模组必需）
- **配置回归校验扩充**：`REQUIRED_SYMBOLS` 由 21 项增至 31 项，覆盖上述新增项
  （参考库 README §5.1.1 教训：配置未写进片段会在换环境重编时静默丢失）
- **CI 健壮性**：`cancel-in-progress: true` → `false`（此前已误杀一次完整编译）；
  两个 job 增加 `timeout-minutes`（内核 330 / RootFS 180）
- **产物校验**：RootFS 构建前校验 `modules.tar.zst` 内 `qmi_wwan` / `cdc_mbim` / `option` /
  `mtk_t7xx` 存在（mt7996e / mt76-connac-lib / pwm-fan 为 `=y` builtin 不产生 .ko，
  由 `REQUIRED_SYMBOLS` 按 .config 校验）

**未采纳的参考库方案（附理由）：**

| 参考库方案 | 不采纳原因 |
|---|---|
| hostapd 5GHz 80MHz 配置 | 本库无线走 NetworkManager（`h5000m-router-init.sh` 用 nmcli 建 wlan0/wlan1 AP），无 hostapd |
| 首启 resize2fs + swap 服务 | 用户明确要求分区与 CI 对齐、暂不扩容 |
| eth IRQ 修复（997 补丁，注册 8 条中断线） | 针对 6.12 的驱动级改动，6.18 移植需实机验证，风险高，列入待办 |

### 2026-10-05 — 内核产物收集修复 + RootFS 预装 luci-app-mt5700（局域网可访问）

**编译失败修复（CI run 37258658236：`tar: lib: Cannot stat`）：**

- **modules_install 路径修复**：`build-kernel.sh` 的 `INSTALL_MOD_PATH` 原为相对路径，
  经 `make -C "$KERNEL_SRC"` 切换工作目录后被解析进内核源码树内部
  （`$KERNEL_SRC/out/...`），导致 `$MODULES_ROOT/lib` 不存在、收集产物阶段
  `tar: lib: Cannot stat: No such file or directory`。现统一将 `OUT_DIR` 规范化为绝对路径
  （`mkdir -p` + `cd && pwd`），`make -C` 与 `tar -C` 落点一致
- **modules_install 健壮化**：输出落盘 `work/modinst.log`（不再 `>/dev/null` 静默），
  失败打印日志尾部并终止；新增 `lib/modules` 产出校验
- **modules.tar.zst 名实相符**：打包由 `tar -cJf`（实为 xz）改为 `tar --zstd -cf`（真 zstd），
  与 RootFS 侧 `tar -I zstd -xf` 解压方式匹配（原组合会在 RootFS 步骤解压失败）

**CHANGELOG 已声明但未落地的 12 项修复补齐：**

- **CONFIG_PWM_FAN → CONFIG_SENSORS_PWM_FAN**：6.18 起符号改名
  （drivers/hwmon/Kconfig:1887），配置片段与 `REQUIRED_SYMBOLS` 核验同步更新；
  已在 6.18.54 上本地复现 defconfig+片段+olddefconfig 验证解析为 `=y`
- **补丁应用判定重构**：目录缺失显式 `[SKIP]`；git apply 失败但 patch 回退成功记
  `[OK]（回退）`；仅两者均失败才 `[FAIL]`
- **CI 改传 `--strict`**：补丁失败或关键配置缺失时终止构建（PWM_FAN 符号修复后可安全启用）
- **RootFS 容量自动估算**：`make-sd-image.sh` 未传 `--rootfs-size` 时按 tar 包内容求和
  （+512 MiB 余量、8 MiB 对齐、上限 7372 MiB ≈ eMMC p5 7.2 GiB），移除硬编码 4096 默认值

**RootFS 预装 luci-app-mt5700（对齐 H5000M udev 参考包）：**

- **at-webserver-rust（AT 后端）**：CI 从 Release
  [`v1.14.2`](https://github.com/LianXia233/luci-app-mt5700/releases/tag/v1.14.2) 的
  aarch64 ipk 提取（静态链接 musl，可直接运行于 Debian glibc），URL 锁定于
  `build-rootfs.sh` 的 `MT5700_IPK_URL`
- **mt5700-web（模组管理面板）**：二进制 + `/usr/share/mt5700-panel/www` 静态资源
  vendor 入库 `build/rootfs/vendor/mt5700/`（来源与更新指引见其 `PROVENANCE.md`；
  该二进制暂无公开发布渠道，暂取自 udev 参考包镜像，glibc 动态链接适配 Debian 13）
- **systemd 单元**：`at-webserver.service`（AT 后端）、`mt5700-web.service`
  （面板，`--bind 0.0.0.0 --port 8181 --rpc 127.0.0.1:8765`），chroot 阶段 enable
- **配置**：`/etc/config/at-webserver` 取 ipk 原版（`network_restrict_access '0'` 允许局域网）
- **局域网访问**：面板绑定 0.0.0.0:8181，`nftables.conf` input 策略 drop 下仅 br-lan 放行
  → LAN 可直达，WAN / 5G 上行（enx*/wwan*/usb*）不可达；RPC(8765) 保持本机回环，
  面板服务端代理转发
- **自检**：预装二进制 ELF 魔数 + aarch64 (e_machine=183) 校验（构建机无需运行二进制）
- 分区布局维持 CI 现状（p4 30 MiB FIT + p5 ~7.2 GiB ext4），**不做首启扩容**

### 2026-10-05 — 编译流程健壮性修复（12 项）

依据 H5000M-build-flow-review 所列问题逐项修复（默认密码兜底逻辑保持不变）：

- **补丁核验升级（strict）**：CI 内核编译改传 `--strict`（移除 `--skip-failed-patches`）；
  补丁应用失败或关键配置符号缺失时直接终止构建，不再静默吞错 / 仅告警
- **补丁应用判定重构**：`apply_patch_series` 目录缺失显式 SKIP；git 失败但 patch 回退成功
  记为 OK（标注回退），仅 git / patch 均失败才置 FAIL 并终止
- **CI 缓存策略修正**：`actions/cache` 仅缓存原始源码压缩包
  `out/kernel/linux-${{ env.KERNEL_VERSION }}.tar.xz`（key 按内核版本固定、无 restore-keys）；
  源码树每次干净解压，补丁幂等，同时减小缓存体积、提高命中率
- **模块包压缩名实相符**：`modules.tar.zst` 改 `tar --zstd -cf`（真 zstd），
  RootFS 解压同步 `tar -I zstd -xf`
- **apt 注释过滤**：RootFS 软件包安装命令 `grep -vE '^\s*#'` 剔除 `packages.list` 注释行
- **extlinux 补 earlycon**：extlinux.conf 的 APPEND 补充
  `earlycon=uart8250,mmio32,0x11000000`（与 FIT 刷写包一致）
- **RootFS 容量自动估算**：未传 `--rootfs-size` 时解压探测内容大小 +512 MiB 余量、
  8 MiB 对齐，上限 7372 MiB（eMMC p5 约 7.2 GiB）；CI 移除硬编码 `--rootfs-size 4096`
- **FIT 可选签名**：`make-sd-image.sh` 新增 `--sign-key <dir>`，提供密钥目录时在 ITS config
  注入 `signature-1`（sha256,rsa2048）并以 `mkimage -k` 签名；未提供则维持无签名行为
- **Release 版本号防覆盖**：命名追加 GitHub Run 序号（`%y.%m.%d-r${GITHUB_RUN_NUMBER}`），
  同日 / 同时重跑不再覆盖旧 Release
- **移除调试开关**：删除常开的 `ACTIONS_STEP_DEBUG` / `ACTIONS_RUNNER_DEBUG`
- **cpufreq 补丁兼容修复**：`kernel/patches/844-cpufreq-mediatek-Add-support-for-MT7987.patch`
  修复 6.18.54 下 `proc_fixed_volt` 兼容问题
- 同步更新：`build/build-kernel.sh`、`build/build-rootfs.sh`、`build/make-sd-image.sh`、
  `scripts/build.sh`、`.github/workflows/build.yml`

### 2026-10-04 — LED 控制：复刻官方 OpenWrt 固件方案

- 实测官方固件 `H5000M-.-sysupgrade.bin`（diag.sh / leds.sh / 内核 FIT DTB）：
  - 官方 DTS 与我们一致：`led-3=amber:wlan-2ghz`、`led-4=blue:wlan-5ghz`（gpio-leds，GPIO3/4 active-low）
  - aliases：`led-boot=led-4`（蓝）、`led-failsafe/upgrade=led-3`（琥珀）；系统就绪后无运行 LED
- 新增 `/usr/local/sbin/h5000m-led.sh`：复刻官方 get_dt_led 解析（label→chan-name→color:function）
  与 set_state 行为（boot=蓝灯 100/100 快闪、failsafe=琥珀 50/50、upgrade=琥珀 200/200、done=熄灯）
- 新增 systemd 服务（rootfs-overlay/etc/systemd/system/）：
  - `h5000m-led-boot.service`：启动早期蓝灯快闪（内核 timer trigger，oneshot 退出仍闪烁）
  - `h5000m-led.service`：multi-user.target 后就绪熄灯（done 状态）
- 同步更新：docs/hardware.md（LED 章节）、docs/first-boot.md（默认状态表）

### 2026-10-04 — 默认配置统一：SSH 局域网访问 + 固定默认密码 + 同名双频 WiFi

- Releases 编译产物默认即为「系统默认配置」：
  - **SSH**：root / `password`，仅允许局域网（br-lan）访问；WAN 侧不放行（避免公网暴露）
  - **Wi-Fi**：2.4G 与 5G 同名 **`OWRT`**，密码 **`12345678`**（/etc/default/h5000m-router 与
    h5000m-router-init.sh 兜底默认值同步）
  - **WebUI**：admin / `password`
- 构建默认密码固定为 `password`（`build/build-rootfs.sh`），不再随机生成；
  `/etc/h5000m-initial-credentials` 仍记录首次凭据，提示登录后立即修改
- 同步更新：`docs/first-boot.md`（默认值表与首次登录说明）

### 2026-10-04 — CI 编译产物上传到 GitHub Releases（参考 OpenWrt 发布惯例）

- 容器格式统一为 **`.bin`**（内核 FIT / rootfs ext4），其余命名、版本、校验与 OpenWrt 一致：
  - `H5000M-debian13-<日期>-kernel.bin`（→ p4，FIT，U-Boot bootm 直接启动）
  - `H5000M-debian13-<日期>-rootfs.bin`（→ p5，ext4 RootFS）
  - `H5000M-debian13-<日期>-rootfs.tar.zst`（RootFS 压缩包，可选刷写方式）
  - `sha256sums.txt`（参考 OpenWrt Releases 校验和）
- `.github/workflows/build.yml`：
  - `build-image` job 增加 `permissions: contents: write`
  - 新增「上传固件到 GitHub Releases」步骤（`gh release`，仅非 PR 触发）
  - Release tag 使用 `H5000M-debian13-26.10.04` 日期版本（命名带机型）；同名 tag 先删除后重建（支持每周定时/多次构建覆盖更新）
  - Release Notes 引用 `docs/first-boot.md` 刷写说明；初始凭据仅在 Artifact 交付（不公开上传）
- 新增 `.gitattributes`：仓库强制 **LF 行尾**（`* text=auto eol=lf`，二进制 png/ico 排除），
  Windows 检出同样保持 LF，杜绝 CRLF 导致 BusyBox ash / procd 启动失败


### 2026-10-04 — 刷写包产物改用 .bin 命名（与官方 H5000M-...sysupgrade.bin 风格一致）

- 构建产物由 `h5000m-kernel.fit` / `h5000m-rootfs.ext4.img` 更名为 **`.bin` 格式**：
  - `out/H5000M-debian13-kernel.bin`（内容仍为裸 FIT 镜像，→ p4，U-Boot bootm 直接加载）
  - `out/H5000M-debian13-rootfs.bin`（内容仍为 ext4 镜像，→ p5）
- 同步更新：`build/make-sd-image.sh`、`scripts/install-emmc.sh`、`scripts/build.sh`、
  `boot/boot.cmd`、`.github/workflows/build.yml`（Artifact 产物路径）及全部文档引用
  （README / docs/build-guide / first-boot / troubleshooting / debian13-partition-plan）


### 2026-10-04 — 官方固件实测验证（下载 H5000M sysupgrade.bin 逐项核对启动链）

下载官方固件 `H5000M-.-sysupgrade.bin`（ImmortalWRT SNAPSHOT, mediatek/filogic, aarch64_cortex-a53）
并实测分析，用真实数据验证 / 修正分区方案：

**实测确认（与方案一致）：**

- 固件为新式 sysupgrade tar 包：`sysupgrade-hiveton_h5000m/{CONTROL,kernel,root}`，`BOARD=hiveton_h5000m`
- p4 内容为**裸 FIT 镜像**（魔数 `d00dfeed`），内核 LZMA 压缩；`mkimage -l`：
  `ARM64 OpenWrt FIT` / `Linux-6.18.52` / `kernel-1` + `fdt-1` + `config-1`，每镜像 crc32 + sha1 双哈希
- bootargs（DTB chosen）：`earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf`
- GPT PARTLABEL 定位：`lib/upgrade/platform.sh` 设 `CI_KERNPART="kernel" CI_ROOTPART="rootfs"`，
  `lib/upgrade/emmc.sh` 按 PARTLABEL `find_mmc_part` 后 **dd 仅写 kernel/rootfs 两分区**（与本方案"只写 p4/p5"一致）
- p2 `factory`：DTB `block-partition-factory { partname = "factory"; nvmem-layout }`（Wi-Fi EEPROM）
- 网口映射：`etc/board.d/02_network` → `ucidef_set_interfaces_lan_wan "eth0" eth1`（LAN=eth0 / WAN=eth1）
- MAC 生成：`macaddr_generate_from_mmc_cid mmcblk0`（LAN），WAN=LAN+1
- eMMC：DTB `mmc@11230000` `mmc-card` `non-removable`（无 SD 卡槽）

**修正（基于实测）：**

- FIT **load/entry 地址 0x40000000**（原假设 0x46000000，实测官方 FIT 同值，已修正）
- FIT 节点命名与官方同构：`kernel-1` / `fdt-1` / `config-1` / `hash-1`(crc32) / `hash-2`(sha1)（消除 `@` 单元地址警告）
- bootargs 补 `earlycon=uart8250,mmio32,0x11000000`（与官方 chosen 一致，各处文档/脚本已同步）
- `make-sd-image.sh`：`mkimage` 调用前 `cd` 到工作目录（`.its` 的 `/incbin/()` 为相对路径，修复潜在打包失败）
- 用官方内核数据实测验证：按新 `.its` 生成的 FIT 与官方哈希逐字节一致（crc32 `ffeed093`、sha1 `3ed2ff7d…`）
- `docs/debian13-partition-plan.md` 新增 §1.2「官方固件实测验证」

### 2026-10-04 — 分区方案重构：完整复用现有 OpenWrt eMMC 布局（不重建 / 不重排）

**核心原则落地**：以设备当前正常运行的 OpenWrt 分区布局 / 启动链 / DTS 为唯一基准，
BL2 / U-Boot / FIP / u-boot-env / factory / GPT / eMMC 硬件配置 **零写入、零改动**；
Debian 13 仅复用并替换 kernel（p4）与 rootfs（p5）两个分区的**内容**。

**新增：**

- `docs/debian13-partition-plan.md`：完整分区方案
  - 当前 OpenWrt 分区表（p1 u-boot-env 1MiB / p2 factory 2MiB / p3 fip 4MiB /
    p4 kernel 30MiB / p5 rootfs ~7.2GiB）与启动链对应关系（BootROM → BL2 → FIP →
    U-Boot 读 p4 FIT → bootm → root=PARTLABEL=rootfs 挂载 p5）
  - 不可修改区域清单；Debian 13 最终分区表（与 OpenWrt 完全一致，零结构变化）
  - U-Boot 加载 Debian Kernel 的方式（p4 FIT + bootm，与 OpenWrt 同型，无需 EFI/GRUB）
  - 内核定位 RootFS 的 bootargs、`/etc/fstab`、覆盖区域、备份方案、GPT 备份损坏分析与处理、
    刷写后验证方案

**修改（对齐新分区方案）：**

- `scripts/install-emmc.sh`：**不再创建/重建 GPT**（删除 mklabel/mkpart），仅：
  只读校验现有分区表（含 p5 PARTLABEL=rootfs 校验）→ 写 p4（FIT）→ 写 p5（ext4 /
  解压 tar.zst）→ 回读校验；支持 `--kernel-fit` / `--rootfs` / `--rootfs-img` /
  `--backup-full` / `--backup-p45`；绝不触碰 p1-p3 / GPT / eMMC 硬件配置
- `boot/boot.cmd`：备用引导脚本，主引导为 p4 FIT（现有 U-Boot bootm，无需本脚本）；
  兜底路径从 p5（mmc 0:5）`/boot` 加载 Image + DTB 后 booti
- `build/make-sd-image.sh`：改为生成**刷写包**（`h5000m-kernel.fit` → p4、
  `h5000m-rootfs.ext4.img` → p5），不再创建分区表 / 不写块设备；
  FIT 内核 LZMA 压缩（p4 仅 30MiB），与 OpenWrt 同型；rootfs 内预置 `/boot` 备用引导文件
- `scripts/build.sh`：一键构建步骤 3 改为生成刷写包（移除废弃的 `--dev/--img` 参数）
- `.github/workflows/build.yml`：构建步骤改为生成 `h5000m-kernel.fit` +
  `h5000m-rootfs.ext4.img` 刷写包产物
- 文档：README（分区与启动 / 首次启动 / 目录结构 / 验收标准）、
  docs/build-guide.md（刷写包生成与 eMMC 刷入）、docs/first-boot.md（仅写 p4/p5 流程、
  USB 试运行改为手动制作）、docs/troubleshooting.md（U-Boot 引导 / eMMC 刷入排查对齐新流程）

### 2026-10-04 — 风扇温控 + U-Boot 兼容 + eMMC 刷入 + GitHub Actions 云编译

**风扇控制（参考 luci-app-h5000m-fancontrol 行为）：**

- 内核：`CONFIG_PWM_FAN=y`（pwm-fan hwmon，`/sys/class/hwmon/*/pwm1` + thermal cooling device）
  - `build/kernel-conf/h5000m-6.18.config` 启用 PWM / PWM_MEDIATEK / PWM_FAN
  - `build/build-kernel.sh` 的 `REQUIRED_SYMBOLS` 增加 `CONFIG_PWM_FAN` 核验
  - DTS 删除 cpu-thermal 中风扇相关 cooling-maps（`cpu-active-high/low`、`cpu-passive`），
    保留 CPU 频率缩放与 critical/hot trips，避免内核 governor 与用户空间争抢 PWM
- `rootfs-overlay/usr/local/sbin/h5000m-fancontrol`：Debian 版风扇控制器（systemd 服务）
  - 自动曲线（silent/balanced/performance/custom）、手动 PWM、kernel 仅内核保护模式
  - 温度滞回、降速延迟、启动助推（Start PWM）、传感器/曲线故障保护（Failsafe PWM）
  - 温度来源 max（CPU/PHY/WiFi/5G 模组取最高）或 cpu；接管 thermal zone 策略前先保存并退出恢复
- `rootfs-overlay/etc/default/h5000m-fancontrol`：默认配置（ENABLED/MODE/CURVE/TEMP_SOURCE 等）
- `rootfs-overlay/etc/systemd/system/h5000m-fancontrol.service`：开机自启，失败自动重启
- `build/build-rootfs.sh`：overlay 后 chmod 风扇脚本 + chroot 内 enable 服务

**U-Boot 兼容（不修改 U-Boot 本体）：**

- `boot/boot.cmd`：U-Boot 启动脚本源文件（eMMC → USB 依次尝试，booti 启动）
- `build/make-boot.sh`：用 mkimage 生成 `boot.scr`（ImmortalWrt/OpenWrt Filogic U-Boot 自动加载）
- `build/make-sd-image.sh`：boot 分区自动放入 boot.scr，无 boot.scr 时回退 extlinux 并告警
- `scripts/install-emmc.sh`：eMMC 刷入脚本（GPT：p1 vfat boot + p2 ext4 rootfs，
  可选整盘备份、可选 fw_setenv 设置 U-Boot 环境）

**GitHub Actions 云编译：**

- `.github/workflows/build.yml`：push / PR / workflow_dispatch / 每周定时触发
  - Job 1 内核编译（ubuntu-24.04，内核源码缓存，产物 artifact）
  - Job 2 RootFS + SD 镜像（debootstrap + qemu-user-static，上传发布 artifact）
- `.gitignore`：out/、镜像、凭据、日志等

**文档：**

- README：目录结构、快速开始、云编译、eMMC 固化说明
- docs/build-guide.md：boot.scr 生成、CI、eMMC 刷入
- docs/first-boot.md：install-emmc.sh 固化流程
- docs/hardware.md：风扇控制（DTS/PWM/控制器）
- docs/architecture.md：风扇服务职责与启动顺序
- docs/troubleshooting.md：风扇与启动引导排查

### 2026-10-04 — 初始版本（H5000M → Debian 13 移植）

**新增：**

- 项目骨架：README、docs/（architecture、hardware、build-guide、first-boot、troubleshooting）
- 硬件参考：H5000M DTS（ImmortalWrt master 已验证版本）→ `dts/`
  （mt7987a-hiveton-h5000m.dts + mt7987a.dtsi / mt7987b.dtsi / mt7987.dtsi）
- Linux-Router 源码 vendored → `linux-router/vendor/`（保持上游原始文件，集成层单独放置）
- 内核适配：基于 ImmortalWrt patches-6.18 的 MT7987A 补丁集 → `kernel/patches/`
  （generic/backport、generic/pending、generic/hack、mediatek 四层，按 OpenWrt 标准顺序）
- 固件清单：MT7992（mediatek/mt7996/mt7992_*_23.bin）、MT7987 内置 2.5G PHY（i2p5ge-phy-*.bin）

**内核（M1）：**

- `build/build-kernel.sh`：自动化内核构建（默认 Linux 6.18.54）
  - 按序应用 generic/backport → generic/pending → generic/hack → mediatek 补丁（逐个 `git apply --check`）
  - 复制 OpenWrt files（mtdsplit、mtk_bmt、swconfig 等）→ `kernel/files-generic/`、`kernel/files-mediatek/`
  - 复制 H5000M DTS 并注册 DTB 目标，`olddefconfig` 后核验关键符号，输出 Image / dtb / modules.tar.zst
- `build/kernel-conf/h5000m-6.18.config`：MT7987A 内核配置片段
  （MT7987 pinctrl/clk、mtk_eth_soc、RTL8221B、mt76/MT7992、eMMC、PCIe Gen3、PWM、LVTS thermal、nftables/bridge 全量）

**RootFS（M2）：**

- `build/build-rootfs.sh`：自动化 Debian 13 (Trixie) ARM64 RootFS 构建
  - `debootstrap --foreign trixie` + qemu-user-static 完成第二阶段
  - 安装 `build/rootfs/packages.list`（systemd / NetworkManager / hostapd / dnsmasq / nftables / iproute2 / iw / wireless-regdb / ethtool / bridge-utils / openssh-server 等）
  - 应用 `rootfs-overlay/` 覆盖层 + 集成 Linux-Router + 安装内核/模块 + 生成初始凭据
- `scripts/fetch-firmware.py`：跨平台固件获取（MT7992 / MT7987 PHY 固件，失败可离线重试）

**开箱即用（M3）：**

- `rootfs-overlay/` 运行时配置：
  - `etc/systemd/system/h5000m-router-init.service`：开机编排（WAN/LAN/bridge/Wi-Fi 创建）
  - `usr/local/sbin/h5000m-router-init.sh`：幂等初始化，创建 NM 连接：
    WAN=eth1(DHCP) / br-lan=192.168.88.1/24(+IPv6 ULA) / LAN=eth0(从属) / Wi-Fi AP(2.4G+5G, 桥接 br-lan)
  - `etc/default/h5000m-router`：网络默认配置（网段/SSID/密码/regulatory）
  - `etc/NetworkManager/conf.d/h5000m.conf`：`dns=none`，NM 独占接口管理，DNS 交 dnsmasq
  - `etc/dnsmasq.d/h5000m.conf`：唯一 DHCP+DNS（:53），DHCP 池 + RA/无状态 DHCPv6 + 兜底上游 DNS
  - `etc/nftables.conf`：唯一防火墙/NAT（input drop、WAN 侧仅必要流量、MASQUERADE、IPv6 邻居发现放行）
  - `etc/sysctl.d/90-h5000m-router.conf`：IPv4/IPv6 forwarding、桥接 nf-call 等
  - `etc/systemd/system/router-panel.service` / `router-panel-agent.service`：Linux-Router WebUI 与代理
  - `etc/systemd/system/dnsmasq.service.d/override.conf`：dnsmasq 崩溃自动重启
  - `etc/NetworkManager/dispatcher.d/90-h5000m-wan-dns`：WAN DHCP 后刷新 dnsmasq 上游 DNS
- Linux-Router 集成：预装到 `/opt/linux-router`，修改默认 LAN 网段为 192.168.88.0/24，
  预创建运行账号/数据目录/初始密码，开机自动启动（WebUI http://192.168.88.1）

**镜像与文档（M4/M5）：**

- `build/make-sd-image.sh`：GPT 分区（p1 vfat /boot + p2 ext4 /）生成 USB/SD 启动镜像
- `scripts/build.sh`：一键构建入口（内核 + RootFS + 镜像）
- 文档：docs/architecture.md（服务职责表）、docs/hardware.md（硬件/补丁清单）、
  docs/build-guide.md（构建指南）、docs/first-boot.md（首启不破坏 eMMC）、docs/troubleshooting.md

**已验证/确认：**

- WAN/LAN 物理对应（依据 ImmortalWrt `02_network` + DTS PHY 定义，非名称猜测）：
  - LAN = eth0（gmac0，外置 RTL8221B PHY，远离电源口）
  - WAN = eth1（gmac1，内置 2.5G PHY，靠近电源口）
- 主线上游内核不支持 MT7987A，须使用 ImmortalWrt 6.18 补丁集；MT7992 由 mainline mt76 支持
- Debian 13 仓库不含 MT7992/MT7987 PHY 固件，固件从 linux-firmware / mt76 仓库获取
- nftables ICMPv6 类型名以实际支持为准（`nd-neighbor-advert` / `nd-router-advert`）
- PCIe 符号名以 6.18 为准（`CONFIG_PCIE_MEDIATEK` / `CONFIG_MT76_CORE`）

**网络职责（唯一控制者）：**

| 功能 | 唯一控制者 | 底层实现 |
| --- | --- | --- |
| WAN/LAN/网口/Bridge/Wi-Fi AP | Linux-Router 编排（NM 连接） | NetworkManager |
| DHCP/DNS | dnsmasq（:53，NM `dns=none`） | dnsmasq |
| NAT/防火墙 | nftables（唯一后端） | nftables |
| 服务生命周期 | systemd | systemd |
| WebUI/配置持久化 | Linux-Router | router-panel + agent |

**计划里程碑**

| 里程碑 | 状态 |
| --- | --- |
| M1 内核 | ✅ build-kernel.sh + defconfig + DTS + 补丁集 |
| M2 rootfs | ✅ build-rootfs.sh + packages.list + firmware + overlays |
| M3 开箱即用 | ✅ 路由器配置 + Linux-Router 集成 + systemd 编排 |
| M4 首启介质 | ✅ make-sd-image.sh + scripts/build.sh |
| M5 验证 | ⏳ 沙箱/实机验证（需目标硬件） |
