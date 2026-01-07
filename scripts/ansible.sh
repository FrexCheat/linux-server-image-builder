#!/usr/bin/env bash

set -euo pipefail

green='\033[0;32m'
red='\033[0;31m'
yellow='\033[0;33m'
reset='\033[0m'

info() {
    echo -e "${green}$1${reset}"
}

warn() {
    echo -e "${yellow}$1${reset}" >&2
}

error() {
    echo -e "${red}$1${reset}" >&2
}

init_env() {
    unset JAVA_HOME
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

if [ $# -ne 1 ]; then
    error "Usage: $0 <debootstrap directory>"
    exit 1
fi

init_env

BASEROOTFS=$1; shift
DESTROOTFS=$(mktemp -d "/tmp/ubuntu-noble-rootfs.XXXXXX")
CACHEDIR=/var/cache/debootstrap

mount_all() {
    info "Mounting temporary debootstrap root filesystem $DESTROOTFS..."

    mkdir -p "$DESTROOTFS"
    mount -o bind "$BASEROOTFS" "$DESTROOTFS"
    mount -t proc /proc "$DESTROOTFS/proc"
    mount -t sysfs /sys "$DESTROOTFS/sys"

    if [ ! -d "/sys/firmware/efi/efivars" ]; then
        warn "EFI variables not found on host system, skipping efivarfs mount..."
    else
        mount -t efivarfs -o ro efivarfs "$DESTROOTFS/sys/firmware/efi/efivars" || warn "Failed to mount efivarfs, continuing without it..."
    fi

    find "$DESTROOTFS/run" -mindepth 1 -delete || true
    mount -t tmpfs tmpfs "$DESTROOTFS/tmp"
    mount -t tmpfs tmpfs "$DESTROOTFS/run"
    mkdir -p "$DESTROOTFS/run/systemd/resolve"
    mkdir -p "$DESTROOTFS/var/cache/apt/archives"
    mount -o bind $CACHEDIR "$DESTROOTFS/var/cache/apt/archives"
    touch "$DESTROOTFS/run/systemd/resolve/stub-resolv.conf"
    cp /etc/resolv.conf "$DESTROOTFS/run/systemd/resolve/stub-resolv.conf" || warn "Failed to copy resolv.conf, DNS may not work inside chroot"
}

cleanup() {
    info "Cleaning up..."

    if [ -d "$DESTROOTFS" ]; then
        info "Unmounting temporary root filesystem $DESTROOTFS..."
        umount -R "$DESTROOTFS" || true
    fi

    if [ -d "$DESTROOTFS" ]; then
        info "Removing temporary root filesystem directory $DESTROOTFS..."
        rmdir "$DESTROOTFS" || true
    fi

    info "Clean up completed successfully"
}

# ====================Start Ansible provisioning process=====================

mount_all

INVENTORY_FILE=$(mktemp)

trap cleanup EXIT

cat <<EOF > "$INVENTORY_FILE"
[vm]
$DESTROOTFS ansible_connection=chroot
EOF

ansible-playbook -i "$INVENTORY_FILE" --diff playbook.yml "$@"

rm -f "$INVENTORY_FILE"

info "Ansible provisioning completed successfully"
