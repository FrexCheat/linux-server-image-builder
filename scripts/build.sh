#!/bin/bash

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

if [ $# -ne 2 ]; then
    error "Usage: $0 <path to rootfs> <ISO name>"
    exit 1
fi

ROOTFS="$1"
ISONAME="$2"
WORKDIR=$(mktemp -d "/tmp/ubuntu-noble-build.XXXXXX")
ISODIR="$WORKDIR/iso"
CD_BOOT_IMG="${CD_BOOT_IMG:-"/usr/share/cd-boot-images-amd64"}"

# ===================== Functions Block =====================

init_workdir() {
    info "Initializing working directory..."
    info "Sync rootfs to workdir..."
    rsync -aHAXS \
        --exclude="/proc/*" \
        --exclude="/sys/*" \
        --exclude="/dev/*" \
        --exclude="/run/*" \
        --exclude="/mnt/*" \
        --exclude="/tmp/*" \
        --exclude="/media/*" \
        --exclude="/root/.ansible/" \
        "$ROOTFS/" "$ISODIR/"
    rsync -a "$CD_BOOT_IMG/tree/" "$ISODIR/"
}

cleanup() {
    info "Cleaning up..."
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}

configure_grub() {
    info "Configuring GRUB bootloader..."
    cp ./grub/grub.cfg "$ISODIR/boot/grub/grub.cfg"
}

configure_auto_deploy() {
    info "Configuring auto deploy settings..."

    info "Configure auto deploy toolkit..."
    cp ./deploy/init.sh "$ISODIR/opt/init.sh"
    chmod +x "$ISODIR/opt/init.sh"

    cp ./deploy/autodeploy.sh "$ISODIR/opt/autodeploy.sh"
    cat >> "$ISODIR/etc/bash.bashrc" <<EOF
# ==== Auto-deploy toolkit block begin ====
if [ -f /opt/init.sh ]; then
    clear
    bash /opt/autodeploy.sh
fi
# ==== Auto-deploy toolkit block end ====
EOF
    chmod +x "$ISODIR/opt/autodeploy.sh"
}

create_iso() {
    info "Creating ISO image..."

    mkdir -p ./output
    xorriso -as mkisofs \
        -V "UBUNTU_NOBLE" \
        -iso-level 3 \
        -o "output/$ISONAME" \
        -J -joliet-long \
        -l -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        --grub2-mbr $CD_BOOT_IMG/images/boot/grub/i386-pc/boot_hybrid.img \
        -append_partition 2 0xef $CD_BOOT_IMG/images/boot/grub/efi.img \
        -appended_part_as_gpt --mbr-force-bootable \
        -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -partition_offset 16 -R \
        $ISODIR

    info "ISO created successfully at output/$ISONAME"
}

trap cleanup EXIT
init_workdir
configure_grub
configure_auto_deploy

create_iso

info "===> Build completed successfully."
