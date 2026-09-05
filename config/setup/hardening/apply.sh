#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL

# This script applies the small, host-level hardening policy for this Pi.
# It never installs packages, reboots, resets UFW, or removes packages.

usage() {
    printf '%s\n' "Usage: sudo sh apply.sh --tailscale-ssh-tested" >&2
    printf '%s\n' "The flag is required only after Tailscale SSH has been tested from another tailnet device." >&2
}

fail() {
    printf 'hardening: %s\n' "$1" >&2
    exit 1
}

# Require an explicit operator confirmation before changing SSH access.
if [ "$(id -u)" -ne 0 ]; then
    fail "run as root (use sudo)"
fi

if [ "$#" -ne 1 ] || [ "$1" != "--tailscale-ssh-tested" ]; then
    usage
    exit 2
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "required command not found: $1"
    fi
}

for command_name in awk cp grep id ip rfkill tailscale systemctl ufw; do
    require_command "$command_name"
done

# Refuse to continue if the Tailscale interface or IPv6 firewall support is missing.
if ! ip link show dev tailscale0 >/dev/null 2>&1; then
    fail "tailscale0 is not available; keep current access until Tailscale is connected"
fi
if [ ! -r /etc/default/ufw ]; then
    fail "UFW configuration not found at /etc/default/ufw"
fi
if ! grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*yes[[:space:]]*(#.*)?$' /etc/default/ufw; then
    fail "UFW IPv6 support is not enabled in /etc/default/ufw"
fi

if [ -f /boot/firmware/config.txt ]; then
    boot_config=/boot/firmware/config.txt
elif [ -f /boot/config.txt ]; then
    boot_config=/boot/config.txt
else
    fail "supported boot config not found (/boot/firmware/config.txt or /boot/config.txt)"
fi

# Return whether an overlay is absent, unconditional, or trapped in a conditional section.
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

# Do not create duplicate overlays or leave a conditional overlay looking effective.
wifi_overlay_scope=$(overlay_scope disable-wifi)
bt_overlay_scope=$(overlay_scope disable-bt)
case "$wifi_overlay_scope" in
    conditional) fail "disable-wifi exists under a conditional boot section; move it to [all] manually" ;;
esac
case "$bt_overlay_scope" in
    conditional) fail "disable-bt exists under a conditional boot section; move it to [all] manually" ;;
esac

# UFW rules are checked from its saved configuration, which also works while UFW is inactive.
check_configured_ufw_rules() {
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
        fail "unexpected UFW rules exist; review them manually instead of resetting UFW"
    fi
}

if configured_rules=$(ufw show added 2>&1); then
    :
else
    fail "could not read configured UFW rules: $configured_rules"
fi
check_configured_ufw_rules

ensure_ufw_rule() {
    port=$1
    protocol=$2
    rule_command="ufw allow in on tailscale0 to any port $port proto $protocol"
    if printf '%s\n' "$configured_rules" | awk -v expected="$rule_command" '$0 == expected { found = 1 } END { exit !found }'; then
        printf 'hardening: UFW rule already present: %s\n' "$rule_command"
    else
        printf 'hardening: adding UFW rule: %s\n' "$rule_command"
        ufw allow in on tailscale0 to any port "$port" proto "$protocol"
        if configured_rules=$(ufw show added 2>&1); then
            :
        else
            fail "could not reread configured UFW rules: $configured_rules"
        fi
        check_configured_ufw_rules
    fi
}

# Set the narrow default policy and permit only the intended tailnet service ports.
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw logging low
ensure_ufw_rule 22 tcp
ensure_ufw_rule 53 tcp
ensure_ufw_rule 53 udp
ensure_ufw_rule 443 tcp
ensure_ufw_rule 8443 tcp

# Turn on the firewall before stopping any other network service.
ufw --force enable

if ufw_status=$(ufw status verbose 2>&1); then
    :
else
    fail "could not read UFW status after enabling: $ufw_status"
fi
case "$ufw_status" in
    *"Status: active"*) ;;
    *) fail "UFW did not become active" ;;
esac

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
    case "$enabled_state" in
        enabled|enabled-runtime|linked|linked-runtime|alias)
            fail "$unit is still enabled ($enabled_state)"
            ;;
        disabled|static|indirect|generated|transient|masked|not-found)
            ;;
        *)
            fail "could not determine enabled state for $unit: $enabled_state"
            ;;
    esac

    active_state=$(systemctl is-active "$unit" 2>&1 || true)
    case "$active_state" in
        active|activating|reloading)
            fail "$unit is still active ($active_state)"
            ;;
        inactive|failed|deactivating|dead|unknown|not-found)
            ;;
        *)
            fail "could not determine active state for $unit: $active_state"
            ;;
    esac
}

disable_unit() {
    unit=$1
    if unit_exists "$unit"; then
        printf 'hardening: disabling/stopping %s\n' "$unit"
        if ! systemctl disable "$unit"; then
            fail "could not disable $unit"
        fi
        if ! systemctl stop "$unit"; then
            fail "could not stop $unit"
        fi
        check_unit_disabled "$unit"
    else
        unit_result=$?
        case "$unit_result" in
            1) printf 'hardening: optional unit absent, skipping %s\n' "$unit" ;;
            *) fail "could not inspect $unit" ;;
        esac
    fi
}

# Only these known unwanted services are touched; core networking stays enabled.
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
    disable_unit "$unwanted_unit"
done

# Handle any interface-specific Wi-Fi supplicant units without assuming an interface name.
if wpa_instances=$(systemctl list-units --all --no-legend 'wpa_supplicant@*.service' 2>&1); then
    :
else
    fail "could not inspect wpa_supplicant instances: $wpa_instances"
fi
wpa_instance_names=$(printf '%s\n' "$wpa_instances" | awk '$1 ~ /^wpa_supplicant@.+\.service$/ { print $1 }')
for wpa_unit in $wpa_instance_names; do
    disable_unit "$wpa_unit"
done

# Apply the runtime radio block when the kernel still exposes a radio device.
if rfkill_output=$(rfkill list 2>&1); then
    :
else
    fail "rfkill could not list radio devices: $rfkill_output"
fi
if printf '%s\n' "$rfkill_output" | awk '$0 ~ /^[0-9]+: .*Wireless LAN/ { found = 1 } END { exit !found }'; then
    if ! rfkill block wifi; then
        fail "could not block Wi-Fi"
    fi
    printf '%s\n' 'hardening: Wi-Fi soft-blocked'
else
    printf '%s\n' 'hardening: no Wi-Fi rfkill device found'
fi
if printf '%s\n' "$rfkill_output" | awk '$0 ~ /^[0-9]+: .*Bluetooth/ { found = 1 } END { exit !found }'; then
    if ! rfkill block bluetooth; then
        fail "could not block Bluetooth"
    fi
    printf '%s\n' 'hardening: Bluetooth soft-blocked'
else
    printf '%s\n' 'hardening: no Bluetooth rfkill device found'
fi

# Make the radio disablement persistent, preserving one recoverable backup.
need_boot_edit=0
if [ "$wifi_overlay_scope" = absent ]; then
    need_boot_edit=1
fi
if [ "$bt_overlay_scope" = absent ]; then
    need_boot_edit=1
fi

if [ "$need_boot_edit" -eq 1 ]; then
    boot_backup="${boot_config}.homelab-hardening.bak"
    if [ ! -e "$boot_backup" ]; then
        cp -p "$boot_config" "$boot_backup"
        printf 'hardening: created boot config backup %s\n' "$boot_backup"
    else
        printf 'hardening: preserving existing boot config backup %s\n' "$boot_backup"
    fi

    # [all] prevents existing conditional sections from hiding these overlays.
    printf '\n[all]\n' >> "$boot_config"
    if [ "$wifi_overlay_scope" = absent ]; then
        printf '%s\n' 'dtoverlay=disable-wifi' >> "$boot_config"
        printf '%s\n' 'hardening: appended unconditional dtoverlay=disable-wifi'
    fi
    if [ "$bt_overlay_scope" = absent ]; then
        printf '%s\n' 'dtoverlay=disable-bt' >> "$boot_config"
        printf '%s\n' 'hardening: appended unconditional dtoverlay=disable-bt'
    fi
else
    printf '%s\n' 'hardening: boot overlays already present in an unconditional section'
fi

# Recheck the final UFW policy after all local changes.
if printf '%s\n' "$ufw_status" | awk '$0 == "Default: deny (incoming), allow (outgoing), deny (routed)" { found = 1 } END { exit !found }'; then
    :
else
    fail "UFW defaults are not deny incoming, allow outgoing, deny routed"
fi
if printf '%s\n' "$ufw_status" | awk '$0 == "Logging: low" { found = 1 } END { exit !found }'; then
    :
else
    fail "UFW logging is not low"
fi

status_has_rule() {
    port=$1
    protocol=$2
    printf '%s\n' "$ufw_status" | awk -v port="$port" -v protocol="$protocol" '
        $1 == port "/" protocol && $2 == "on" && $3 == "tailscale0" && $4 == "ALLOW" && $5 == "IN" { ipv4 = 1 }
        $1 == port "/" protocol && $2 == "(v6)" && $3 == "on" && $4 == "tailscale0" && $5 == "ALLOW" && $6 == "IN" { ipv6 = 1 }
        END { exit !(ipv4 && ipv6) }
    '
}

for rule_spec in "22 tcp" "53 tcp" "53 udp" "443 tcp" "8443 tcp"; do
    rule_port=${rule_spec% *}
    rule_protocol=${rule_spec#* }
    if status_has_rule "$rule_port" "$rule_protocol"; then
        :
    else
        fail "exact IPv4 and IPv6 UFW allow rules are missing for $rule_port/$rule_protocol on tailscale0"
    fi
done

if configured_rules=$(ufw show added 2>&1); then
    :
else
    fail "could not reread configured UFW rules: $configured_rules"
fi
check_configured_ufw_rules

printf '%s\n' 'hardening: complete; reboot is intentionally not performed'
