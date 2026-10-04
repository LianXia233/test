#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — 首次启动路由器初始化（幂等，可重复执行）
#
# 职责（唯一网络编排入口，由 h5000m-router-init.service 在开机时执行）：
#   1. 等待物理接口出现
#   2. 创建 NetworkManager 连接：WAN(eth1, DHCP) / LAN(eth0) / br-lan / Wi-Fi AP(2G/5G)
#   3. 设置 regulatory domain 与 rfkill
#   4. 准备 dnsmasq 上游 DNS 文件并启动 dnsmasq / nftables
#
# 故障隔离：每一步失败仅记录日志并继续，绝不阻塞后续步骤。
# 例如：WAN 无网络不影响 LAN/DHCP；Wi-Fi 失败不影响有线；WebUI 独立于本脚本运行。

set -u

log() { printf '[h5000m-router-init] %s\n' "$*"; }
warn() { printf '[h5000m-router-init] WARN: %s\n' "$*" >&2; }

# ---- 读取默认配置（不硬编码路径）----
CONF="/etc/default/h5000m-router"
if [[ -r "$CONF" ]]; then
  # shellcheck disable=SC1090
  . "$CONF"
else
  warn "缺少 $CONF，使用默认值"
  WAN_IFACE=eth1
  LAN_IFACE=eth0
  LAN_BRIDGE=br-lan
  LAN_ADDRESS=192.168.88.1/24
  DHCP_RANGE=192.168.88.100,192.168.88.200,255.255.255.0,12h
  AP_2G_IFACE=wlan0
  AP_5G_IFACE=wlan1
  AP_SSID_2G=OWRT
  AP_SSID_5G=OWRT
  AP_PASSWORD=12345678
  REGULATORY_DOMAIN=CN
  FALLBACK_DNS="1.1.1.1 8.8.8.8 223.5.5.5"
fi

# 从 LAN_ADDRESS 提取网关 IP 与掩码（供 dnsmasq 网段使用）
LAN_IP="${LAN_ADDRESS%/*}"
LAN_PREFIX="${LAN_ADDRESS#*/}"
LAN_SUBNET_CIDR="${LAN_ADDRESS%/*}/${LAN_PREFIX}"

command -v nmcli >/dev/null 2>&1 || { warn "缺少 nmcli，无法创建网络连接"; exit 0; }

# ---- 1. 等待接口出现（最长 30s，MT7992 通过 PCIe 探测可能较慢）----
wait_iface() {
  local name="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    [[ -e "/sys/class/net/$name" ]] && return 0
    sleep 1
  done
  return 1
}

# ---- 2. 创建 NM 连接（幂等：已存在则跳过）----
nm_conn_exists() { nmcli -t -f NAME connection show | grep -qx "$1"; }

# WAN：eth1，DHCP 自动获取 IPv4/IPv6 与默认路由
if ! nm_conn_exists "WAN"; then
  if wait_iface "$WAN_IFACE"; then
    nmcli connection add type ethernet con-name "WAN" ifname "$WAN_IFACE" \
      ipv4.method auto ipv6.method auto connection.autoconnect yes \
      connection.autoconnect-priority 100 || warn "创建 WAN 连接失败"
  else
    warn "接口 $WAN_IFACE 未出现，跳过 WAN 连接（LAN 不受影响）"
  fi
fi

# br-lan：LAN 网桥，静态 192.168.88.1/24 + IPv6 ULA（dnsmasq RA 通告）
if ! nm_conn_exists "$LAN_BRIDGE"; then
  nmcli connection add type bridge con-name "$LAN_BRIDGE" ifname "$LAN_BRIDGE" \
    ipv4.method manual ipv4.addresses "$LAN_ADDRESS" \
    ipv4.gateway "" ipv4.dns "" ipv4.never-default yes \
    ipv6.method manual ipv6.addresses "${LAN_ULA:-fd88:88::1/64}" ipv6.never-default yes \
    bridge.stp no bridge.forward-delay 0 \
    connection.autoconnect yes connection.autoconnect-priority 100 \
    || warn "创建 $LAN_BRIDGE 网桥连接失败"
fi

# LAN 以太网口：作为 br-lan 从属口
if ! nm_conn_exists "LAN"; then
  if wait_iface "$LAN_IFACE"; then
    nmcli connection add type ethernet con-name "LAN" ifname "$LAN_IFACE" \
      master "$LAN_BRIDGE" slave-type bridge ipv4.method disabled ipv6.method disabled \
      connection.autoconnect yes || warn "创建 LAN 从属连接失败"
  else
    warn "接口 $LAN_IFACE 未出现，跳过 LAN 从属连接"
  fi
fi

# Wi-Fi AP（MT7992，双 PHY）：桥接到 br-lan，与有线 LAN 同一二层网络
add_ap() {
  local con="$1" iface="$2" ssid="$3" band="$4"
  if ! nm_conn_exists "$con"; then
    if wait_iface "$iface" 45; then
      nmcli connection add type wifi con-name "$con" ifname "$iface" ssid "$ssid" \
        master "$LAN_BRIDGE" slave-type bridge \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$AP_PASSWORD" \
        802-11-wireless.mode ap 802-11-wireless.band "$band" \
        802-11-wireless.channel 0 802-11-wireless.powersave 2 \
        ipv4.method disabled ipv6.method disabled \
        connection.autoconnect yes connection.autoconnect-priority 90 \
        || warn "创建 Wi-Fi AP 连接 $con 失败"
    else
      warn "接口 $iface 未出现，跳过 AP $con（不影响有线 LAN）"
    fi
  fi
}
add_ap "H5000M-AP-2G" "$AP_2G_IFACE" "$AP_SSID_2G" "bg"
add_ap "H5000M-AP-5G" "$AP_5G_IFACE" "$AP_SSID_5G" "a"

# ---- 3. regulatory / rfkill ----
if command -v iw >/dev/null 2>&1; then
  iw reg set "$REGULATORY_DOMAIN" 2>/dev/null || warn "iw reg set $REGULATORY_DOMAIN 失败"
fi
if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock wifi 2>/dev/null || warn "rfkill unblock wifi 失败"
fi

# ---- 4. 应用连接并启动 br-lan（先 bridge 后 AP，逐个尝试）----
nmcli general reload 2>/dev/null
nmcli connection up "$LAN_BRIDGE" >/dev/null 2>&1 || warn "启动 $LAN_BRIDGE 失败"
nmcli connection up "WAN" >/dev/null 2>&1 || warn "启动 WAN 失败（LAN 不受影响）"
for con in "H5000M-AP-2G" "H5000M-AP-5G"; do
  nmcli connection up "$con" >/dev/null 2>&1 || warn "启动 $con 失败（不影响有线 LAN）"
done

# ---- 5. dnsmasq 上游 DNS 文件（兜底），并确保 DHCP/DNS/防火墙运行 ----
mkdir -p /run/h5000m
{
  for ns in $FALLBACK_DNS; do printf 'nameserver %s\n' "$ns"; done
} > /run/h5000m/upstream-resolv.conf

systemctl restart dnsmasq >/dev/null 2>&1 || warn "dnsmasq 重启失败"
systemctl restart nftables >/dev/null 2>&1 || warn "nftables 重启失败"

# ---- 6. 校验并汇总 ----
log "接口状态："
ip -br link show 2>/dev/null | sed 's/^/  /'
log "br-lan 地址：$(ip -4 -br addr show "$LAN_BRIDGE" 2>/dev/null | awk '{print $3}')"
log "完成。LAN 管理地址 http://${LAN_IP%%/*}  WebUI 已由 router-panel 提供。"
exit 0
