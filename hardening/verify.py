"""Read-only host hardening verification."""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from .commands import CommandError, Runner
from .policy import (
    ALLOWED_RULES,
    OPTIONAL_UNITS,
    all_rfkill_soft_blocked,
    has_exact_line,
    listening_has_unwanted,
    overlay_scope,
    parse_unit_names,
    status_has_rule,
    unexpected_ufw_rules,
    unit_active_bad,
    unit_active_ok,
    unit_enabled_bad,
    unit_enabled_ok,
)

REQUIRED_COMMANDS = ("ip", "rfkill", "ss", "systemctl", "tailscale", "ufw")
BOOT_CONFIGS = (Path("/boot/firmware/config.txt"), Path("/boot/config.txt"))
UFW_CONFIG = Path("/etc/default/ufw")


class Checks:
    def __init__(self) -> None:
        self.failures = 0

    def fail(self, message: str) -> None:
        print(f"verify: FAIL: {message}", file=sys.stderr)
        self.failures += 1


def _boot_config() -> Path:
    for path in BOOT_CONFIGS:
        if path.is_file():
            return path
    raise CommandError("supported boot config not found (/boot/firmware/config.txt or /boot/config.txt)")


def _ipv6_enabled(text: str) -> bool:
    return any(re.fullmatch(r"\s*IPV6\s*=\s*yes\s*(?:#.*)?", line) for line in text.splitlines())


def _unit_exists(runner: Runner, unit: str) -> bool | None:
    result = runner.run(("systemctl", "list-unit-files", "--no-legend", unit))
    if result.returncode != 0:
        return None
    if any(fields and fields[0] == unit for fields in (line.split() for line in result.output.splitlines())):
        return True
    result = runner.run(("systemctl", "list-units", "--all", "--no-legend", unit))
    if result.returncode != 0:
        return None
    return any(fields and fields[0] == unit for fields in (line.split() for line in result.output.splitlines()))


def _check_unit(runner: Runner, checks: Checks, unit: str) -> None:
    enabled_result = runner.run(("systemctl", "is-enabled", unit))
    active_result = runner.run(("systemctl", "is-active", unit))
    enabled = enabled_result.output.strip()
    active = active_result.output.strip()
    print(f"{unit}: enabled={enabled} active={active}")
    if unit_enabled_bad(enabled):
        checks.fail(f"{unit} is enabled")
    elif not unit_enabled_ok(enabled):
        checks.fail(f"could not determine enabled state for {unit}")
    if unit_active_bad(active):
        checks.fail(f"{unit} is active")
    elif not unit_active_ok(active):
        checks.fail(f"could not determine active state for {unit}")


def _check_configured_rules(runner: Runner, checks: Checks) -> None:
    result = runner.run(("ufw", "show", "added"))
    if result.returncode != 0:
        print(result.output, file=sys.stderr, end="")
        checks.fail("could not read configured UFW rules")
        return
    unexpected = unexpected_ufw_rules(result.output)
    if unexpected:
        print("\n".join(unexpected), file=sys.stderr)
        checks.fail("unexpected UFW rules exist outside the Tailscale-only allowlist")
    else:
        print("verify: OK: configured UFW rules are limited to the Tailscale allowlist")


def verify(runner: Runner | None = None) -> int:
    if os.geteuid() != 0:
        print("verify: run as root (use sudo)", file=sys.stderr)
        return 1
    runner = runner or Runner()
    checks = Checks()
    for command in REQUIRED_COMMANDS:
        try:
            runner.require(command)
        except CommandError as exc:
            print(f"verify: {exc}", file=sys.stderr)
            return 1

    boot_config = _boot_config()
    boot_text = boot_config.read_text(encoding="utf-8")
    print("== UFW status and rules ==")
    status_result = runner.run(("ufw", "status", "verbose"))
    ufw_status = status_result.output
    if status_result.returncode != 0:
        print(ufw_status, file=sys.stderr, end="")
        checks.fail("could not read UFW status")
    print(ufw_status, end="")
    if "Status: active" not in ufw_status:
        checks.fail("UFW is not active")
    if not has_exact_line(ufw_status, "Default: deny (incoming), allow (outgoing), deny (routed)"):
        checks.fail("UFW defaults are not deny incoming, allow outgoing, deny routed")
    if not has_exact_line(ufw_status, "Logging: low"):
        checks.fail("UFW logging is not low")
    if not UFW_CONFIG.is_file() or not _ipv6_enabled(UFW_CONFIG.read_text(encoding="utf-8")):
        checks.fail("UFW IPv6 support is not enabled in /etc/default/ufw")
    else:
        print("verify: OK: UFW IPv6 support is enabled")
    for port, protocol in ALLOWED_RULES:
        if status_has_rule(ufw_status, port, protocol):
            print(f"verify: OK: exact IPv4 and IPv6 rule for {port}/{protocol} on tailscale0")
        else:
            checks.fail(f"missing exact IPv4 and IPv6 UFW rule for {port}/{protocol} on tailscale0")
    _check_configured_rules(runner, checks)

    print("== Relevant unit states ==")
    for unit in OPTIONAL_UNITS:
        exists = _unit_exists(runner, unit)
        if exists is True:
            _check_unit(runner, checks, unit)
        elif exists is False:
            print(f"{unit}: absent (expected optional unit)")
        else:
            checks.fail(f"could not inspect {unit}")
    wpa_result = runner.run(("systemctl", "list-units", "--all", "--no-legend", "wpa_supplicant@*.service"))
    if wpa_result.returncode != 0:
        print(wpa_result.output, file=sys.stderr, end="")
        checks.fail("could not inspect wpa_supplicant instances")
    else:
        instances = parse_unit_names(wpa_result.output)
        if instances:
            for unit in instances:
                _check_unit(runner, checks, unit)
        else:
            print("wpa_supplicant instances: absent (expected optional unit)")

    print("== Boot overlay state ==")
    for overlay in ("disable-wifi", "disable-bt"):
        state = overlay_scope(boot_text, overlay)
        print(f"{overlay}: {state}")
        if state == "conditional":
            checks.fail(f"{overlay} is only configured under a conditional boot section")
        elif state == "absent":
            checks.fail(f"{overlay} is missing from {boot_config}")
        elif state != "unconditional":
            checks.fail(f"could not determine {overlay} state")

    print("== rfkill list ==")
    rfkill_result = runner.run(("rfkill", "list"))
    if rfkill_result.returncode != 0:
        print(rfkill_result.output, file=sys.stderr, end="")
        checks.fail("rfkill could not list radio devices")
    print(rfkill_result.output, end="")
    if rfkill_result.returncode == 0:
        if rfkill_result.output:
            if all_rfkill_soft_blocked(rfkill_result.output):
                print("verify: OK: listed rfkill devices are soft-blocked")
            else:
                checks.fail("an rfkill device is not soft-blocked")
        else:
            print("verify: OK: no rfkill devices (expected after disabling Wi-Fi and Bluetooth)")

    interface = runner.run(("ip", "link", "show", "dev", "tailscale0"))
    if interface.returncode == 0:
        print("verify: OK: tailscale0 is available")
    else:
        checks.fail("tailscale0 is not available")

    print("== Listening sockets ==")
    sockets = runner.run(("ss", "-lntup"))
    if sockets.returncode != 0:
        print(sockets.output, file=sys.stderr, end="")
        checks.fail("ss could not enumerate listening sockets")
    print(sockets.output, end="")
    if sockets.returncode == 0:
        if listening_has_unwanted(sockets.output):
            checks.fail("ss shows an unwanted sshd or Avahi listener")
        else:
            print("verify: OK: no sshd or Avahi listener found")

    print("== Tailscale Serve status ==")
    serve = runner.run(("tailscale", "serve", "status"))
    if serve.returncode == 0:
        print(serve.output, end="")
    else:
        print(serve.output, file=sys.stderr, end="")
        print("verify: WARN: could not read Tailscale Serve status; check it after configuring Serve", file=sys.stderr)

    if checks.failures:
        print(f"verify: {checks.failures} check(s) failed", file=sys.stderr)
        return 1
    print("verify: all local hardening checks passed")
    return 0


def main() -> int:
    try:
        return verify()
    except (CommandError, OSError) as exc:
        print(f"verify: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
