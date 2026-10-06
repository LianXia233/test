#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Hiveton H5000M — 首次启动路由器初始化（幂等，可重复执行）
#
# 职责（首启基础网络编排，由 h5000m-router-init.service 在开机时执行）：
#   1. 等待物理接口出现
#   2. 创建 NetworkManager 连接：WAN(eth1)/5G-WAN(eth2) / LAN(eth0) / br-lan / Wi-Fi AP
#   3. 设置 regulatory domain 与 rfkill
#   4. 准备 dnsmasq 上游 DNS 文件并装载 nftables（dnsmasq 由 systemd 在本服务完成后启动）
#
# 故障隔离：非关键步骤失败仅记录日志并继续，绝不阻塞后续步骤。
# 例如：WAN 无网络不影响 LAN/DHCP；Wi-Fi 失败不影响有线；WebUI 独立于本脚本运行。
#
# 【致命 vs 非致命】此前无论发生什么都以 exit 0 收尾，systemd 的 oneshot
# 永远判定成功：br-lan 没起来、nmcli 缺失这类"整台设备不可管理"的失败在
# systemctl status 里完全看不出来，也不会触发重启重试。现在分成两类：
#   fatal —— LAN/管理面不可用（nmcli 缺失、br-lan 创建或激活失败）
#   warn  —— 其余（WAN、AP、regulatory、nftables）
# 退出码反映是否有 fatal，并把结果落到 /run/h5000m/init-status.json 供
# 面板与现场排查读取。

set -u

WARNINGS=()
FATAL=""

# 统一日志出口：优先写 journald（带 syslog 级别，便于 journalctl -p warning
# 过滤与后续审计），logger 不可用时回退到 stderr —— systemd 同样会收进 journal。
_init_log() {
	local level="$1"
	shift
	if command -v logger >/dev/null 2>&1; then
		logger -p "daemon.$level" -t h5000m-router-init "$*"
	else
		printf '[h5000m-router-init] %s: %s\n' "$level" "$*" >&2
	fi
}

log() { _init_log info "$@"; }
warn() {
	_init_log warning "$@"
	WARNINGS+=("$*")
}
fatal() {
	_init_log crit "$@"
	FATAL="$*"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

# 写出本次初始化的结构化结果；返回值为进程退出码（有 fatal 则非 0）
write_status() {
  local ok="true" code=0 index total
  if [[ -n "$FATAL" ]]; then
    ok="false"
    code=1
  fi

  mkdir -p /run/h5000m
  {
    printf '{\n'
    printf '  "ok": %s,\n' "$ok"
    printf '  "finished_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
    if [[ -n "$FATAL" ]]; then
      printf '  "fatal": "%s",\n' "$(json_escape "$FATAL")"
    else
      printf '  "fatal": null,\n'
    fi
    printf '  "warnings": [\n'
    total=${#WARNINGS[@]}
    for ((index = 0; index < total; index++)); do
      if ((index + 1 < total)); then
        printf '    "%s",\n' "$(json_escape "${WARNINGS[index]}")"
      else
        printf '    "%s"\n' "$(json_escape "${WARNINGS[index]}")"
      fi
    done
    printf '  ]\n'
    printf '}\n'
  } > /run/h5000m/init-status.json.tmp
  mv -f /run/h5000m/init-status.json.tmp /run/h5000m/init-status.json
  chmod 0644 /run/h5000m/init-status.json
  return "$code"
}

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

# ---- 板级 MAC：由 eMMC CID 派生并持久化 ----
# 同一个固件刷到多台设备时，DTB 里写死的 mac-address 会让所有机器用同一组
# MAC（见 dts/mt7987a-hiveton-h5000m.dts 的注释）。这里按每块板子的 eMMC
# CID 派生一个稳定地址，并落到 /etc/h5000m-mac.conf：CID 不可读（换 eMMC、
# 走 SD/USB 启动）时也能复用首次算出的结果，不会每次开机漂移。
MAC_STATE="/etc/h5000m-mac.conf"

mac_increment() {
  local mac="$1" last next
  last="${mac##*:}"
  next=$(( (0x${last} + 1) & 0xff ))
  printf '%s:%02x' "${mac%:*}" "$next"
}

# 生成 LAN 基地址：02:xx:xx:xx:00:00（本地管理位=1、单播位=0）
derive_base_mac() {
  local cid="" digest=""
  local cid_path
  for cid_path in /sys/block/mmcblk0/device/cid /sys/block/mmcblk1/device/cid; do
    if [[ -r "$cid_path" ]]; then
      cid="$(tr -d ' \t\r\n' < "$cid_path" 2>/dev/null || true)"
      [[ -n "$cid" ]] && break
    fi
  done
  [[ -n "$cid" ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  digest="$(printf '%s' "$cid" | sha256sum | cut -c1-6)"
  [[ "${#digest}" -eq 6 ]] || return 1
  printf '02:%s:%s:%s:00:00' "${digest:0:2}" "${digest:2:2}" "${digest:4:2}"
}

load_board_macs() {
  if [[ -r "$MAC_STATE" ]]; then
    # shellcheck disable=SC1090
    . "$MAC_STATE"
  fi
  if [[ -z "${LAN_MAC:-}" || -z "${WAN_MAC:-}" ]]; then
    local base=""
    if base="$(derive_base_mac)"; then
      LAN_MAC="$base"
      WAN_MAC="$(mac_increment "$base")"
      {
        printf '# 由 h5000m-router-init.sh 生成：基于板载 eMMC CID 派生的板级 MAC\n'
        printf '# 删除本文件会在下次启动时按 CID 重新派生（结果通常一致）\n'
        printf 'LAN_MAC=%s\n' "$LAN_MAC"
        printf 'WAN_MAC=%s\n' "$WAN_MAC"
      } > "$MAC_STATE"
      chmod 0644 "$MAC_STATE"
      log "已按 eMMC CID 派生板级 MAC：LAN=$LAN_MAC WAN=$WAN_MAC"
    else
      warn "无法读取 eMMC CID 派生 MAC，沿用内核分配的接口地址"
      LAN_MAC=""
      WAN_MAC=""
    fi
  fi
}
load_board_macs

# ---- AP 出厂弱口令处置 ----
# AP_PASSWORD 的出厂值 12345678 是仓库里公开的常量。这里不动出厂默认本身
# （刷机后的可预测性要保留），但做两件事：
#   1) 把 /etc/default/h5000m-router 收成 0600，避免任何本地用户读到明文口令；
#   2) 若 H5000M_AP_RANDOMIZE=1，首启自动换成随机口令并写回该文件。
# 仍是出厂值时在日志里显著告警，提示必须修改。
AP_PASSWORD_FILE="/etc/default/h5000m-router"
FACTORY_AP_PASSWORD="12345678"

harden_ap_password() {
  [ -f "$AP_PASSWORD_FILE" ] || return 0
  chmod 0600 "$AP_PASSWORD_FILE" 2>/dev/null || warn "无法收紧 $AP_PASSWORD_FILE 权限"

  if [ "${H5000M_AP_RANDOMIZE:-0}" = "1" ] && [ "${AP_PASSWORD:-}" = "$FACTORY_AP_PASSWORD" ]; then
    local generated=""
    if command -v openssl >/dev/null 2>&1; then
      generated="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)"
    elif [ -r /dev/urandom ]; then
      generated="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)"
    fi
    if [ "${#generated}" -ge 12 ]; then
      AP_PASSWORD="$generated"
      # 去掉旧的 AP_PASSWORD 行再追加新值，保持文件里其它配置不变
      local tmp="${AP_PASSWORD_FILE}.tmp"
      grep -v '^AP_PASSWORD=' "$AP_PASSWORD_FILE" > "$tmp" 2>/dev/null || cp "$AP_PASSWORD_FILE" "$tmp"
      printf 'AP_PASSWORD=%s\n' "$AP_PASSWORD" >> "$tmp"
      mv -f "$tmp" "$AP_PASSWORD_FILE"
      chmod 0600 "$AP_PASSWORD_FILE"
      log "已按 H5000M_AP_RANDOMIZE 生成随机 AP 口令（SSID=${AP_SSID_2G:-OWRT}）"
    else
      warn "随机 AP 口令生成失败，沿用出厂口令"
    fi
  fi

  if [ "${AP_PASSWORD:-}" = "$FACTORY_AP_PASSWORD" ]; then
    warn "AP 口令仍为出厂弱口令 $FACTORY_AP_PASSWORD（公开已知值），请立即修改 $AP_PASSWORD_FILE"
  fi
}
harden_ap_password

if ! command -v nmcli >/dev/null 2>&1; then
  fatal "缺少 nmcli，无法创建网络连接（LAN 管理地址不可用）"
  write_status
  exit $?
fi

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

# 把派生出的板级 MAC 交给 NetworkManager：NM 在每次激活连接时应用
# cloned-mac-address，比在脚本里 ip link set 更可靠（接口被 PCIe 重枚举、
# 热插拔或重启后都能保持一致）。CID 派生失败时数组为空，NM 保持内核默认值。
WAN_MAC_ARGS=()
if [[ -n "${WAN_MAC:-}" ]]; then
  WAN_MAC_ARGS=(ethernet.cloned-mac-address "$WAN_MAC")
fi
LAN_MAC_ARGS=()
if [[ -n "${LAN_MAC:-}" ]]; then
  LAN_MAC_ARGS=(ethernet.cloned-mac-address "$LAN_MAC")
fi

# WAN：eth1，优先有线 DHCP；实机当前由 MT5700M 提供 eth2 DHCP 上联，作备用出口
if ! nm_conn_exists "WAN"; then
  if wait_iface "$WAN_IFACE"; then
    nmcli connection add type ethernet con-name "WAN" ifname "$WAN_IFACE" \
      ipv4.method auto ipv4.route-metric 100 ipv6.method auto ipv6.route-metric 100 connection.autoconnect yes \
      connection.autoconnect-priority 100 "${WAN_MAC_ARGS[@]+"${WAN_MAC_ARGS[@]}"}" \
      || warn "创建 WAN 连接失败"
  else
    warn "接口 $WAN_IFACE 未出现，跳过 WAN 连接（LAN 不受影响）"
  fi
fi

# 实机 OpenWrt 当前 MT5700M uplink 为 eth2（DHCP）。NetworkManager 可先保存
# 绑定 eth2 的 profile；USB 网卡稍后枚举出来时会自动连接，不在启动时抢时间窗口。
if ! nm_conn_exists "WAN-5G"; then
  nmcli connection add type ethernet con-name "WAN-5G" ifname "eth2" \
    ipv4.method auto ipv4.route-metric 200 ipv6.method auto ipv6.route-metric 200 \
    connection.autoconnect yes connection.autoconnect-priority 90 \
    || warn "创建 WAN-5G 连接失败（有线 WAN/LAN 不受影响）"
fi

# br-lan：LAN 网桥，静态 192.168.88.1/24 + IPv6 ULA（dnsmasq RA 通告）
# 这是致命路径：网桥建不起来 → LAN 无管理地址 → WebUI/SSH 都不可达。
BRIDGE_CREATED=1
if ! nm_conn_exists "$LAN_BRIDGE"; then
  if nmcli connection add type bridge con-name "$LAN_BRIDGE" ifname "$LAN_BRIDGE" \
    ipv4.method manual ipv4.addresses "$LAN_ADDRESS" \
    ipv4.gateway "" ipv4.dns "" ipv4.never-default yes \
    ipv6.method manual ipv6.addresses "${LAN_ULA:-fd88:88::1/64}" ipv6.never-default yes \
    bridge.stp no bridge.forward-delay 0 \
    connection.autoconnect yes connection.autoconnect-priority 100; then
    BRIDGE_CREATED=1
  else
    BRIDGE_CREATED=0
    fatal "创建 $LAN_BRIDGE 网桥连接失败"
  fi
fi

# LAN 以太网口：作为 br-lan 从属口
if ! nm_conn_exists "LAN"; then
  if wait_iface "$LAN_IFACE"; then
    nmcli connection add type ethernet con-name "LAN" ifname "$LAN_IFACE" \
      master "$LAN_BRIDGE" slave-type bridge ipv4.method disabled ipv6.method disabled \
      connection.autoconnect yes "${LAN_MAC_ARGS[@]+"${LAN_MAC_ARGS[@]}"}" \
      || warn "创建 LAN 从属连接失败"
  else
    warn "接口 $LAN_IFACE 未出现，跳过 LAN 从属连接"
  fi
fi

# Wi-Fi AP（MT7992，双 PHY）：桥接到 br-lan，与有线 LAN 同一二层网络
add_ap() {
  local con="$1" iface="$2" ssid="$3" band="$4"
  if ! nm_conn_exists "$con"; then
    # 先保存绑定接口名的 profile；Wi-Fi 驱动/接口晚到时由 NM 自动激活，
    # 不在可选无线设备探测期间阻塞有线 LAN、DHCP 或面板启动。
    nmcli connection add type wifi con-name "$con" ifname "$iface" ssid "$ssid" \
      master "$LAN_BRIDGE" slave-type bridge \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$AP_PASSWORD" \
      802-11-wireless.mode ap 802-11-wireless.band "$band" \
      802-11-wireless.channel 0 802-11-wireless.powersave 2 \
      ipv4.method disabled ipv6.method disabled \
      connection.autoconnect yes connection.autoconnect-priority 90 \
      || warn "创建 Wi-Fi AP 连接 $con 失败"
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
if ((BRIDGE_CREATED)); then
  nmcli --wait 10 connection up "$LAN_BRIDGE" >/dev/null 2>&1 \
    || fatal "启动 $LAN_BRIDGE 失败（LAN 管理地址不可用）"
fi
nmcli --wait 10 connection up "WAN" >/dev/null 2>&1 || warn "启动 WAN 失败（LAN 不受影响）"
# WAN-5G 与 AP 均设为 autoconnect：接口可以晚于本 oneshot 服务出现。
for con in "H5000M-AP-2G" "H5000M-AP-5G"; do
  nmcli connection modify "$con" connection.autoconnect yes >/dev/null 2>&1 || warn "启用 $con 自动连接失败"
  nmcli --wait 10 connection up "$con" >/dev/null 2>&1 || log "$con 当前不可用（有线 LAN 不受影响）"
done

# ---- 5. 写 dnsmasq 上游 DNS 兜底文件，并装载防火墙 ----
mkdir -p /run/h5000m
{
  for ns in $FALLBACK_DNS; do printf 'nameserver %s\n' "$ns"; done
} > /run/h5000m/upstream-resolv.conf

# dnsmasq.service 通过 After/Requires 排在本 oneshot 之后，由 systemd 在
# 本服务结束后启动。这里不能同步 restart，否则会等待本服务自身完成。
systemctl restart nftables >/dev/null 2>&1 || warn "nftables 重启失败"

# ---- 6. 校验并汇总 ----
log "接口状态："
ip -br link show 2>/dev/null | sed 's/^/  /'
log "br-lan 地址：$(ip -4 -br addr show "$LAN_BRIDGE" 2>/dev/null | awk '{print $3}')"
log "完成。LAN 管理地址 http://${LAN_IP%%/*}  WebUI 已由 router-panel 提供。"

# 汇总结构化结果并以真实退出码收尾：致命失败时 systemd 会据此把本 oneshot
# 判为 failed，并按 Restart=on-failure 重试（见 h5000m-router-init.service）。
write_status
