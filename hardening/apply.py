"""Apply the host hardening policy, preserving the conservative shell ordering."""
from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

from .commands import CommandError, Runner
from .policy import (
    ALLOWED_RULES,
    OPTIONAL_UNITS,
    configured_has_rule,
    configured_rule,
    has_exact_line,
    has_rfkill_device,
    overlay_scope,
    parse_unit_names,
    status_has_rule,
    unexpected_ufw_rules,
    unit_active_bad,
    unit_active_ok,
    unit_enabled_bad,
    unit_enabled_ok,
)

REQUIRED_COMMANDS = ("ip", "rfkill", "systemctl", "ufw")
BOOT_CONFIGS = (Path("/boot/firmware/config.txt"), Path("/boot/config.txt"))
UFW_CONFIG = Path("/etc/default/ufw")
CONFIRMATION = "--tailscale-ssh-tested"


class ApplyFailure(RuntimeError):
    pass


def _output(result_output: str, operation: str, returncode: int) -> str:
    if returncode != 0:
        detail = result_output.strip()
        raise ApplyFailure(f"{operation}: {detail or 'command failed'}")
    return result_output


def _boot_config() -> Path:
    for path in BOOT_CONFIGS:
        if path.is_file():
            return path
    raise ApplyFailure("supported boot config not found (/boot/firmware/config.txt or /boot/config.txt)")


def _ipv6_enabled(text: str) -> bool:
    return any(re.fullmatch(r"\s*IPV6\s*=\s*yes\s*(?:#.*)?", line) for line in text.splitlines())


def _configured_rules(runner: Runner) -> str:
    result = runner.run(("ufw", "show", "added"))
    return _output(result.output, "could not read configured UFW rules", result.returncode)


def _check_configured_rules(configured: str) -> None:
    unexpected = unexpected_ufw_rules(configured)
    if unexpected:
        raise ApplyFailure(
            "unexpected UFW rules exist; review them manually instead of resetting UFW\n"
            + "\n".join(unexpected)
        )


def _ensure_rule(runner: Runner, configured: str, port: str, protocol: str) -> str:
    rule = configured_rule(port, protocol)
    if configured_has_rule(configured, port, protocol):
        print(f"hardening: UFW rule already present: {rule}")
        return configured
    print(f"hardening: adding UFW rule: {rule}")
    result = runner.run(("ufw", "allow", "in", "on", "tailscale0", "to", "any", "port", port, "proto", protocol))
    _output(result.output, f"could not add UFW rule {rule}", result.returncode)
    configured = _configured_rules(runner)
    _check_configured_rules(configured)
    return configured


def _unit_exists(runner: Runner, unit: str) -> bool:
    result = runner.run(("systemctl", "list-unit-files", "--no-legend", unit))
    files = _output(result.output, f"could not inspect {unit}", result.returncode)
    if any(fields and fields[0] == unit for fields in (line.split() for line in files.splitlines())):
        return True
    result = runner.run(("systemctl", "list-units", "--all", "--no-legend", unit))
    loaded = _output(result.output, f"could not inspect {unit}", result.returncode)
    return any(fields and fields[0] == unit for fields in (line.split() for line in loaded.splitlines()))


def _check_unit_disabled(runner: Runner, unit: str) -> None:
    enabled_result = runner.run(("systemctl", "is-enabled", unit))
    enabled = enabled_result.output.strip()
    if unit_enabled_bad(enabled):
        raise ApplyFailure(f"{unit} is still enabled ({enabled})")
    if not unit_enabled_ok(enabled):
        raise ApplyFailure(f"could not determine enabled state for {unit}: {enabled}")

    active_result = runner.run(("systemctl", "is-active", unit))
    active = active_result.output.strip()
    if unit_active_bad(active):
        raise ApplyFailure(f"{unit} is still active ({active})")
    if not unit_active_ok(active):
        raise ApplyFailure(f"could not determine active state for {unit}: {active}")


def _disable_unit(runner: Runner, unit: str) -> None:
    if not _unit_exists(runner, unit):
        print(f"hardening: optional unit absent, skipping {unit}")
        return
    print(f"hardening: disabling/stopping {unit}")
    result = runner.run(("systemctl", "disable", unit))
    _output(result.output, f"could not disable {unit}", result.returncode)
    result = runner.run(("systemctl", "stop", unit))
    _output(result.output, f"could not stop {unit}", result.returncode)
    _check_unit_disabled(runner, unit)


def apply(argv: list[str] | None = None, runner: Runner | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if os.geteuid() != 0:
        raise ApplyFailure("run as root (use sudo)")
    if args != [CONFIRMATION]:
        print("Usage: sudo sh apply.sh --tailscale-ssh-tested", file=sys.stderr)
        print("The flag is required only after Tailscale SSH has been tested from another tailnet device.", file=sys.stderr)
        return 2

    runner = runner or Runner()
    for command in REQUIRED_COMMANDS:
        runner.require(command)

    interface = runner.run(("ip", "link", "show", "dev", "tailscale0"))
    if interface.returncode != 0:
        raise ApplyFailure("tailscale0 is not available; keep current access until Tailscale is connected")
    if not UFW_CONFIG.is_file() or not os.access(UFW_CONFIG, os.R_OK):
        raise ApplyFailure("UFW configuration not found at /etc/default/ufw")
    if not _ipv6_enabled(UFW_CONFIG.read_text(encoding="utf-8")):
        raise ApplyFailure("UFW IPv6 support is not enabled in /etc/default/ufw")

    boot_config = _boot_config()
    boot_text = boot_config.read_text(encoding="utf-8")
    wifi_scope = overlay_scope(boot_text, "disable-wifi")
    bt_scope = overlay_scope(boot_text, "disable-bt")
    if wifi_scope == "conditional":
        raise ApplyFailure("disable-wifi exists under a conditional boot section; move it to [all] manually")
    if bt_scope == "conditional":
        raise ApplyFailure("disable-bt exists under a conditional boot section; move it to [all] manually")

    configured = _configured_rules(runner)
    _check_configured_rules(configured)
    # Keep the shell script's policy command ordering explicit.
    runner.check(("ufw", "default", "deny", "incoming"), "could not set UFW incoming policy")
    runner.check(("ufw", "default", "allow", "outgoing"), "could not set UFW outgoing policy")
    runner.check(("ufw", "default", "deny", "routed"), "could not set UFW routed policy")
    runner.check(("ufw", "logging", "low"), "could not set UFW logging")
    for port, protocol in ALLOWED_RULES:
        configured = _ensure_rule(runner, configured, port, protocol)

    runner.check(("ufw", "--force", "enable"), "could not enable UFW")
    status_result = runner.run(("ufw", "status", "verbose"))
    ufw_status = _output(status_result.output, "could not read UFW status after enabling", status_result.returncode)
    if "Status: active" not in ufw_status:
        raise ApplyFailure("UFW did not become active")

    for unit in OPTIONAL_UNITS:
        _disable_unit(runner, unit)
    wpa_result = runner.run(("systemctl", "list-units", "--all", "--no-legend", "wpa_supplicant@*.service"))
    wpa_instances = _output(wpa_result.output, "could not inspect wpa_supplicant instances", wpa_result.returncode)
    for unit in parse_unit_names(wpa_instances):
        _disable_unit(runner, unit)

    rfkill_result = runner.run(("rfkill", "list"))
    rfkill_output = _output(rfkill_result.output, "rfkill could not list radio devices", rfkill_result.returncode)
    for kind, command, label in (
        ("Wireless LAN", "wifi", "Wi-Fi"),
        ("Bluetooth", "bluetooth", "Bluetooth"),
    ):
        if has_rfkill_device(rfkill_output, kind):
            result = runner.run(("rfkill", "block", command))
            _output(result.output, f"could not block {label}", result.returncode)
            print(f"hardening: {label} soft-blocked")
        else:
            print(f"hardening: no {label} rfkill device found")

    if wifi_scope == "absent" or bt_scope == "absent":
        backup = Path(str(boot_config) + ".homelab-hardening.bak")
        if not backup.exists():
            shutil.copy2(boot_config, backup)
            print(f"hardening: created boot config backup {backup}")
        else:
            print(f"hardening: preserving existing boot config backup {backup}")
        with boot_config.open("a", encoding="utf-8") as stream:
            stream.write("\n[all]\n")
            if wifi_scope == "absent":
                stream.write("dtoverlay=disable-wifi\n")
                print("hardening: appended unconditional dtoverlay=disable-wifi")
            if bt_scope == "absent":
                stream.write("dtoverlay=disable-bt\n")
                print("hardening: appended unconditional dtoverlay=disable-bt")
    else:
        print("hardening: boot overlays already present in an unconditional section")

    if not has_exact_line(ufw_status, "Default: deny (incoming), allow (outgoing), deny (routed)"):
        raise ApplyFailure("UFW defaults are not deny incoming, allow outgoing, deny routed")
    if not has_exact_line(ufw_status, "Logging: low"):
        raise ApplyFailure("UFW logging is not low")
    for port, protocol in ALLOWED_RULES:
        if not status_has_rule(ufw_status, port, protocol):
            raise ApplyFailure(f"exact IPv4 and IPv6 UFW allow rules are missing for {port}/{protocol} on tailscale0")
    configured = _configured_rules(runner)
    _check_configured_rules(configured)
    print("hardening: complete; reboot is intentionally not performed")
    return 0


def main() -> int:
    try:
        return apply()
    except (ApplyFailure, CommandError, OSError) as exc:
        print(f"hardening: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
