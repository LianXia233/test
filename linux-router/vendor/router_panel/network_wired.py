"""有线（以太网）接口的状态采集与展示格式化。

这一组功能原先整段放在 network.py 里。network.py 同时承担无线扫描、热点、
客户端与有线四类职责，已经到了 1500 行量级，任何一处改动都要在长文件里
来回跳。有线这一块与无线/热点之间没有共享状态（只依赖 core 的命令执行和
network_parsers 的字段翻译），是代价最低、边界最清晰的一刀。

network.py 仍然 re-export 这里的名字，因此既有 import 不需要改。
"""

from __future__ import annotations

from typing import Any

from .core import read_text, run_command
from .network_parsers import normalize_nmcli_general_state, translate_device_state


def default_wired_profile(ifname: str) -> dict[str, Any]:
    return {
        "name": "",
        "active_device": ifname,
        "interface_name": ifname,
        "autoconnect": True,
        "ipv4_method": "auto",
        "ipv4_address": "",
        "ipv4_gateway": "",
        "ipv4_dns": "",
        "route_metric": "-1",
    }


def parse_link_speed_mbps(value: str) -> int:
    raw = value.strip()
    if not raw or raw in {"--", "-1"}:
        return 0
    try:
        speed = int(float(raw.split()[0]))
    except (ValueError, IndexError):
        return 0
    return speed if speed > 0 else 0


def format_link_speed(value: str) -> str:
    speed_mbps = parse_link_speed_mbps(value)
    if not speed_mbps:
        return "未知"
    if speed_mbps >= 1000:
        speed_gbps = speed_mbps / 1000
        return f"{speed_gbps:g} Gbps"
    return f"{speed_mbps} Mbps"


def get_wired_carrier(ifname: str) -> str:
    carrier = read_text(f"/sys/class/net/{ifname}/carrier")
    return carrier if carrier in {"0", "1"} else ""


def get_wired_sysfs_speed(ifname: str) -> str:
    return read_text(f"/sys/class/net/{ifname}/speed")


def normalize_wired_state(state: str, carrier: str) -> str:
    if state == "unavailable" and carrier == "0":
        return "disconnected"
    return state


def translate_ipv4_method(value: str) -> str:
    method = value.strip().lower()
    if method == "manual":
        return "静态地址"
    if method in {"auto", "shared"}:
        return "DHCP"
    return "未知"


def get_wired_ipv4_method_label(connection_name: str) -> str:
    if not connection_name:
        return "未知"
    result = run_command(
        ["nmcli", "-g", "ipv4.method", "connection", "show", "id", connection_name],
        timeout=5,
    )
    if not result.ok:
        return "未知"
    return translate_ipv4_method(result.output)


def gather_wired_network_info() -> dict[str, Any]:
    result = run_command(
        [
            "nmcli",
            "-t",
            "-f",
            (
                "GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION,"
                "GENERAL.HWADDR,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS"
            ),
            "device",
            "show",
        ]
    )
    if not result.ok or not result.output:
        return {
            "devices": [],
            "errors": [result.output or "无法读取有线网络状态"],
        }

    raw_devices: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in result.output.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        value = value.strip()

        if key == "GENERAL.DEVICE":
            if current:
                raw_devices.append(current)
            current = {
                "device": value,
                "type": "",
                "state": "",
                "connection": "",
                "mac": "",
                "ipv4": [],
                "gateway": "",
                "dns": [],
            }
            continue
        if current is None:
            continue

        if key == "GENERAL.TYPE":
            current["type"] = value
        elif key == "GENERAL.STATE":
            current["state"] = normalize_nmcli_general_state(value)
        elif key == "GENERAL.CONNECTION":
            current["connection"] = "" if value == "--" else value
        elif key == "GENERAL.HWADDR":
            current["mac"] = value
        elif key.startswith("IP4.ADDRESS"):
            current["ipv4"].append(value)
        elif key == "IP4.GATEWAY":
            current["gateway"] = value
        elif key.startswith("IP4.DNS"):
            current["dns"].append(value)
    if current:
        raw_devices.append(current)

    devices: list[dict[str, Any]] = []
    for device in sorted(raw_devices, key=lambda value: value.get("device", "")):
        if device.get("type") != "ethernet":
            continue
        ifname = device.get("device", "")
        connection_name = device.get("connection", "")
        carrier = get_wired_carrier(ifname)
        state = normalize_wired_state(device.get("state", ""), carrier)
        speed = "" if carrier == "0" else get_wired_sysfs_speed(ifname)
        profile = default_wired_profile(ifname)
        profile["name"] = connection_name
        profile["ipv4_method_label"] = get_wired_ipv4_method_label(connection_name)
        devices.append(
            {
                "device": ifname,
                "state": state,
                "state_label": translate_device_state(state),
                "connection": connection_name or "未连接",
                "details": {
                    "mac": device.get("mac", ""),
                    "carrier": carrier,
                    "link_speed": format_link_speed(speed),
                    "ipv4": device.get("ipv4", []),
                    "gateway": device.get("gateway", ""),
                    "dns": device.get("dns", []),
                },
                "profile": profile,
            }
        )

    return {
        "devices": devices,
        "errors": [],
    }


__all__ = [
    "default_wired_profile",
    "format_link_speed",
    "gather_wired_network_info",
    "get_wired_carrier",
    "get_wired_ipv4_method_label",
    "get_wired_sysfs_speed",
    "normalize_wired_state",
    "parse_link_speed_mbps",
    "translate_ipv4_method",
]
