# 故障排查

## 1. 内核/启动

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| 无串口输出 | 串口接线/速率 | 115200n8；确认 U-Boot 侧 console 配置 |
| 内核 panic 于 dts | DTB 与内核版本不匹配 | 确认 Image 与 dtb 同源构建 |
| 网口不出现 | 补丁未应用完整 | `strings Image \| grep -i mt7987`；重跑 build-kernel.sh |
| 模块缺失 | modules 未安装 | 检查 rootfs `/lib/modules/$(uname -r)/` |
| `earlycon` 无输出 | U-Boot 未传 bootargs | 检查 `chosen/bootargs` 与 U-Boot 环境变量 |

## 2. 风扇控制

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| 风扇不转 | `/usr/local/sbin/h5000m-fancontrol status`；`cat /sys/class/hwmon/hwmon*/pwm1` | 温度低于曲线启动点属正常（如 35°C 以下曲线为 0）；确认 `h5000m-fancontrol.service` 已运行（`systemctl status h5000m-fancontrol`） |
| 风扇满转不停 | `status` 中 `result=failsafe` / `reason=*-failsafe` | 传感器/曲线校验失败进入保护；查 `journalctl -u h5000m-fancontrol`，确认温度源（`control_sensor`）可读 |
| PWM 节点不存在 | `ls /sys/class/hwmon/`；`dmesg \| grep -i pwm` | 内核未启用 `CONFIG_PWM_FAN` 或 DTS 风扇节点未生效（`&fan` status=okay）；重编内核 |
| 温度读取为 -40/150 边界 | `find /sys/class/thermal -name temp` | LVTS 未初始化或传感器失效；确认 `CONFIG_MTK_LVTS_THERMAL=y` |
| 与内核策略争抢 PWM | `cat /sys/class/thermal/thermal_zone*/policy` | 本项目 DTS 已删除风扇 cooling-maps；若升级旧 DTB，需同步新 DTS 或确认策略为用户空间接管后恢复 |
| 修改配置不生效 | `cat /etc/default/h5000m-fancontrol` | 修改后执行 `systemctl restart h5000m-fancontrol` |

## 3. U-Boot 引导 / eMMC 刷入

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| U-Boot 未自动引导 Debian | p4 是否已写入 FIT；p5 是否已写入 Debian | `dd if=/dev/mmcblk0p4 bs=1 count=4 | od -An -tx1` 应为 `d0 0d fe ed`；重新运行 `scripts/install-emmc.sh`（先备份！） |
| 手动引导（主路径，p4 FIT） | 串口进入 U-Boot | `setenv bootargs 'earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8'` → `load mmc 0:4 0x46000000` → `bootm 0x46000000`（bootm 按 FIT 内 load=0x40000000 解压） |
| 手动引导（兜底，p5 /boot） | 串口进入 U-Boot | `load mmc 0:5 0x47000000 /boot/boot.scr` → `source 0x47000000` |
| 刷入 eMMC 后无法启动 | 分区表 / FIT / rootfs | `sgdisk -p /dev/mmcblk0` 确认 p4 PARTLABEL=`kernel`、p5 PARTLABEL=`rootfs`；p4 为 FIT（bootm 加载）、p5 为引导层 ext4（`debugfs -R 'stat /sbin/init' /dev/mmcblk0p5` 应存在，内含 `/squashfs/rootfs.squashfs` 与 `/overlay/`）；`Image`/DTB 与当前内核匹配 |
| 想恢复 ImmortalWrt | 备份文件 | `dd if=emmc-backup.img of=/dev/mmcblk0 bs=4M conv=fsync` |

## 4. SquashFS / OverlayFS / 只读根

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| 启动进入"只读救援模式"提示 | 串口日志 `/sbin/init` 的 overlay 组装失败原因；`findmnt /`（救援模式根为 squashfs + tmpfs） | SSH/串口登录后检查 p5：`e2fsck -fn /dev/mmcblk0p5`；`/overlay/upper`/`work` 是否损坏或占满；修复后 `reboot`（引导层 init 每次启动都会重试组装） |
| 根分区只读、写入报 Read-only | `findmnt /` 看 upperdir；`mount \| grep overlay` | upper/work 未挂上（引导层 p5 只读挂载？）：检查 `dmesg \| grep -i "EXT4-fs error"`，必要时 e2fsck 修复 |
| `/overlay` 空间不足 | `df -h /`（overlay 容量 = p5 剩余）；`du -xsh /var/* \| sort -h` | 清理日志/缓存；确认 `h5000m-grow-rootfs.service` 已跑过（`systemctl status h5000m-grow-rootfs`；marker `/var/lib/h5000m-rootfs-grown`） |
| 重启后配置丢失 | overlay upper 是否持久：`ls /overlay/upper/etc/`（经 `/tmpold` 视角） | 正常情况下 `/etc` `/var` 写入自动落 upper；若为空说明 overlay 未组装成功（见救援模式行） |
| 在线升级失败（--rootfs-squashfs） | 脚本输出；`/tmpold/squashfs/` 是否可见；`ls -la /tmpold/squashfs/rootfs.squashfs*` | 仅当系统本身是 SquashFS+OverlayFS 架构才可用（脚本会探测）；空间不足会提前报 df 检查；失败时旧版未动，`.bak` 存在则 `mv` 回退 |
| 在线升级后想回退旧版本 | `ls /tmpold/squashfs/rootfs.squashfs.bak` | 挂载 p5：`mount /dev/mmcblk0p5 /mnt` → `mv /mnt/squashfs/rootfs.squashfs.bak /mnt/squashfs/rootfs.squashfs` → `umount /mnt` → `reboot` |
| squashfs 镜像损坏疑虑 | `dd if=rootfs.squashfs bs=1 count=4` 应为 `hsqs` | 重新从 Release 下载并核对 sha256sums.txt 后重刷 |

## 5. WAN

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| WAN 无 IP | `nmcli device status`；`journalctl -u NetworkManager` | 确认插在**靠近电源**的 2.5G 口（eth1） |
| WAN 获取到但无默认路由 | `ip route` | 正常应为 `default via <网关> dev eth1`；IPv6 失败不影响 IPv4 |
| WAN 反复 up/down | PHY 固件缺失 | 确认 `/usr/lib/firmware/mediatek/mt7987/i2p5ge-phy-*.bin` 存在 |

## 6. LAN / DHCP / DNS

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| LAN 无 192.168.88.1 | `ip -br addr show br-lan` | `systemctl restart linux-router-netbringup` |
| 客户端无 IP | `systemctl status dnsmasq`；`journalctl -u dnsmasq` | 确认仅一个 dnsmasq 实例（`pgrep -a dnsmasq`） |
| DNS 不通 | `dig @192.168.88.1 example.com` | dnsmasq 上游：WAN DNS 或 8.8.8.8 兜底；检查 53 端口占用（`ss -lunp \| grep :53`），确保 systemd-resolved 已禁用 |
| LAN 无法上网 | `nft list ruleset` | 确认 masquerade 规则存在；`sysctl net.ipv4.ip_forward` = 1 |

## 7. Wi-Fi

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| 无 wlan 接口 | `lspci`；`dmesg \| grep -i mt7992` | PCIe 复位 GPIO36；固件是否加载（`dmesg` 看 firmware 路径） |
| 固件加载失败 | `ls /usr/lib/firmware/mediatek/mt7996/` | 重跑 `scripts/fetch-firmware.py` 并重建 rootfs |
| AP 起不来 | `systemctl status hostapd*`；`journalctl -u hostapd*` | 检查 hostapd 配置（信道/带宽/国家码）；`iw reg get` |
| 客户端连不上 | `iw dev <iface> station dump` | 检查 WPA2/WPA3 配置与密码；确认射频未锁定（`rfkill list`） |
| 无线带外（5G DFS） | 国家码/信道 | 通过 WebUI 选择合法信道；配置已默认使用无 DFS 信道 |

## 8. WebUI / Linux-Router

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| 无法打开 192.168.88.1 | `systemctl status router-panel router-panel-agent` | agent 是 web 的强依赖；两者均 `Restart=on-failure` |
| 修改配置不生效 | agent 日志 | `journalctl -u router-panel-agent -f`；确认 nmcli/dnsmasq 调用返回成功 |
| 密码遗忘 | 重置 | 参考 Linux-Router `install.sh uninstall --purge-data` 后重装；或按 DEPLOYMENT.md 重置 |

## 9. 服务职责冲突检查（防止双管理）

```bash
systemctl list-units --all | grep -Ei 'network|dnsmasq|hostapd|resolved|dhcpcd|networkd|firewalld|ufw'
```

期望结果：

- `NetworkManager.service`：enabled（唯一网口管理）
- `systemd-networkd` / `dhcpcd` / `systemd-resolved`：**不存在或 disabled**
- `firewalld` / `ufw`：**不安装**
- `dnsmasq`：仅一个实例；`:53` 仅 dnsmasq 监听

## 10. eMMC 固化（谨慎操作）

```bash
# 先全盘备份 eMMC
dd if=/dev/mmcblk0 of=/path/to/backup/mmcblk0.img bs=4M conv=sync status=progress

# 全新刷写：仅写 p4（FIT）+ p5（引导层 ext4），其余区域（GPT / p1-p3 / U-Boot / eMMC 硬件配置）不动
sudo bash scripts/install-emmc.sh \
  --kernel-fit out/H5000M-debian13-kernel.bin \
  --rootfs-img out/H5000M-debian13-rootfs.bin \
  --dev /dev/mmcblk0 [--backup-full /tmp/emmc-full.img] [--yes]

# 在线升级（系统运行中执行，仅原子替换 p5 上的 SquashFS + 刷新 p4 FIT，配置/数据保留）
sudo bash scripts/install-emmc.sh \
  --kernel-fit out/H5000M-debian13-kernel.bin \
  --rootfs-squashfs out/rootfs/rootfs.squashfs \
  --dev /dev/mmcblk0 [--yes]
```

恢复 ImmortalWrt：`dd if=backup.img of=/dev/mmcblk0 bs=4M conv=fsync`。

## 11. 重启恢复

所有写入经 OverlayFS 落 p5 引导层 upper（持久化），网络配置另由 Linux-Router 持久化
（`/var/lib/linux-router`）+ NetworkManager connection 持久化；服务均设置
`Restart=on-failure`。若重启后配置丢失，检查：

- overlay 是否正常组装：`findmnt /` 应显示 overlay（否则见 §4 只读救援模式）
- `/var/lib/linux-router/network.json` 是否存在
- NetworkManager `nmcli connection show` 中 `DebianRouterHotspot` 与 WAN/LAN 连接是否 autoconnect

## 12. 云编译（GitHub Actions）

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| Actions 页面没有可触发的运行 | workflow 仅 `workflow_dispatch` | 手动 Run workflow，或 `gh workflow run build.yml`（推送不会自动编译） |
| ARM64 runner 一直排队 / 拉不起来 | job 长时间 queued | 勾选 `force_x86_runner` 重跑（回退 x86_64：交叉编译 + qemu 第二阶段，耗时回到 2 小时量级） |
| RootFS 步骤日志 `构建模式：foreign` | 期望 native 却走了 qemu 路径 | job 实际跑在 x86 runner 上（`uname -m` 非 arm64）；确认未勾选回退且 runner 标签为 `ubuntu-24.04-arm` |
| `Unknown suite trixie` / debootstrap 报套件不存在 | runner 镜像自带 debootstrap 过旧 | workflow 内置预检会自动装 Debian 上游 debootstrap；若仍失败检查能否访问 `deb.debian.org` |
| 内核编译耗时没有下降 | 日志末尾 `ccache 统计` | 看 Hits/Cacheable 比例：首次必然 miss；若二次仍为 0 命中，检查 cache key（补丁/dts/配置/脚本任一改动都会换 key） |
| `.deb` 下载仍然很慢 | 日志是否有「预置 N 个缓存 .deb」 | 无则说明 apt 缓存未命中（`packages.list` 变更会换 key）；属首次或清单变更后的正常行为 |
| artifact 上传报 EACCES | 产物属主 | workflow 已有 chown 步骤；本地复现时 `sudo chown -R $(id -u):$(id -g) out` |
