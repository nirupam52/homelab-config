from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from hardening import apply, policy, verify
from hardening.commands import Result


class PolicyParserTests(unittest.TestCase):
    def test_overlay_sections_comments_and_inline_options(self) -> None:
        config = """# dtoverlay=disable-wifi
[pi4]
dtoverlay=disable-wifi
[all]
# dtoverlay=disable-bt
dtoverlay=disable-bt,foo
"""
        self.assertEqual(policy.overlay_scope(config, "disable-wifi"), "conditional")
        self.assertEqual(policy.overlay_scope(config, "disable-bt"), "unconditional")
        self.assertEqual(policy.overlay_scope("dtoverlay=disable-wifi-extra\n", "disable-wifi"), "absent")

    def test_saved_rules_are_exact_allowlist(self) -> None:
        allowed = "\n".join(sorted(policy.ALLOWED_UFW_RULES))
        self.assertEqual(policy.unexpected_ufw_rules(allowed), ())
        self.assertEqual(
            policy.unexpected_ufw_rules(allowed + "\nufw allow 80/tcp"),
            ("ufw allow 80/tcp",),
        )
        self.assertFalse(policy.configured_has_rule(allowed, "22", "udp"))

    def test_status_rules_require_exact_ipv4_and_ipv6_rows(self) -> None:
        status = """22/tcp on tailscale0 ALLOW IN Anywhere
22/tcp (v6) on tailscale0 ALLOW IN Anywhere (v6)
22/tcp on tailscale0 ALLOW IN from 10.0.0.0/8
"""
        self.assertTrue(policy.status_has_rule(status, "22", "tcp"))
        self.assertFalse(policy.status_has_rule(status, "53", "tcp"))

    def test_systemd_state_classification_and_instances(self) -> None:
        self.assertTrue(policy.unit_enabled_ok("masked"))
        self.assertFalse(policy.unit_enabled_ok("enabled"))
        self.assertTrue(policy.unit_active_bad("reloading"))
        self.assertFalse(policy.unit_active_ok("active"))
        self.assertEqual(
            policy.parse_unit_names(
                "wpa_supplicant@wlan0.service loaded active running\n"
                "other.service loaded inactive dead\n"
            ),
            ("wpa_supplicant@wlan0.service",),
        )


class ApplySafetyTests(unittest.TestCase):
    def test_apply_rejects_conditional_overlay_before_mutation(self) -> None:
        class FakeRunner:
            def __init__(self) -> None:
                self.calls: list[tuple[str, ...]] = []

            def require(self, command: str) -> None:
                pass

            def run(self, argv: tuple[str, ...]) -> Result:
                self.calls.append(argv)
                if argv == ("ip", "link", "show", "dev", "tailscale0"):
                    return Result(0, "")
                raise AssertionError(argv)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            boot = root / "config.txt"
            boot.write_text("[pi4]\ndtoverlay=disable-wifi\n", encoding="utf-8")
            ufw_config = root / "ufw"
            ufw_config.write_text("IPV6=yes\n", encoding="utf-8")
            fake = FakeRunner()
            with (
                patch.object(apply.os, "geteuid", return_value=0),
                patch.object(apply, "BOOT_CONFIGS", (boot,)),
                patch.object(apply, "UFW_CONFIG", ufw_config),
            ):
                with self.assertRaisesRegex(apply.ApplyFailure, "conditional"):
                    apply.apply(["--tailscale-ssh-tested"], fake)
            self.assertEqual(fake.calls, [("ip", "link", "show", "dev", "tailscale0")])


class ReadOnlyVerificationTests(unittest.TestCase):
    def test_verify_issues_only_read_commands(self) -> None:
        class FakeRunner:
            def __init__(self) -> None:
                self.calls: list[tuple[str, ...]] = []

            def require(self, command: str) -> None:
                self.calls.append(("require", command))

            def run(self, argv: tuple[str, ...]) -> Result:
                self.calls.append(argv)
                if argv[:3] == ("ufw", "status", "verbose"):
                    rows = []
                    for port, proto in policy.ALLOWED_RULES:
                        rows.extend(
                            [
                                f"{port}/{proto} on tailscale0 ALLOW IN",
                                f"{port}/{proto} (v6) on tailscale0 ALLOW IN",
                            ]
                        )
                    return Result(
                        0,
                        "Status: active\nDefault: deny (incoming), allow (outgoing), deny (routed)\n"
                        "Logging: low\n" + "\n".join(rows) + "\n",
                    )
                if argv == ("ufw", "show", "added"):
                    return Result(0, "\n".join(sorted(policy.ALLOWED_UFW_RULES)) + "\n")
                if argv[0] == "systemctl":
                    return Result(0, "")
                if argv[0] == "rfkill":
                    return Result(0, "")
                if argv[0] == "ip":
                    return Result(0, "")
                if argv[0] == "ss":
                    return Result(0, "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n")
                if argv[:3] == ("tailscale", "serve", "status"):
                    return Result(0, "")
                raise AssertionError(argv)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            boot = root / "config.txt"
            boot.write_text("[all]\ndtoverlay=disable-wifi\ndtoverlay=disable-bt\n", encoding="utf-8")
            ufw_config = root / "ufw"
            ufw_config.write_text("IPV6=yes\n", encoding="utf-8")
            fake = FakeRunner()
            with (
                patch.object(verify.os, "geteuid", return_value=0),
                patch.object(verify, "BOOT_CONFIGS", (boot,)),
                patch.object(verify, "UFW_CONFIG", ufw_config),
            ):
                self.assertEqual(verify.verify(fake), 0)
            mutating = {
                ("ufw", "default"),
                ("ufw", "logging"),
                ("ufw", "allow"),
                ("ufw", "--force"),
                ("systemctl", "disable"),
                ("systemctl", "stop"),
                ("rfkill", "block"),
            }
            self.assertFalse(any(call[:2] in mutating for call in fake.calls if call and call[0] != "require"))


if __name__ == "__main__":
    unittest.main()
