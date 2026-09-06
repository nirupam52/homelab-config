"""Shared policy constants and pure state parsers for host hardening.

Nothing in this module reads or writes the host.  The apply and verify entry
points use these helpers so their policy checks cannot drift apart.
"""
from __future__ import annotations

import re

ALLOWED_RULES: tuple[tuple[str, str], ...] = (
    ("22", "tcp"),
    ("53", "tcp"),
    ("53", "udp"),
    ("443", "tcp"),
    ("8443", "tcp"),
)
ALLOWED_UFW_RULES = frozenset(
    f"ufw allow in on tailscale0 to any port {port} proto {protocol}"
    for port, protocol in ALLOWED_RULES
)
OPTIONAL_UNITS: tuple[str, ...] = (
    "ssh.service",
    "ssh.socket",
    "sshd.service",
    "sshd.socket",
    "avahi-daemon.service",
    "avahi-daemon.socket",
    "sshswitch.service",
    "bluetooth.service",
    "wpa_supplicant.service",
    "wpa_supplicant.socket",
)
ENABLED_STATES = frozenset({"enabled", "enabled-runtime", "linked", "linked-runtime", "alias"})
OK_ENABLED_STATES = frozenset(
    {"disabled", "static", "indirect", "generated", "transient", "masked", "not-found"}
)
ACTIVE_STATES = frozenset({"active", "activating", "reloading"})
OK_ACTIVE_STATES = frozenset(
    {"inactive", "failed", "deactivating", "dead", "unknown", "not-found"}
)

_OVERLAY_SECTION = re.compile(r"^\s*\[[^]]+\]\s*$")


def overlay_scope(text: str, overlay: str) -> str:
    """Return ``absent``, ``conditional``, or ``unconditional`` for an overlay.

    Boot configuration starts in the implicit all section.  Full-line comments
    are ignored, while inline comments on a dtoverlay line remain accepted as
    they are by the original shell implementation.
    """
    section = "all"
    any_match = False
    unconditional = False
    pattern = re.compile(r"^\s*dtoverlay=" + re.escape(overlay) + r"(?:[,\s].*)?\s*$")
    for raw_line in text.splitlines():
        if re.match(r"^\s*#", raw_line):
            continue
        if _OVERLAY_SECTION.match(raw_line):
            section = raw_line.strip()
            continue
        if pattern.match(raw_line):
            any_match = True
            if section in ("all", "[all]"):
                unconditional = True
    if unconditional:
        return "unconditional"
    if any_match:
        return "conditional"
    return "absent"




def unexpected_ufw_rules(configured: str) -> tuple[str, ...]:
    """Return saved UFW command lines outside the exact allowlist."""
    return tuple(
        line
        for line in configured.splitlines()
        if line.startswith("ufw ") and line not in ALLOWED_UFW_RULES
    )


def configured_rule(port: str, protocol: str) -> str:
    return f"ufw allow in on tailscale0 to any port {port} proto {protocol}"


def configured_has_rule(configured: str, port: str, protocol: str) -> bool:
    return configured_rule(port, protocol) in configured.splitlines()


def status_has_rule(status: str, port: str, protocol: str) -> bool:
    """Require exact IPv4 and IPv6 UFW status rows for one rule."""
    ipv4 = False
    ipv6 = False
    expected = f"{port}/{protocol}"
    for line in status.splitlines():
        fields = line.split()
        if fields[:5] == [expected, "on", "tailscale0", "ALLOW", "IN"]:
            ipv4 = True
        elif fields[:6] == [expected, "(v6)", "on", "tailscale0", "ALLOW", "IN"]:
            ipv6 = True
    return ipv4 and ipv6


def has_exact_line(text: str, expected: str) -> bool:
    return expected in text.splitlines()


def parse_unit_names(output: str, prefix: str = "wpa_supplicant@") -> tuple[str, ...]:
    """Parse systemctl --no-legend output, retaining valid first-column units."""
    pattern = re.compile(r"^" + re.escape(prefix) + r".+\.service$")
    return tuple(
        fields[0]
        for line in output.splitlines()
        if (fields := line.split()) and pattern.match(fields[0])
    )


def unit_enabled_ok(state: str) -> bool:
    return state in OK_ENABLED_STATES


def unit_active_ok(state: str) -> bool:
    return state in OK_ACTIVE_STATES


def unit_enabled_bad(state: str) -> bool:
    return state in ENABLED_STATES


def unit_active_bad(state: str) -> bool:
    return state in ACTIVE_STATES


def has_rfkill_device(output: str, kind: str) -> bool:
    pattern = re.compile(r"^[0-9]+: .*" + re.escape(kind) + r"(?:\s|$)")
    return any(pattern.match(line) for line in output.splitlines())


def all_rfkill_soft_blocked(output: str) -> bool:
    return "Soft blocked: no" not in output


def listening_has_unwanted(output: str) -> bool:
    return "sshd" in output or "avahi-daemon" in output
