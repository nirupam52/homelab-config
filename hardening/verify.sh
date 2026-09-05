#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL

# This script only checks local state. It never changes firewall, services, or boot files.

failures=0

fail_check() {
    printf 'verify: FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'verify: required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'verify: run as root (use sudo)' >&2
    exit 1
fi

for command_name in awk grep id ip rfkill ss systemctl tailscale ufw; do
    require_command "$command_name"
done

if [ -f /boot/firmware/config.txt ]; then
    boot_config=/boot/firmware/config.txt
elif [ -f /boot/config.txt ]; then
    boot_config=/boot/config.txt
else
    printf '%s\n' 'verify: supported boot config not found (/boot/firmware/config.txt or /boot/config.txt)' >&2
    exit 1
fi

# Match the same unconditional [all] overlay rule that apply.sh manages.
overlay_scope() {
    overlay=$1
    awk -v overlay="$overlay" '
        BEGIN { section = "all"; any = 0; unconditional = 0 }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            section = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
            next
        }
        $0 ~ "^[[:space:]]*dtoverlay=" overlay "([,[:space:]].*)?[[:space:]]*$" {
            any = 1
            if (section == "all" || section == "[all]") {
                unconditional = 1
            }
        }
        END {
            if (unconditional) print "unconditional"
            else if (any) print "conditional"
            else print "absent"
        }
    ' "$boot_config"
}

# UFW's saved rules are checked separately from its active status so disabled UFW is still audited.
check_configured_ufw_rules() {
    if configured_rules=$(ufw show added 2>&1); then
        :
    else
        printf '%s\n' "$configured_rules" >&2
        fail_check 'could not read configured UFW rules'
        return
    fi
    unexpected_rules=$(printf '%s\n' "$configured_rules" | awk '
        $0 == "ufw allow in on tailscale0 to any port 22 proto tcp" { next }
        $0 == "ufw allow in on tailscale0 to any port 53 proto tcp" { next }
        $0 == "ufw allow in on tailscale0 to any port 53 proto udp" { next }
        $0 == "ufw allow in on tailscale0 to any port 443 proto tcp" { next }
        $0 == "ufw allow in on tailscale0 to any port 8443 proto tcp" { next }
        /^ufw / { print }
    ')
    if [ -n "$unexpected_rules" ]; then
        printf '%s\n' "$unexpected_rules" >&2
        fail_check 'unexpected UFW rules exist outside the Tailscale-only allowlist'
    else
        printf '%s\n' 'verify: OK: configured UFW rules are limited to the Tailscale allowlist'
    fi
}

# Check an exact IPv4 and IPv6 UFW status row, not a loose substring.
status_has_rule() {
    port=$1
    protocol=$2
    printf '%s\n' "$ufw_status" | awk -v port="$port" -v protocol="$protocol" '
        $1 == port "/" protocol && $2 == "on" && $3 == "tailscale0" && $4 == "ALLOW" && $5 == "IN" { ipv4 = 1 }
        $1 == port "/" protocol && $2 == "(v6)" && $3 == "on" && $4 == "tailscale0" && $5 == "ALLOW" && $6 == "IN" { ipv6 = 1 }
        END { exit !(ipv4 && ipv6) }
    '
}

printf '%s\n' '== UFW status and rules =='
if ufw_status=$(ufw status verbose 2>&1); then
    :
else
    printf '%s\n' "$ufw_status"
    fail_check 'could not read UFW status'
fi
printf '%s\n' "$ufw_status"
case "$ufw_status" in
    *"Status: active"*) ;;
    *) fail_check 'UFW is not active' ;;
esac
if printf '%s\n' "$ufw_status" | awk '$0 == "Default: deny (incoming), allow (outgoing), deny (routed)" { found = 1 } END { exit !found }'; then
    :
else
    fail_check 'UFW defaults are not deny incoming, allow outgoing, deny routed'
fi
if printf '%s\n' "$ufw_status" | awk '$0 == "Logging: low" { found = 1 } END { exit !found }'; then
    :
else
    fail_check 'UFW logging is not low'
fi
if grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*yes[[:space:]]*(#.*)?$' /etc/default/ufw; then
    printf '%s\n' 'verify: OK: UFW IPv6 support is enabled'
else
    fail_check 'UFW IPv6 support is not enabled in /etc/default/ufw'
fi

for rule_spec in "22 tcp" "53 tcp" "53 udp" "443 tcp" "8443 tcp"; do
    rule_port=${rule_spec% *}
    rule_protocol=${rule_spec#* }
    if status_has_rule "$rule_port" "$rule_protocol"; then
        printf 'verify: OK: exact IPv4 and IPv6 rule for %s/%s on tailscale0\n' "$rule_port" "$rule_protocol"
    else
        fail_check "missing exact IPv4 and IPv6 UFW rule for $rule_port/$rule_protocol on tailscale0"
    fi
done
check_configured_ufw_rules

# Treat systemd query failures as failures; only a confirmed absent unit is skipped.
unit_exists() {
    unit=$1
    if unit_files=$(systemctl list-unit-files --no-legend "$unit" 2>&1); then
        :
    else
        return 2
    fi
    if printf '%s\n' "$unit_files" | awk -v unit="$unit" '$1 == unit { found = 1 } END { exit !found }'; then
        return 0
    fi
    if loaded_units=$(systemctl list-units --all --no-legend "$unit" 2>&1); then
        :
    else
        return 2
    fi
    if printf '%s\n' "$loaded_units" | awk -v unit="$unit" '$1 == unit { found = 1 } END { exit !found }'; then
        return 0
    fi
    return 1
}

check_unit_disabled() {
    unit=$1
    enabled_state=$(systemctl is-enabled "$unit" 2>&1 || true)
    active_state=$(systemctl is-active "$unit" 2>&1 || true)
    printf '%s: enabled=%s active=%s\n' "$unit" "$enabled_state" "$active_state"
    case "$enabled_state" in
        enabled|enabled-runtime|linked|linked-runtime|alias)
            fail_check "$unit is enabled"
            ;;
        disabled|static|indirect|generated|transient|masked|not-found)
            ;;
        *)
            fail_check "could not determine enabled state for $unit"
            ;;
    esac
    case "$active_state" in
        active|activating|reloading)
            fail_check "$unit is active"
            ;;
        inactive|failed|deactivating|dead|unknown|not-found)
            ;;
        *)
            fail_check "could not determine active state for $unit"
            ;;
    esac
}

printf '%s\n' '== Relevant unit states =='
for unwanted_unit in \
    ssh.service \
    ssh.socket \
    sshd.service \
    sshd.socket \
    avahi-daemon.service \
    avahi-daemon.socket \
    sshswitch.service \
    bluetooth.service \
    wpa_supplicant.service \
    wpa_supplicant.socket; do
    if unit_exists "$unwanted_unit"; then
        check_unit_disabled "$unwanted_unit"
    else
        unit_result=$?
        case "$unit_result" in
            1) printf '%s: absent (expected optional unit)\n' "$unwanted_unit" ;;
            *) fail_check "could not inspect $unwanted_unit" ;;
        esac
    fi
done

if wpa_instances=$(systemctl list-units --all --no-legend 'wpa_supplicant@*.service' 2>&1); then
    :
else
    printf '%s\n' "$wpa_instances" >&2
    fail_check 'could not inspect wpa_supplicant instances'
    wpa_instances=''
fi
wpa_instance_names=$(printf '%s\n' "$wpa_instances" | awk '$1 ~ /^wpa_supplicant@.+\.service$/ { print $1 }')
if [ -n "$wpa_instance_names" ]; then
    for wpa_unit in $wpa_instance_names; do
        check_unit_disabled "$wpa_unit"
    done
else
    printf '%s\n' 'wpa_supplicant instances: absent (expected optional unit)'
fi

printf '%s\n' '== Boot overlay state =='
for overlay in disable-wifi disable-bt; do
    overlay_state=$(overlay_scope "$overlay")
    printf '%s: %s\n' "$overlay" "$overlay_state"
    case "$overlay_state" in
        unconditional) ;;
        conditional) fail_check "$overlay is only configured under a conditional boot section" ;;
        absent) fail_check "$overlay is missing from $boot_config" ;;
        *) fail_check "could not determine $overlay state" ;;
    esac
done

printf '%s\n' '== rfkill list =='
rfkill_ok=1
if rfkill_output=$(rfkill list 2>&1); then
    rfkill_ok=0
else
    printf '%s\n' "$rfkill_output" >&2
    fail_check 'rfkill could not list radio devices'
    rfkill_output=''
fi
printf '%s\n' "$rfkill_output"
if [ "$rfkill_ok" -eq 0 ]; then
    if [ -n "$rfkill_output" ]; then
        case "$rfkill_output" in
            *"Soft blocked: no"*) fail_check 'an rfkill device is not soft-blocked' ;;
            *) printf '%s\n' 'verify: OK: listed rfkill devices are soft-blocked' ;;
        esac
    else
        printf '%s\n' 'verify: OK: no rfkill devices (expected after disabling Wi-Fi and Bluetooth)'
    fi
fi

if ip link show dev tailscale0 >/dev/null 2>&1; then
    printf '%s\n' 'verify: OK: tailscale0 is available'
else
    fail_check 'tailscale0 is not available'
fi

printf '%s\n' '== Listening sockets =='
ss_ok=1
if ss_output=$(ss -lntup 2>&1); then
    ss_ok=0
else
    printf '%s\n' "$ss_output" >&2
    fail_check 'ss could not enumerate listening sockets'
    ss_output=''
fi
printf '%s\n' "$ss_output"
if [ "$ss_ok" -eq 0 ]; then
    case "$ss_output" in
        *sshd*|*avahi-daemon*) fail_check 'ss shows an unwanted sshd or Avahi listener' ;;
        *) printf '%s\n' 'verify: OK: no sshd or Avahi listener found' ;;
    esac
fi

printf '%s\n' '== Tailscale Serve status =='
if serve_status=$(tailscale serve status 2>&1); then
    printf '%s\n' "$serve_status"
else
    printf '%s\n' "$serve_status" >&2
    printf '%s\n' 'verify: WARN: could not read Tailscale Serve status; check it after configuring Serve' >&2
fi

if [ "$failures" -ne 0 ]; then
    printf 'verify: %s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf '%s\n' 'verify: all local hardening checks passed'
