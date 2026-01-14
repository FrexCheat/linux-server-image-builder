#!/bin/bash

green="\033[0;32m"
red="\033[0;31m"
yellow="\033[0;33m"
reset="\033[0m"

normal() {
    echo -e "$1" >&2
}

info() {
    echo -e "${green}$1${reset}" >&2
}

warn() {
    echo -e "${yellow}$1${reset}" >&2
}

error() {
    echo -e "${red}$1${reset}" >&2
}

confirm() {
    local prompt="$1"
    local default="${2:-Y}"
    local display_format
    local user_input

    if [[ "${default,,}" == "y" ]]; then
        display_format="[Y/n]"
        default="Y"
    else
        display_format="[y/N]"
        default="N"
    fi

    while true; do
        echo -n "$prompt $display_format: "
        read user_input
        if [[ -z "$user_input" ]]; then
            user_input="$default"
        fi

        if [[ -z "$user_input" ]]; then
            user_input="$default"
        fi

        case "${user_input,,}" in
        y | yes)
            return 0
            ;;
        n | no)
            return 1
            ;;
        *)
            error "Invalid input, please try again."
            ;;
        esac
    done
}

is_ipv4() {
    local ip="$1"
    [[ -n "$ip" ]] || return 1
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local a b c d
    IFS='.' read -r a b c d <<<"$ip"
    for o in "$a" "$b" "$c" "$d"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        ((o >= 0 && o <= 255)) || return 1
    done
    return 0
}

is_ipv4_cidr() {
    local cidr="$1"
    [[ -n "$cidr" ]] || return 1
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    is_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    ((prefix >= 0 && prefix <= 32)) || return 1
    return 0
}

select_interface() {
    local -a ifaces=()
    mapfile -t ifaces < <(ip -br link show | awk '{print $1}' | sed 's/@.*//' | grep -v '^lo$' || true)
    if [ ${#ifaces[@]} -eq 0 ]; then
        mapfile -t ifaces < <(ip -br link show | awk '{print $1}' | sed 's/@.*//' || true)
    fi

    while true; do
        info "Available interfaces:"
        for i in "${!ifaces[@]}"; do
            printf "  [%d] %s\n" $((i + 1)) "${ifaces[i]}" >&2
        done

        local choice
        read -rp "Select interface [1-${#ifaces[@]}]: " choice
        if [[ -z "$choice" ]]; then
            error "Interface selection cannot be empty."
            continue
        fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            error "Please enter a number."
            continue
        fi
        if ((choice < 1 || choice > ${#ifaces[@]})); then
            error "Out of range, please try again."
            continue
        fi
        echo "${ifaces[choice - 1]}"
        return 0
    done
}

select_mode() {
    while true; do
        info "Network mode:"
        normal "  [1] dhcp"
        normal "  [2] static"

        local choice
        read -rp "Select network mode [1-2]: " choice
        case "$choice" in
        1)
            echo "dhcp"
            return 0
            ;;
        2)
            echo "static"
            return 0
            ;;
        "") error "Mode selection cannot be empty." ;;
        *) error "Invalid selection, please try again." ;;
        esac
    done
}

prompt_ipv4_cidr() {
    local prompt="$1"
    local value
    while true; do
        read -rp "$prompt" value
        if [[ -z "$value" ]]; then
            error "Input cannot be empty."
            continue
        fi
        if ! is_ipv4_cidr "$value"; then
            error "Invalid IPv4 CIDR format, expected like 192.168.1.100/24"
            continue
        fi
        echo "$value"
        return 0
    done
}

prompt_ipv4() {
    local prompt="$1"
    local value
    while true; do
        read -rp "$prompt" value
        if [[ -z "$value" ]]; then
            error "Input cannot be empty."
            continue
        fi
        if ! is_ipv4 "$value"; then
            error "Invalid IPv4 address format, expected like 192.168.1.1"
            continue
        fi
        echo "$value"
        return 0
    done
}

clear
trap 'echo ""; exit' SIGINT

info "Ubuntu Noble Server Setup Script (V1.0)"

if [ -f /opt/setup_completed ]; then
    warn "Setup script has already been completed. Exiting."
    exit 0
fi

# ===================== Network Configuration =====================
normal "===> Starting network configuration..."

NETPLAN_CONFIG="/etc/netplan/99-setup-script.yaml"
INTERFACE="$(select_interface)"
MODE="$(select_mode)"

if [ "$MODE" = "static" ]; then
    IP_ADDRESS="$(prompt_ipv4_cidr "Enter the static IP-CIDR address (e.g., 192.168.1.100/24): ")"
    GATEWAY="$(prompt_ipv4 "Enter the gateway (e.g., 192.168.1.1): ")"
    DNS_SERVER="$(prompt_ipv4 "Enter the DNS server (e.g., 223.5.5.5): ")"
fi

normal "===> Generating netplan configuration at $NETPLAN_CONFIG..."

{
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    $INTERFACE:"
    if [ "$MODE" = "dhcp" ]; then
        echo "      dhcp4: true"
    else
        echo "      addresses:"
        echo "        - \"$IP_ADDRESS\""
        echo "      nameservers:"
        echo "        addresses:"
        echo "          - $DNS_SERVER"
        echo "      routes:"
        echo "        - to: \"default\""
        echo "          via: \"$GATEWAY\""
    fi
} >"$NETPLAN_CONFIG"

chmod 600 "$NETPLAN_CONFIG"

normal "===> Applying netplan configuration..."

netplan apply

info "===> Network configuration applied successfully."

# ===================== Hostname Configuration =====================
normal "===> Starting hostname configuration..."

while true; do
    read -rp "Enter the desired hostname: " NEW_HOSTNAME

    if [[ -z "$NEW_HOSTNAME" ]]; then
        error "Hostname cannot be empty."
        continue
    fi

    if [[ ${#NEW_HOSTNAME} -gt 63 ]]; then
        error "Hostname is too long (maximum 63 characters)."
        continue
    fi

    if [[ ! "$NEW_HOSTNAME" =~ ^([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9])$ ]]; then
        error "Invalid hostname format."
        warn "Rules: Only letters (a-z), digits (0-9), and hyphens (-) are allowed."
        warn "Note: Cannot start or end with a hyphen."
        continue
    fi

    break
done

normal "===> Setting hostname to '$NEW_HOSTNAME'..."

hostnamectl set-hostname "$NEW_HOSTNAME"

info "===> Hostname configured successfully."

# ===================== Set Fish Shell as Default =====================
normal "===> Starting set fish shell as default..."

chsh -s /usr/bin/fish

info "===> Fish shell set as default successfully."

# ===================== Change root password =====================
normal "===> Starting root password configuration..."

if confirm "Do you want to change the root password?"; then
    passwd root
    info "===> Root password configured successfully."
else
    warn "Skipping root password change."
fi

# ===================== APT Update and Upgrade =====================
normal "===> Starting APT update and upgrade..."

apt update && apt upgrade -y

info "===> APT update and upgrade completed successfully."

# ===================== Finalization =====================
touch /opt/setup_completed

info "Setup completed successfully. Press Ctrl+C to cancel the script if needed."

for i in {10..1}; do
    echo -ne "\r${yellow}System will reboot to apply all changes in $i seconds.${reset}"
    sleep 1
done

echo ""
normal "Rebooting now..."

reboot
