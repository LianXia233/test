# 更新文档 (Changelog)

本项目遵循用户规则：任何对仓库的推送/更新，必须同步更新本文档。

## [Unreleased]

### 2026-10-06 — 文档同步至 SquashFS+OverlayFS 架构 + 一键构建链路修复

- **scripts/build.sh 链路修复**（全链改造时遗漏的一键入口）：第 2 步 `build-rootfs.sh`
  加 `--skip-tar`（SquashFS 直接消费树）；新增第 2.5 步调用 `make-squashfs.sh`；
  第 3 步 `make-sd-image.sh` 改传 `--squashfs`（旧 `--rootfs tar.zst` 参数已不存在，
  原链路会直接报"未知参数"）；`--skip-rootfs` 校验改为 RootFS 树存在性；
  产物列表补 `rootfs.squashfs` / 两个 .bin。`bash -n` 语法通过。
- **README.md**：新增"系统架构（SquashFS + OverlayFS）"章节（p5 引导层语义 / 164 MiB
  收益 / 在线升级）；构建命令补 make-squashfs 步骤；Releases 产物更新为
  sysupgrade.bin（≈164 MiB）/ kernel.bin / rootfs.bin / rootfs.squashfs（移除
  tar.zst 与 .bin.zst 解压指引）；首次启动改为"全新刷写 + 在线升级"双命令示例；
  目录结构补 `make-squashfs.sh` 与 `h5000m-grow-rootfs`；验收标准补持久化/可升级条目。
- **docs/architecture.md**：系统总览插入引导层/OverlayFS 层级；新增 §2 存储架构
  （p5 布局、/sbin/init 启动序列、关键保证表、体积收益表）；服务启动顺序补
  init 前置阶段与 h5000m-grow-rootfs；故障矩阵补"OverlayFS 组装失败 → 只读救援模式"行。
- **docs/build-guide.md**：产物清单重写（RootFS 树 + rootfs.squashfs + 引导层镜像 +
  sysupgrade）；依赖补 squashfs-tools；新增 §3.3 SquashFS 章节（瘦身/压缩参数/自检）；
  §3.4 刷写包重写（--squashfs 参数、引导层内容详解、尺寸公式、resize2fs 扩容语义）；
  §3.6 eMMC 刷入改三方法（引导层镜像 / tar.zst 兼容模式 / --rootfs-squashfs 在线升级
  含 .bak 回退）；§3.7 CI 描述更新；验证清单改 SquashFS/引导层逐项检查。
- **docs/first-boot.md**：三方法刷写 + 启动流程插入 /sbin/init 序列（overlay 组装 /
  pivot_root / 救援模式 / grow-rootfs）；验证命令改 overlay 视角（findmnt / 为 overlay、
  /sq 为 squashfs ro）；USB 试运行补引导层 dd 说明（tar 解压 = 兼容模式）。
- **docs/debian13-partition-plan.md**：p5 全文档语义更新为"引导层 ext4"；§6 存放位置
  拆只读基础系统/可写层/引导脚本三行；§9 fstab 同步为布局说明注释（无运行时挂载项）；
  §14 验证补 debugfs 引导层检查与 overlay 启动验证；§15 构建流程补 make-squashfs。
- **docs/troubleshooting.md**：新增 §4「SquashFS / OverlayFS / 只读根」七类故障
  （救援模式进入、根只读、overlay 空间不足、配置丢失、在线升级失败/回退、squashfs
  魔数）；§10 eMMC 固化补在线升级命令；§11 重启恢复补 overlay 检查项。
- **docs/hardware.md**：核对无需改动（无旧架构描述）。

### 2026-10-06 — 固件架构重构：Debian RootFS → SquashFS 只读根 + OverlayFS 持久层（sysupgrade 579 → 164 MiB）

- **背景与目标**：sysupgrade 整包需上传到设备 /tmp（tmpfs 占 RAM）；旧 ext4 固定尺寸镜像
  （540 MiB，更早 1.15 GiB）把空闲空间也封进固件导致 /tmp 放不下。本次从整条构建链改造为
  「Debian 13 Minimal RootFS → SquashFS → OverlayFS 可写层 → H5000M 固件」，同时保持
  BL2 / U-Boot / FIP / u-boot-env / factory / GPT 分区布局与现有启动链 **零改动**。
- **新布局（p5 引导层 ext4，取代整分区 ext4 Debian）**：
  - `/sbin/init`（busybox 引导脚本）：挂 `/squashfs/rootfs.squashfs`（只读）→ 组装
    OverlayFS（lower=/sq，upper/work=p5 引导层 `/overlay`）→ `pivot_root`（旧根保留于
    `/tmpold`，运行期可直接访问 SquashFS 文件）→ 交棒 systemd；
  - OverlayFS 组装失败时进入**只读救援模式**（squashfs 根 + tmpfs，可 SSH 修复，防砖）；
  - `/etc` `/var` `/opt` 等全部写入经 overlay 落在 p5，重启持久保留。
- **构建链改动**：
  1. 新增 `build/make-squashfs.sh`：RootFS 树 → 副本瘦身（apt lists/doc/man/info/locale/日志）
     → `mksquashfs`（默认 zstd -19 -b 256K，`--comp xz` 可选）→ 自检（超块格式 + 抽样 cmp）。
     沙箱实测 514 MiB 树 → zstd **119 MiB** / xz 106 MiB（选 zstd：解压快 5-10 倍，A53 首启友好）；
  2. 重写 `build/make-sd-image.sh`：p5 产物改为引导层 ext4（init + busybox + SquashFS +
     overlay 目录 + /boot 兜底），`mkfs.ext4 -d` 免挂载构建 + e2fsck + debugfs 三重自检；
     busybox-static arm64 自动从 Debian mirror 下载（本地缓存，`--busybox` 可指定）；
  3. `build/build-rootfs.sh`：新增 `--skip-tar`（SquashFS 直接消费树，CI 跳过 tar.zst）；
  4. `build/make-sysupgrade-tar.sh`：root 成员语义更新为引导层镜像，600 MiB 门槛保留；
  5. `scripts/install-emmc.sh`：新增 **`--rootfs-squashfs` 运行中在线升级模式**——仅原子替换
     p5 上的 SquashFS 文件 + 刷新 p4 FIT，overlay 持久化数据全部保留，旧版自动备份
     `rootfs.squashfs.bak`（mv 回即回退）；
  6. 内核 config：`CONFIG_SQUASHFS_ZSTD=y`（XZ/OverlayFS/DEVTMPFS_MOUNT 原已就绪），
     沙箱增量编译 `zstd_wrapper.o` 通过；
  7. workflow：串联 make-squashfs 步骤、依赖加 squashfs-tools、Release 产物
     （sysupgrade + kernel.bin + rootfs.bin + rootfs.squashfs，移除 tar.zst）、
     **新增产物 chown 步骤**（修复旧 run 37353387707 的 upload-artifact EACCES：
     sudo 构建产物为 root 属主，runner 读不了 initial-credentials.txt）。
- **产物体积（沙箱全链实跑）**：kernel FIT 12.4 MiB + 引导层 152 MiB → **sysupgrade.bin
  164 MiB**（v2 slim ext4 579 MiB → 缩小 72%；v1 1.15 GiB → 缩小 86%）；
  设备 /tmp 占用 164 MiB ≪ 600 MiB 约束。字节级闭环校验：sysupgrade 解包 → CONTROL/
  kernel/root 成员 → 引导层内 init/busybox/squashfs 大小全部一致。
- **沙箱验证**：① mksquashfs zstd 超块 + 抽样文件 cmp 一致；② 引导层镜像 e2fsck clean；
  ③ busybox applet（pivot_root/mount/env）核对；④ 两段式真机等价 pivot 序列（引导层成根 →
  pivot 进 merged → `/tmpold/squashfs` 在线升级路径可见）+ chroot(qemu) 执行 arm64 /bin/echo
  全链通过；⑤ overlay 真实挂载与重启持久化端到端列为真机首启验证项（容器无 overlay 挂载权限）。
- **功能兼容**：packages.list 全量保留（NetworkManager / dnsmasq / nftables / hostapd /
  Wi-Fi / Modem / Linux-Router / WebUI / systemd）；fstab 改为布局说明（root 由引导层处理）；
  `h5000m-grow-rootfs` 服务迁入 rootfs-overlay（改用 `findfs PARTLABEL=rootfs` 在线扩容
  p5 引导层至 ~7.2 GiB，作为 overlay 持久层）。

### 2026-10-06 — MT7987 以太网修复：内核 IRQ 三缺陷 + DTS 八中断/板级 MAC（参考 ctr54188/h5000m-debian 真机逆向）

- **来源**：参考仓库 `ctr54188/h5000m-debian`（同型号设备，作者对厂商出货内核 6.6.94 做了
  真机逆向，见其 `docs/ETHERNET-TX-NOTES.md`——kallsyms + 反汇编 + live.dtb 交叉验证）。
- **内核修复（新增 `kernel/patches/997-net-ethernet-mtk_eth_soc-mt7987-eth-irq-fixes.patch`，
  在 750/751 mt7987 支持补丁之上叠加，已适配 6.18.54 枚举与函数名）**：
  1. `mt7987_data.rx.irq_done_mask` 补 `MTK_RX_DONE_INT0`（BIT(16)）——仅清 BIT(14) 会残留
     RX done 位 → **RX IRQ 风暴 + RCU stall**（厂商寄存器行为逆向结论）；
  2. FE 中断分组：MT7987（netsys v3、PPE1 类）必须写 `FE_INT_GRP = 0x210ffff2` 且
     **不触碰 `pdma.int_grp` 分组寄存器**——主线写 `0x21021000`（旧路径）与厂商不一致；
     此项参考仓库 997 补丁未包含，依据其 NOTES 反汇编证据补齐；
  3. 厂商在全部 8 条 eth IRQ 线上注册合并 handler：新增 `mtk_handle_irq_fe`
     （TX+RX 合并处理，非本设备中断源返回 `IRQ_NONE` 防 IRQ 风暴），`mtk_probe` 对
     MT7987 挂满 8 线；`mtk_get_irqs` 按厂商布局填 TX=资源1 / RX=资源2。
- **DTS 修复（`dts/mt7987.dtsi` + `dts/mt7987a-hiveton-h5000m.dts`）**：
  1. eth 节点中断 4 → **8 条**（189/190/191/192 + 196/197/198/199，与厂商 DTB 一致；
     不加 interrupt-names，同厂商 DTB 行为，8 条 IRQ 由 997 补丁按资源序注册）；
  2. gmac2 补 `phy-mode = "internal"` + `fixed-link`（1G 全双工，与已验证厂商 DTB 一致；
     属性顺序已按 dtc 规范置于子节点之前——参考仓库原补丁顺序会被新版 dtc 拒绝）；
  3. 板级 gmac0/gmac1 补 `mac-address`（`0e:c7:2f:5b:6a:84/85`，本地管理地址，来源为
     参考作者真机厂商 DTB；同型号出厂同值，如有独占地址需求可自行修改）；
  4. pcie1 `disabled → okay`（与已验证厂商 DTB 一致，空槽无副作用）。
- **验证**：① 补丁经 `patch -p1 --dry-run` 与 `git apply --check` 双重回放通过；
  ② 沙箱 6.18.54 构建树增量编译 `mtk_eth_soc.o` 通过（gcc 无警告错误）；
  ③ DTS 经 cpp+dtc 编译为 DTB 成功，反解确认 8 条中断值、双 MAC、fixed-link 均已生效。
- **遗留提醒**：本仓库 Wi-Fi（MT7992 hostapd AP）与有线 HNAT flowtable 卸载为参考仓库已
  实现、本仓库未覆盖的功能面，后续按需引入。

### 2026-10-06 — 产出优化：sysupgrade 单文件 + 瘦身（≤600 MiB 内存约束）+ 触发改纯手动

- **背景**：沙箱实测验证（对照参考镜像 `H5000M-.-sysupgrade.bin` 解剖）：
  ① 官方 sysupgrade.bin 为 sysupgrade-tar 格式（CONTROL + kernel FIT + root），sysupgrade 解包后 dd 写 p4/p5；
  ② sysupgrade 会把整包上传到设备 /tmp（tmpfs 占 RAM），此前 1.15 GiB 产出超出设备内存无法刷入，
     约束定为 ≤600 MiB（实测 579 MiB 交付验证通过）。
- **make-sd-image.sh**（默认行为变更）：
  - 新增瘦身模式（默认开启）：清理 apt lists / doc / man / info / 非中英文 locale 翻译；
    `--no-slim` 恢复全量（自动估算尺寸），`--auto-size` 恢复旧估算行为
  - 默认跳过 /boot/Image 冗余副本（p4 FIT 已含同一内核，省 60+ MiB）；`--keep-boot-image` 恢复
  - rootfs 镜像默认 540 MiB（slim 后内容 ~423 MiB，使用率 ~80%）；解压后加 92% 水位防护，
    超限立即失败并给出处置提示（避免解压中途 No space left 难排查）
  - 注入 `h5000m-grow-rootfs.service`（oneshot + marker 防重跑）：首启 resize2fs 在线扩满 p5
    （~7.2 GiB；p5 本为 GPT 全部剩余空间，不触碰分区表）
- **build/make-sysupgrade-tar.sh**（新增）：sysupgrade-tar 单文件封装（`--sort=name` 成员序
  CONTROL→kernel→root 与官方一致；uid/gid 归零、mtime 固定可复现；FIT 魔数预检 + 600 MiB
  内存约束门槛 + CONTROL/成员大小自检）；无 root 依赖，纯 tar。
- **.github/workflows/build.yml**：
  - **触发改纯手动 `workflow_dispatch`**（删除 push / pull_request / schedule）——内核编译 1~2 小时，
    每次推送自动重编几乎不变的内核纯属浪费 runner 时长；出包时 Actions 页面手动 Run 或
    `gh workflow run build.yml`
  - build-image job 新增 "封装 sysupgrade-tar 单文件固件" step；artifact 与 Release 均新增
    sysupgrade.bin（主交付，命名 `H5000M-debian13-<VERSION>-sysupgrade.bin`）
  - Release 发布简化：rootfs 540 MiB < 2 GB 单文件上限，**不再 zstd 压缩**，直接发 rootfs.bin；
    RELEASE-NOTES 重写（sysupgrade -n 推荐刷法 + 首启自动扩容 + 回退说明），
    附 initial-credentials.txt
- **验证**：make-sysupgrade-tar.sh 以沙箱 FIT + slim ext4 实跑，产物与已交付
  `H5000M-debian13-sysupgrade.bin`（579,194,880 B，SHA256 243df178…）同构；脚本全部 LF。

### 2026-10-05 — FIT 打包缺 dtc 导致 mkimage 失败（CI run 37325207380）

- **进展**：mt5700 交叉编译 step 通过（上轮 glibc 头修复生效）；RootFS 构建完成；
  失败点推进到最后的"生成刷写包"——`mkimage 打包 FIT 失败`。
- **根因**：`mkimage -f` 打包 FIT 时会**调用外部 `dtc` 二进制**编译 ITS（并非内嵌）；
  workflow 用 `--no-install-recommends` 安装 u-boot-tools 不会带入
  device-tree-compiler → ITS 编译失败。此前该代码路径从未真正执行到（上上轮死于
  自拷贝、更早轮死于其他错误），本次为首次暴露。沙箱因已装 device-tree-compiler
  1.7.0 而通过（环境差异型失败，与上轮同类）。
- **修复**：workflow apt 增加 `device-tree-compiler`（附注释说明原因）；
  make-sd-image.sh 工具检测加 `dtc`；mkimage 失败时不再吞 stderr（仅屏蔽 stdout），
  die 提示指向 dtc；`SIGN_ARGS=()` 显式空数组初始化（set -u 防御）。

### 2026-10-05 — 交叉编译环境补全：aarch64 glibc 头文件缺失（CI run 37317806045）

- **失败现象**：新 step "交叉编译 luci-app-mt5700" 中 ring 0.17.14 的 C 代码编译报
  `/usr/include/stdint.h:26:10: fatal error: bits/libc-header-start.h: No such file
  or directory`（aarch64-linux-gnu-gcc 编 curve25519.c）。
- **根因**：runner 只装了 `gcc-aarch64-linux-gnu`（编译器本体），未装 aarch64 的
  glibc 头文件包；gcc-cross 的 `stdint.h` 经 `include_next` 落到宿主 x86_64 的
  `/usr/include/stdint.h`，其 `bits/` 头不在 aarch64 搜索路径。沙箱验证时装的是
  `crossbuild-essential-arm64` 元包（含 `libc6-dev-arm64-cross`，提供
  `/usr/aarch64-linux-gnu/include`），故未复现——环境差异型失败。
- **修复**：workflow apt 依赖 `gcc-aarch64-linux-gnu` → `crossbuild-essential-arm64`
  （与 build-kernel job 一致）；build-mt5700.sh 增加前置检查——缺
  `/usr/aarch64-linux-gnu/include/bits/libc-header-start.h` 时 die 并提示安装命令，
  失败信息从 cc-rs 深处提前到脚本入口。
- 内核 job 全绿（未改动）；其余链路不变。

### 2026-10-05 — MT5700M 插件切换为 luci-app-mt5700 Debian 分支（单服务架构）+ 修复 make-sd-image.sh 自拷贝（CI run 37295444686）

**变更 A：mt5700 预装方案重写（"Release ipk + vendor 面板"双服务 → Debian 分支单服务）**

- **新架构**：luci-app-mt5700 `Debian` 分支（commit `76d1f82`）——单一 Rust 后端
  `at-webserver` 2.0.0 一体化承载 **WebUI + HTTP API + WebSocket（0.0.0.0:9000）**，
  移除 OpenWrt/LuCI/ubus/rpcd/UCI 依赖；替代原 `at-webserver-rust`(RPC :8765) +
  `mt5700-web`(面板 :8181) 双服务。
- **二进制来源**：Releases 无 Debian 分支资产（仅 OpenWrt musl ipk/apk），改为
  **CI 内交叉编译**：新增 `build/build-mt5700.sh`，浅克隆 Debian 分支并 **pin commit
  `76d1f82e5a00b6622da15ffb64d8be630073ffb2`**（可复现，升级插件时同步更新）；
  依赖链 tokio/serde/ureq(rustls)——rustls 的 ring 组件含 C/asm 代码，需目标平台
  C 编译器：默认 **aarch64-unknown-linux-gnu**（gcc-aarch64-linux-gnu，构建机
  ubuntu-24.04 glibc 2.39 ≤ Debian 13 的 2.41，向后兼容；rootfs 已含 libgcc-s1），
  musl 静态备选需自备 aarch64-linux-musl-gcc（apt 无此包）。staging 产物
  （二进制 + webui/ + debian/ 配置 + PROVENANCE.txt）经 `--mt5700-dir` 供
  build-rootfs.sh 消费。
- **安装布局**（与上游 debian/install.sh 一致）：`/usr/bin/at-webserver` +
  `/usr/share/mt5700/webui/` + `/etc/mt5700/{config.json,on-uplink.sh}` +
  `/etc/systemd/system/at-webserver.service`（SupplementaryGroups=dialout、
  ProtectSystem=strict + ReadWritePaths）。
- **清理**：删除 rootfs-overlay 的旧 `at-webserver.service`(ExecStart=at-webserver-rust)、
  `mt5700-web.service`、`etc/config/at-webserver`（UCI 残留）、
  `usr/libexec/at-webserver/on-uplink.sh`，以及整个 `build/rootfs/vendor/mt5700/`
  （面板二进制 + LuCI 静态资源 + PROVENANCE.md，约 60 文件）；systemd enable 列表
  移除 mt5700-web.service。
- **端口/防火墙**：motd 模组面板提示 8181 → 9000；nftables 无需改动（`iifname
  "br-lan" accept` 已覆盖 :9000，WAN 侧 policy drop 不变）。
- **CI**：build-image job 新增"交叉编译 luci-app-mt5700 at-webserver"step（RootFS
  构建前执行），build-rootfs.sh 调用加 `--mt5700-dir out/mt5700`。

**变更 B：make-sd-image.sh 修复（run 37295444686 "生成刷写包"失败）**

- 失败现象：`cp: '/tmp/h5000m-img.XXXX/Image.lzma' and '/tmp/h5000m-img.XXXX/Image.lzma'
  are the same file`。
- 根因：`IMAGE_LZMA="$WORK/Image.lzma"`（lzma 压缩已直接输出到该路径）后，ITS
  heredoc 之前遗留一行 `cp -f "$IMAGE_LZMA" "$WORK/Image.lzma"` 自拷贝（源=目标），
  GNU cp 报错退出。`/incbin/("Image.lzma")` 以 `cd "$WORK"` 为 cwd，文件本就在
  正确位置，该行纯冗余 → 删除（DTB 跨目录复制保留）。
- 顺手修复：`die()`/`log()` 定义移至文件入参校验之前（原 79-81 行在函数定义前
  调用 die，触发时报 command not found 而非友好错误信息）。

**本地验证**：`bash -n` 全部脚本通过；FIT 打包段 mkimage 模拟（假 Image/DTB，魔数
d0 0d fe ed 校验）通过；沙箱实测 build-mt5700.sh 完整链路（浅克隆固定 commit →
cargo 交叉编译 aarch64-gnu → staging → ELF/aarch64 自检）通过。

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
