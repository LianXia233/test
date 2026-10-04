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
| 手动引导（主路径，p4 FIT） | 串口进入 U-Boot | `setenv bootargs 'root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8'` → `load mmc 0:4 0x46000000` → `bootm 0x46000000` |
| 手动引导（兜底，p5 /boot） | 串口进入 U-Boot | `load mmc 0:5 0x47000000 /boot/boot.scr` → `source 0x47000000` |
| 刷入 eMMC 后无法启动 | 分区表 / FIT / rootfs | `sgdisk -p /dev/mmcblk0` 确认 p4 PARTLABEL=`kernel`、p5 PARTLABEL=`rootfs`；p4 为 FIT（bootm 加载）、p5 为 ext4（PARTLABEL=rootfs 挂载）；`Image`/DTB 与当前内核匹配 |
| 想恢复 ImmortalWrt | 备份文件 | `dd if=emmc-backup.img of=/dev/mmcblk0 bs=4M conv=fsync` |

## 4. WAN

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| WAN 无 IP | `nmcli device status`；`journalctl -u NetworkManager` | 确认插在**靠近电源**的 2.5G 口（eth1） |
| WAN 获取到但无默认路由 | `ip route` | 正常应为 `default via <网关> dev eth1`；IPv6 失败不影响 IPv4 |
| WAN 反复 up/down | PHY 固件缺失 | 确认 `/usr/lib/firmware/mediatek/mt7987/i2p5ge-phy-*.bin` 存在 |

## 5. LAN / DHCP / DNS

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| LAN 无 192.168.88.1 | `ip -br addr show br-lan` | `systemctl restart linux-router-netbringup` |
| 客户端无 IP | `systemctl status dnsmasq`；`journalctl -u dnsmasq` | 确认仅一个 dnsmasq 实例（`pgrep -a dnsmasq`） |
| DNS 不通 | `dig @192.168.88.1 example.com` | dnsmasq 上游：WAN DNS 或 8.8.8.8 兜底；检查 53 端口占用（`ss -lunp \| grep :53`），确保 systemd-resolved 已禁用 |
| LAN 无法上网 | `nft list ruleset` | 确认 masquerade 规则存在；`sysctl net.ipv4.ip_forward` = 1 |

## 6. Wi-Fi

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| 无 wlan 接口 | `lspci`；`dmesg \| grep -i mt7992` | PCIe 复位 GPIO36；固件是否加载（`dmesg` 看 firmware 路径） |
| 固件加载失败 | `ls /usr/lib/firmware/mediatek/mt7996/` | 重跑 `scripts/fetch-firmware.py` 并重建 rootfs |
| AP 起不来 | `systemctl status hostapd*`；`journalctl -u hostapd*` | 检查 hostapd 配置（信道/带宽/国家码）；`iw reg get` |
| 客户端连不上 | `iw dev <iface> station dump` | 检查 WPA2/WPA3 配置与密码；确认射频未锁定（`rfkill list`） |
| 无线带外（5G DFS） | 国家码/信道 | 通过 WebUI 选择合法信道；配置已默认使用无 DFS 信道 |

## 7. WebUI / Linux-Router

| 症状 | 检查 | 处理 |
| --- | --- | --- |
| 无法打开 192.168.88.1 | `systemctl status router-panel router-panel-agent` | agent 是 web 的强依赖；两者均 `Restart=on-failure` |
| 修改配置不生效 | agent 日志 | `journalctl -u router-panel-agent -f`；确认 nmcli/dnsmasq 调用返回成功 |
| 密码遗忘 | 重置 | 参考 Linux-Router `install.sh uninstall --purge-data` 后重装；或按 DEPLOYMENT.md 重置 |

## 8. 服务职责冲突检查（防止双管理）

```bash
systemctl list-units --all | grep -Ei 'network|dnsmasq|hostapd|resolved|dhcpcd|networkd|firewalld|ufw'
```

期望结果：

- `NetworkManager.service`：enabled（唯一网口管理）
- `systemd-networkd` / `dhcpcd` / `systemd-resolved`：**不存在或 disabled**
- `firewalld` / `ufw`：**不安装**
- `dnsmasq`：仅一个实例；`:53` 仅 dnsmasq 监听

## 9. eMMC 固化（谨慎操作）

```bash
# 先全盘备份 eMMC
dd if=/dev/mmcblk0 of=/path/to/backup/mmcblk0.img bs=4M conv=sync status=progress

# 仅写 p4（FIT）+ p5（ext4），其余区域（GPT / p1-p3 / U-Boot / eMMC 硬件配置）不动
sudo bash scripts/install-emmc.sh \
  --kernel-fit out/h5000m-kernel.fit \
  --rootfs-img out/h5000m-rootfs.ext4.img \
  --dev /dev/mmcblk0 [--backup-full /tmp/emmc-full.img] [--yes]
```

恢复 ImmortalWrt：`dd if=backup.img of=/dev/mmcblk0 bs=4M conv=fsync`。

## 10. 重启恢复

所有网络配置由 Linux-Router 持久化（`/var/lib/linux-router`）+ NetworkManager connection
持久化；服务均设置 `Restart=on-failure`。若重启后配置丢失，检查：

- `/var/lib/linux-router/network.json` 是否存在
- NetworkManager `nmcli connection show` 中 `DebianRouterHotspot` 与 WAN/LAN 连接是否 autoconnect
