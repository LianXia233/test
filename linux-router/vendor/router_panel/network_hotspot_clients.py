"""热点客户端与 DHCP 租约的采集。

已连接设备的名单来自三个地方：iw station dump（MAC 与信号）、dnsmasq 租约
（主机名与 IP）、ip neighbor（ARP 表里的 IP 兜底）。三者合并后才形成页面上
的客户端列表。这一块与无线扫描、热点开关没有共享状态，独立成模块后
network.py 不必再同时承担四类职责。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .contracts import HotspotClientsStatus
from .core import (
    HOTSPOT_BRIDGE_INTERFACE,
    HOTSPOT_BRIDGED_AP_PROFILES,
    HOTSPOT_CONNECTION_NAME,
    HOTSPOT_DEFAULT_SSID,
    HOTSPOT_DHCP_LEASE_FILE,
    normalize_mac_address,
    run_command,
)
from .network_connections import (
    get_active_connections,
    get_hotspot_connection_master,
    get_hotspot_connection_profile,
)
from .network_parsers import format_wifi_band, parse_iw_station_dump, parse_nmcli_lines

def get_current_wifi_link(ifname: str) -> dict[str, str]:
    wifi_list = run_command(
        [
            "nmcli",
            "-t",
            "-f",
            "IN-USE,SSID,BSSID,CHAN,FREQ,RATE",
            "device",
            "wifi",
            "list",
            "--rescan",
            "no",
            "ifname",
            ifname,
        ]
    )
    if not wifi_list.ok or not wifi_list.output:
        return {}

    for item in parse_nmcli_lines(
        wifi_list.output,
        ["in_use", "ssid", "bssid", "channel", "frequency", "rate"],
    ):
        if item.get("in_use", "").strip() != "*":
            continue
        frequency = item.get("frequency", "").strip()
        return {
            "ssid": item.get("ssid", "").strip() or "隐藏网络",
            "bssid": item.get("bssid", "").strip() or "未知",
            "channel": item.get("channel", "").strip() or "未知",
            "frequency": frequency or "未知",
            "band": format_wifi_band(frequency),
            "rate": item.get("rate", "").strip() or "未知",
        }

    return {}


def get_interface_ipv4_neighbors(ifname: str) -> dict[str, str]:
    result = run_command(["ip", "-4", "neighbor", "show", "dev", ifname], timeout=5)
    if not result.ok or not result.output:
        return {}

    addresses: dict[str, str] = {}
    for line in result.output.splitlines():
        parts = line.split()
        if not parts or "lladdr" not in parts:
            continue
        mac_index = parts.index("lladdr") + 1
        if mac_index >= len(parts):
            continue
        addresses[normalize_mac_address(parts[mac_index])] = parts[0]
    return addresses


def get_hotspot_dhcp_leases(ifname: str) -> dict[str, dict[str, str]]:
    active_connection = next(
        (
            item for item in get_active_connections()
            if item.get("device") == ifname
            and item.get("name") in {HOTSPOT_CONNECTION_NAME, *HOTSPOT_BRIDGED_AP_PROFILES}
        ),
        {},
    )
    bridge_master = get_hotspot_connection_master(active_connection["name"]) if active_connection else ""
    if HOTSPOT_DHCP_LEASE_FILE and HOTSPOT_BRIDGE_INTERFACE and bridge_master == HOTSPOT_BRIDGE_INTERFACE:
        lease_path = Path(HOTSPOT_DHCP_LEASE_FILE)
    else:
        lease_path = Path(f"/var/lib/NetworkManager/dnsmasq-{ifname}.leases")
    try:
        lines = lease_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}

    leases: dict[str, dict[str, str]] = {}
    for line in lines:
        fields = line.split(maxsplit=4)
        if len(fields) < 4:
            continue
        _, mac_address, ip_address, hostname = fields[:4]
        normalized_mac = normalize_mac_address(mac_address)
        if not normalized_mac:
            continue
        leases[normalized_mac] = {
            "ip_address": ip_address.strip() or "未知",
            "device_name": hostname.strip() if hostname.strip() not in {"", "*"} else "未知设备",
        }
    return leases


def get_hotspot_station_clients(ifname: str) -> tuple[list[dict[str, Any]], str | None]:
    result = run_command(["iw", "dev", ifname, "station", "dump"], timeout=8)
    if not result.ok:
        return [], result.output or f"无法读取 {ifname} 的热点客户端"

    clients = parse_iw_station_dump(result.output)
    active_connection = next(
        (
            item for item in get_active_connections()
            if item.get("device") == ifname
            and item.get("name") in {HOTSPOT_CONNECTION_NAME, *HOTSPOT_BRIDGED_AP_PROFILES}
        ),
        {},
    )
    bridge_master = get_hotspot_connection_master(active_connection["name"]) if active_connection else ""
    ipv4_neighbors = get_interface_ipv4_neighbors(bridge_master or ifname)
    dhcp_leases = get_hotspot_dhcp_leases(ifname)
    for client in clients:
        normalized_mac = normalize_mac_address(client.get("mac_address", ""))
        lease = dhcp_leases.get(normalized_mac, {})
        client["device_name"] = lease.get("device_name", "未知设备")
        client["ip_address"] = lease.get("ip_address", "") or ipv4_neighbors.get(normalized_mac, "未知")
    clients.sort(key=lambda item: item.get("mac_address", ""))
    return clients, None


def gather_hotspot_clients_status() -> HotspotClientsStatus:
    errors: list[str] = []
    # 原先这里还并发取了一次 get_hotspot_profile，但结果从未被使用 —— 每次调用
    # 都是一次多余的 nmcli（还要带 --show-secrets 读 PSK）。热点名称后面已经按
    # 连接逐个取过 profile，这里直接去掉。
    active_items = get_active_connections()

    hotspot_connections = [
        item
        for item in active_items
        if item.get("name") in {HOTSPOT_CONNECTION_NAME, *HOTSPOT_BRIDGED_AP_PROFILES}
        and item.get("type") == "802-11-wireless"
        and item.get("device")
    ]

    hotspots: list[dict[str, Any]] = []
    for connection in hotspot_connections:
        hotspot_ifname = connection.get("device", "").strip()
        clients, client_error = get_hotspot_station_clients(hotspot_ifname)
        connection_profile = get_hotspot_connection_profile(connection["name"])
        if client_error:
            errors.append(client_error)
        hotspots.append(
            {
                "ssid": connection_profile.get("ssid", "") or HOTSPOT_DEFAULT_SSID,
                "clients": clients,
                "client_count": len(clients),
            }
        )

    return {
        "hotspots": hotspots,
        "total_clients": sum(item["client_count"] for item in hotspots),
        "errors": errors,
    }


__all__ = [
    "gather_hotspot_clients_status",
    "get_current_wifi_link",
    "get_hotspot_dhcp_leases",
    "get_hotspot_station_clients",
    "get_interface_ipv4_neighbors",
]
