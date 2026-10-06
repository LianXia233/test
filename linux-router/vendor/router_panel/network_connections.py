"""NetworkManager 连接与热点配置的查询。

这一组是纯粹的"读连接属性"，不依赖无线扫描、热点状态或客户端统计，
是 network.py 里最独立的一块。把它单独拆出来后，热点客户端模块才能
在不需要 network.py 的情况下复用它，避免模块之间循环导入。
"""

from __future__ import annotations

from .core import (
    HOTSPOT_BRIDGED_AP_PROFILES,
    HOTSPOT_CONNECTION_NAME,
    HOTSPOT_DEFAULT_SSID,
    is_hotspot_virtual_interface,
    run_command,
)
from .network_parsers import parse_nmcli_lines, translate_connection_type

def get_hotspot_profile() -> dict[str, str]:
    return get_hotspot_connection_profile(HOTSPOT_CONNECTION_NAME)


def get_hotspot_connection_profile(connection_name: str) -> dict[str, str]:
    details = run_command(
        [
            "nmcli",
            "--show-secrets",
            "-g",
            "802-11-wireless.ssid,802-11-wireless-security.psk,802-11-wireless.band,802-11-wireless.channel,connection.interface-name",
            "connection",
            "show",
            connection_name,
        ]
    )
    if not details.ok or not details.output:
        return {
            "ssid": HOTSPOT_DEFAULT_SSID,
            "password": "",
            "band": "",
            "channel": "",
            "interface_name": "",
            "mode": "exclusive",
        }

    lines = details.output.splitlines()
    ssid = lines[0].strip() if lines else HOTSPOT_DEFAULT_SSID
    password = lines[1].strip() if len(lines) > 1 else ""
    band = lines[2].strip() if len(lines) > 2 else ""
    channel = lines[3].strip() if len(lines) > 3 else ""
    interface_name = lines[4].strip() if len(lines) > 4 else ""
    return {
        "ssid": ssid or HOTSPOT_DEFAULT_SSID,
        "password": password,
        "band": band,
        "channel": channel,
        "interface_name": interface_name,
        "mode": "concurrent" if is_hotspot_virtual_interface(interface_name) else "exclusive",
    }


def get_hotspot_connection_master(connection_name: str) -> str:
    result = run_command(
        ["nmcli", "-g", "connection.master", "connection", "show", "id", connection_name],
        timeout=5,
    )
    return result.output.strip() if result.ok else ""


def get_active_connections() -> list[dict[str, str]]:
    active_connections = run_command(
        [
            "nmcli",
            "-t",
            "-f",
            "NAME,TYPE,DEVICE",
            "connection",
            "show",
            "--active",
        ]
    )
    active_items = (
        parse_nmcli_lines(active_connections.output, ["name", "type", "device"])
        if active_connections.ok and active_connections.output
        else []
    )
    return [
        {
            **item,
            "type_label": (
                "热点"
                if item.get("name") in {HOTSPOT_CONNECTION_NAME, *HOTSPOT_BRIDGED_AP_PROFILES}
                and item.get("type") == "802-11-wireless"
                else translate_connection_type(item.get("type", ""))
            ),
        }
        for item in active_items
        if item.get("device") != "lo"
    ]


__all__ = [
    "get_active_connections",
    "get_hotspot_connection_master",
    "get_hotspot_connection_profile",
    "get_hotspot_profile",
]
