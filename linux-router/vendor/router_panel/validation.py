"""WebUI 与 agent 共用的输入校验。

此前热点参数在两处各写了一份判定：``web_network.hotspot_start`` 在提交前挡
一次，``agent_server._execute_hotspot_start`` 在执行前再挡一次。两份逻辑一
旦漂移（比如某一侧放宽了口令长度），就会出现「页面提示通过、agent 里被拒」
或反过来，而且错误消息会不一致。这里把常量、正则与判定收敛成单一来源，
两边只调用本模块的函数。

约定：所有校验函数返回 ``None`` 表示通过，返回字符串表示失败原因。agent 侧
把字符串包进 ``ValidationError``，WebUI 侧直接展示，因此错误文案天然一致。
"""

from __future__ import annotations

import re

# 接口名最长 15 字符是内核 IFNAMSIZ-1 的约束，同时禁止 shell 元字符。
IFNAME_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,15}$")
IFNAME_MAX_LENGTH = 15
IFNAME_ERROR = "无线接口名称无效"

# 信道只在页面下拉里给，仍是外部可提交字段，必须再做一次白名单。
CHANNEL_RE = re.compile(r"^[0-9]{1,4}$")
CHANNEL_MAX_LENGTH = 4
CHANNEL_ERROR = "热点信道无效"

# SSID 是 32 字节而不是 32 个字符：中文 SSID 一个字占 3 字节。
SSID_MAX_BYTES = 32
SSID_EMPTY_ERROR = "请输入热点名称"
SSID_TOO_LONG_ERROR = "热点名称必须是 1 到 32 字节"

# WPA2-PSK 的下限是 8 字符，上限 63 字符由 802.11 的 RSN IE 决定。
PASSWORD_MIN_LENGTH = 8
PASSWORD_MAX_LENGTH = 63
PASSWORD_LENGTH_ERROR = "热点密码长度必须在 8 到 63 个字符之间"

BAND_MAX_LENGTH = 8
MODE_MAX_LENGTH = 16


def validate_ifname(ifname: str) -> str | None:
    """校验无线接口名。"""
    if not isinstance(ifname, str) or not IFNAME_RE.fullmatch(ifname):
        return IFNAME_ERROR
    return None


def validate_hotspot_ssid(ssid: str) -> str | None:
    """校验热点名称，按 UTF-8 字节数而不是字符数计量。

    纯空格的名称没有意义，且与上游（WebUI 表单、agent 的 _require_string）
    一样先 strip 再判定，避免两侧对同一个输入给出不同结论。
    """
    if not isinstance(ssid, str):
        return SSID_EMPTY_ERROR
    candidate = ssid.strip()
    if not candidate:
        return SSID_EMPTY_ERROR
    if len(candidate.encode("utf-8")) > SSID_MAX_BYTES:
        return SSID_TOO_LONG_ERROR
    return None


def validate_hotspot_password(password: str) -> str | None:
    """校验热点口令长度。口令不做 strip，空格是合法口令字符。"""
    if not isinstance(password, str):
        return PASSWORD_LENGTH_ERROR
    if not PASSWORD_MIN_LENGTH <= len(password) <= PASSWORD_MAX_LENGTH:
        return PASSWORD_LENGTH_ERROR
    return None


def validate_hotspot_channel(channel: str) -> str | None:
    """校验热点信道。空串表示交给自动选择，允许通过。"""
    if not isinstance(channel, str):
        return CHANNEL_ERROR
    if channel and not CHANNEL_RE.fullmatch(channel):
        return CHANNEL_ERROR
    return None


def validate_hotspot_credentials(ssid: str, password: str) -> str | None:
    """按页面上的展示顺序依次校验名称与口令，返回第一个错误。"""
    return validate_hotspot_ssid(ssid) or validate_hotspot_password(password)


__all__ = [
    "BAND_MAX_LENGTH",
    "CHANNEL_ERROR",
    "CHANNEL_MAX_LENGTH",
    "CHANNEL_RE",
    "IFNAME_ERROR",
    "IFNAME_MAX_LENGTH",
    "IFNAME_RE",
    "MODE_MAX_LENGTH",
    "PASSWORD_LENGTH_ERROR",
    "PASSWORD_MAX_LENGTH",
    "PASSWORD_MIN_LENGTH",
    "SSID_EMPTY_ERROR",
    "SSID_MAX_BYTES",
    "SSID_TOO_LONG_ERROR",
    "validate_hotspot_channel",
    "validate_hotspot_credentials",
    "validate_hotspot_password",
    "validate_hotspot_ssid",
    "validate_ifname",
]
