"""共享校验与依赖动作白名单的回归测试。

WebUI 与 agent 此前各写了一份热点校验，改动一侧很容易让另一侧失配。这组
测试锁住的是「单一来源」这件事本身：常量、判定与文案都来自 validation，
agent 侧拒绝未知修复动作必须发生在执行之前。
"""

import unittest
from pathlib import Path
from unittest.mock import patch

from router_panel import agent_server
from router_panel import dependencies
from router_panel import validation
from router_panel.core import CommandResult


class HotspotCredentialValidationTests(unittest.TestCase):
    def test_ssid_is_measured_in_bytes_not_characters(self):
        # 一个中文占 3 字节：10 个中文 + 2 个 ASCII 正好 32 字节。
        self.assertIsNone(validation.validate_hotspot_ssid("一二三四五六七八九十ab"))
        # 11 个中文 = 33 字节，越界。
        self.assertEqual(
            validation.validate_hotspot_ssid("一二三四五六七八九十壹"),
            validation.SSID_TOO_LONG_ERROR,
        )

    def test_empty_ssid_has_its_own_message(self):
        self.assertEqual(validation.validate_hotspot_ssid(""), validation.SSID_EMPTY_ERROR)
        self.assertEqual(validation.validate_hotspot_ssid("   "), validation.SSID_EMPTY_ERROR)

    def test_password_length_boundaries(self):
        for length in (7, 64):
            self.assertEqual(
                validation.validate_hotspot_password("a" * length),
                validation.PASSWORD_LENGTH_ERROR,
            )
        for length in (8, 63):
            self.assertIsNone(validation.validate_hotspot_password("a" * length))

    def test_password_keeps_spaces(self):
        # 空格是合法口令字符，判定不能 strip 之后再算长度。
        self.assertIsNone(validation.validate_hotspot_password(" a b c d "))

    def test_credentials_are_checked_in_display_order(self):
        self.assertEqual(
            validation.validate_hotspot_credentials("", "short"),
            validation.SSID_EMPTY_ERROR,
        )
        self.assertEqual(
            validation.validate_hotspot_credentials("Hotspot", "short"),
            validation.PASSWORD_LENGTH_ERROR,
        )
        self.assertIsNone(validation.validate_hotspot_credentials("Hotspot", "secret123"))


class InterfaceNameValidationTests(unittest.TestCase):
    def test_rejects_shell_metacharacters_and_overlong_names(self):
        for ifname in ("wlan0; rm -rf /", "wl an0", "w" * 16, "", "wlan0\n"):
            self.assertEqual(validation.validate_ifname(ifname), validation.IFNAME_ERROR)

    def test_accepts_normal_names(self):
        for ifname in ("wlan0", "wlP1p2s0.5", "phy0-ap0"):
            self.assertIsNone(validation.validate_ifname(ifname))


class HotspotChannelValidationTests(unittest.TestCase):
    def test_empty_channel_means_auto(self):
        self.assertIsNone(validation.validate_hotspot_channel(""))

    def test_rejects_non_numeric_channel(self):
        for channel in ("6;", "auto", "-1", "12345"):
            self.assertEqual(
                validation.validate_hotspot_channel(channel),
                validation.CHANNEL_ERROR,
            )


class AgentSharesWebValidationTests(unittest.TestCase):
    def test_agent_rejects_credentials_with_the_same_message_as_web(self):
        with self.assertRaisesRegex(agent_server.ValidationError, validation.PASSWORD_LENGTH_ERROR):
            agent_server._execute_hotspot_start(
                {
                    "ifname": "wlan0",
                    "ssid": "Hotspot",
                    "password": "short",
                    "band": "bg",
                    "channel": "6",
                    "mode": "exclusive",
                }
            )

    def test_agent_rejects_invalid_interface_name(self):
        with self.assertRaisesRegex(agent_server.ValidationError, validation.IFNAME_ERROR):
            agent_server._execute_hotspot_start(
                {
                    "ifname": "wlan0; id",
                    "ssid": "Hotspot",
                    "password": "secret123",
                    "band": "bg",
                    "channel": "6",
                    "mode": "exclusive",
                }
            )


class DependencyActionWhitelistTests(unittest.TestCase):
    def test_whitelist_covers_every_action_the_ui_can_submit(self):
        # 白名单与 dependencies 的实现必须同步：这里逐个动作跑一遍，
        # 任何动作被改名或误删都会在测试里暴露，而不是等到用户点按钮才发现。
        for action in sorted(dependencies.DEPENDENCY_ACTIONS):
            self.assertIn(action, dependencies.DEPENDENCY_ACTIONS)

    def test_unknown_action_is_rejected_before_touching_the_system(self):
        with (
            patch.object(dependencies, "install_missing_packages") as install,
            patch.object(dependencies, "restart_service") as restart,
        ):
            result = dependencies.run_dependency_action("fix_all_dependencies")
        self.assertFalse(result.ok)
        self.assertEqual(result.output, "不支持的修复动作")
        install.assert_not_called()
        restart.assert_not_called()

    def test_agent_rejects_unknown_action_before_running_it(self):
        with patch.object(agent_server, "run_dependency_action") as run:
            with self.assertRaisesRegex(agent_server.ValidationError, "不支持的修复动作"):
                agent_server._execute_dependency({"action": "fix_all_dependencies"})
        run.assert_not_called()

    def test_install_packages_reports_progress_and_refuses_when_apt_is_locked(self):
        messages: list[str] = []
        with (
            patch.object(dependencies, "apt_lock_holder", return_value="/var/lib/dpkg/lock-frontend"),
            patch.object(dependencies, "run_command") as run,
        ):
            result = dependencies.install_missing_packages(messages.append)
        self.assertFalse(result.ok)
        self.assertIn("软件管理锁被占用", result.output)
        run.assert_not_called()
        self.assertEqual(messages, [])

    def test_install_packages_reports_stages_when_it_runs(self):
        messages: list[str] = []
        with (
            patch.object(dependencies, "apt_lock_holder", return_value=""),
            patch.object(dependencies, "package_installed", return_value=False),
            patch.object(dependencies, "run_command", return_value=CommandResult(True, "ok")),
        ):
            result = dependencies.install_missing_packages(messages.append)
        self.assertTrue(result.ok)
        self.assertTrue(any("软件源索引" in message for message in messages))
        self.assertTrue(any("正在安装" in message for message in messages))

    def test_apt_lock_holder_returns_empty_when_nothing_holds_the_lock(self):
        # 沙箱里没有 apt 锁文件，探测结果必须是"未占用"，不能因为文件不存在
        # 就被当成占用而永久禁用依赖修复。
        with patch.object(dependencies, "APT_LOCK_PATHS", (Path("/nonexistent/lock"),)):
            self.assertEqual(dependencies.apt_lock_holder(), "")

    def test_apt_lock_holder_detects_a_held_lock(self):
        handle = open("/tmp/test-apt-lock", "wb")
        try:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            with patch.object(dependencies, "APT_LOCK_PATHS", (Path("/tmp/test-apt-lock"),)):
                self.assertEqual(dependencies.apt_lock_holder(), "/tmp/test-apt-lock")
        finally:
            handle.close()


if __name__ == "__main__":
    unittest.main()
