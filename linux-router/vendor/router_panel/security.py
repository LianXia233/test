"""登录限流与安全审计。

设计约束与边界（务必知悉，避免误用）：

* 计数**跨 gunicorn worker 共享**。面板以 ``--workers 2`` 运行，如果计数只放在
  进程内存里，攻击者轮流命中不同 worker 就能把阈值翻倍（5 次变成 10 次）。
  因此状态落在 ``DATA_DIR/login-guard.json``，用 ``flock`` 串行化读改写：
  flock 是内核级锁，同进程多线程与跨进程都生效。
* 状态落盘会带来"攻击者写满状态"的面，所以条目数有上限（``MAX_TRACKED_CLIENTS``），
  超出时淘汰最久未更新的来源；单个文件的读写也有字节上限。
* 计数不跨重启保留：重启后文件仍在，但内容按窗口过期自动淘汰，等价于清零。
* 读不到状态文件时**退回进程内存计数**（限流弱一些，但绝不能因为锁或磁盘
  问题让正常登录 500）。
* 审计日志写 stderr，由 systemd-journald 捕获：``journalctl -u router-panel``。
  日志**绝不记录口令、CSRF token 或表单正文**，只记录事件、来源 IP 与结果。
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import threading
import time
from contextlib import contextmanager
from typing import Any

from .core import DATA_DIR

# 连续失败多少次开始锁定
MAX_FAILURES_BEFORE_LOCKOUT = 5
# 首次锁定秒数，之后每次触发按 2 倍递增
BASE_LOCKOUT_SECONDS = 30.0
# 单次锁定上限（15 分钟）
MAX_LOCKOUT_SECONDS = 900.0
# 失败记录的保留窗口：窗口内无新失败则计数清零
FAILURE_WINDOW_SECONDS = 900.0
# 最多跟踪多少个来源。达到上限后淘汰最久未更新的，避免被写满。
MAX_TRACKED_CLIENTS = 512
# 状态文件的字节上限，防止异常内容把内存撑爆
MAX_STATE_BYTES = 256 * 1024

STATE_PATH = DATA_DIR / "login-guard.json"

# 进程内串行化（多线程 worker 内），跨进程由 flock 兜底
_lock = threading.Lock()
# 打不开状态文件时的兜底容器
_memory_state: dict[str, dict[str, Any]] = {}


def _now() -> float:
    # 落盘状态要用 wall clock：monotonic 的基准不跨重启，且不便人工排查。
    return time.time()


def _empty_entry() -> dict[str, Any]:
    return {"failures": [], "strikes": 0, "locked_until": 0.0, "updated_at": 0.0}


@contextmanager
def _state_file():
    """以排他 flock 打开状态文件；打不开时 yield None。"""
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(STATE_PATH, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        yield None
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield fd
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _read_state(fd: int | None) -> dict[str, dict[str, Any]]:
    if fd is None:
        return _memory_state
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        raw = os.read(fd, MAX_STATE_BYTES)
    except OSError:
        return {}
    if not raw:
        return {}
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}
    clients = payload.get("clients") if isinstance(payload, dict) else None
    if not isinstance(clients, dict):
        return {}
    return {
        str(key): value
        for key, value in clients.items()
        if isinstance(value, dict) and isinstance(key, str)
    }


def _write_state(fd: int | None, clients: dict[str, dict[str, Any]]) -> None:
    if fd is None:
        _memory_state.clear()
        _memory_state.update(clients)
        return
    # 条目超限时淘汰最久未更新的来源，保证文件不会无限增长
    if len(clients) > MAX_TRACKED_CLIENTS:
        ordered = sorted(clients.items(), key=lambda item: item[1].get("updated_at", 0.0))
        clients = dict(ordered[len(ordered) - MAX_TRACKED_CLIENTS :])
    payload = json.dumps({"version": 1, "clients": clients}, separators=(",", ":")).encode("utf-8")
    try:
        os.ftruncate(fd, 0)
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, payload)
    except OSError:
        pass


def _prune(timestamps: list[float]) -> list[float]:
    cutoff = _now() - FAILURE_WINDOW_SECONDS
    return [item for item in timestamps if item >= cutoff]


def lockout_remaining(client_key: str) -> float:
    """返回该来源仍需等待的秒数（0 表示未被锁定）。"""
    with _lock, _state_file() as fd:
        clients = _read_state(fd)
        entry = clients.get(client_key)
        if not entry:
            return 0.0
        remaining = float(entry.get("locked_until", 0.0)) - _now()
        if remaining <= 0:
            entry["locked_until"] = 0.0
            _write_state(fd, clients)
            return 0.0
        return remaining


def register_failure(client_key: str) -> float:
    """记录一次登录失败，返回本次需要等待的秒数（0 表示尚未触发锁定）。"""
    with _lock, _state_file() as fd:
        clients = _read_state(fd)
        now = _now()
        entry = clients.get(client_key) or _empty_entry()
        timestamps = _prune([float(item) for item in entry.get("failures", []) if isinstance(item, (int, float))])
        timestamps.append(now)
        entry["failures"] = timestamps
        entry["updated_at"] = now
        clients[client_key] = entry

        if len(timestamps) < MAX_FAILURES_BEFORE_LOCKOUT:
            _write_state(fd, clients)
            return 0.0

        strikes = int(entry.get("strikes", 0)) + 1
        delay = min(BASE_LOCKOUT_SECONDS * (2 ** (strikes - 1)), MAX_LOCKOUT_SECONDS)
        entry["strikes"] = strikes
        entry["locked_until"] = now + delay
        # 触发锁定后清空窗口，避免解锁瞬间被连续判定为再次锁定
        entry["failures"] = []
        _write_state(fd, clients)
        return delay


def register_success(client_key: str) -> None:
    """登录成功后清除该来源的失败与锁定状态。"""
    with _lock, _state_file() as fd:
        clients = _read_state(fd)
        if client_key in clients:
            clients.pop(client_key)
            _write_state(fd, clients)


def reset_state() -> None:
    """仅用于测试：清空全部限流状态（内存兜底与落盘状态一起清）。"""
    with _lock:
        _memory_state.clear()
        try:
            STATE_PATH.unlink(missing_ok=True)
        except OSError:
            pass


def _build_audit_logger() -> logging.Logger:
    logger = logging.getLogger("router-panel.audit")
    if logger.handlers:
        return logger
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    # 不向 root 传播，避免与 Flask 自身日志相互污染
    logger.propagate = False
    return logger


audit_logger = _build_audit_logger()


def audit(event: str, **fields: Any) -> None:
    """写一条结构化审计日志（值全部转为字符串，避免注入换行破坏日志）。"""
    payload = {"event": event}
    for key, value in fields.items():
        payload[key] = str(value).replace("\n", "\\n").replace("\r", "\\r")
    audit_logger.info(" ".join(f"{key}={value}" for key, value in payload.items()))


__all__ = [
    "MAX_FAILURES_BEFORE_LOCKOUT",
    "BASE_LOCKOUT_SECONDS",
    "MAX_LOCKOUT_SECONDS",
    "FAILURE_WINDOW_SECONDS",
    "MAX_TRACKED_CLIENTS",
    "STATE_PATH",
    "audit",
    "audit_logger",
    "lockout_remaining",
    "register_failure",
    "register_success",
    "reset_state",
]
