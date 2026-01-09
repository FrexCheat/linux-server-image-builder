#!/bin/bash

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

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ===================== Global Variables =====================

TARGET="/mnt/target"
DISK=""
EFI=false
PARTITION1=""
PARTITION2=""

# ===================== GPT Partition Type UUIDs =====================

declare -A PART_TYPE_UUID=(
    [efi]="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    [bios_grub]="21686148-6449-6E6F-744E-656564454649"
    [linux_x86_64]="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"
    [linux_x86]="44479540-F297-41B2-9AF7-D131D5F0458A"
    [linux_arm64]="B921B045-1DF0-41C3-AF44-4C6F280D3FAE"
    [linux_generic]="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
)

get_root_type_uuid() {
    case "$(uname -m)" in
        x86_64)  echo "${PART_TYPE_UUID[linux_x86_64]}" ;;
        i?86)    echo "${PART_TYPE_UUID[linux_x86]}" ;;
        aarch64) echo "${PART_TYPE_UUID[linux_arm64]}" ;;
        *)       echo "${PART_TYPE_UUID[linux_generic]}" ;;
    esac
}

# ===================== Utility Functions =====================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "===> Please run as root"
        exit 1
    fi
}

detect_boot_mode() {
    if [ -d /sys/firmware/efi ]; then
        EFI=true
        info "===> Detected UEFI system"
    else
        EFI=false
        info "===> Detected BIOS system"
    fi
}

get_partition_dev() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ nvme|mmcblk|loop ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

countdown() {
    local seconds="$1"
    local prompt="$2"
    local confirm_key="${3:-y}"

    for ((i=seconds; i>0; i--)); do
        printf "\r%s" "$prompt ($i s) [${confirm_key}/n]: "
        if read -t 1 -n 1 key; then
            echo
            case "$key" in
                "$confirm_key"|"${confirm_key^}") return 0 ;;
                n|N) return 1 ;;
            esac
        fi
    done
    echo
    return 0
}

# ===================== Disk Selection =====================

list_available_disks() {
    local disks=()
    while read -r name type; do
        [ "$type" = "disk" ] || continue
        disks+=("/dev/$name")
    done < <(lsblk -ndo NAME,TYPE)
    echo "${disks[@]}"
}

select_disk_auto() {
    local disks=($(list_available_disks))
    
    if [ ${#disks[@]} -eq 0 ]; then
        error "===> No available disks found!"
        return 1
    fi
    
    DISK="${disks[0]}"
    info "===> Auto selected disk: $DISK$(lsblk -ndo SIZE "$DISK")"
}

select_disk_manual() {
    local disks=($(list_available_disks))
    
    if [ ${#disks[@]} -eq 0 ]; then
        error "===> No available disks found!"
        return 1
    fi
    
    echo
    info "===> Available disks:"
    printf "%-15s %-10s %s\n" "DEVICE" "SIZE" "MODEL"
    for dev in "${disks[@]}"; do
        printf "%-15s %-10s %s\n" \
            "$dev" \
            "$(lsblk -ndo SIZE "$dev")" \
            "$(lsblk -ndo MODEL "$dev" 2>/dev/null || echo "-")"
    done
    echo
    
    while true; do
        read -rp "Enter disk (e.g., sda or /dev/sda): " input
        input="/dev/${input#/dev/}"
        
        if [ -b "$input" ]; then
            DISK="$input"
            break
        else
            error "===> Invalid disk: $input"
        fi
    done
}

# ===================== Partition Functions =====================

show_partition_plan() {
    local root_uuid=$(get_root_type_uuid)
    echo
    info "============================== Partition Plan =============================="
    echo "Disk: $DISK$(lsblk -ndo SIZE "$DISK")"
    echo "Table: GPT"
    echo
    printf "%-4s %-12s %-10s %-10s %s\n" "NUM" "SIZE" "TYPE" "FORMAT" "TYPE UUID"
    echo "---------------------------------------------------------------"
    
    if $EFI; then
        printf "%-4s %-12s %-10s %-10s %s\n" "1" "300MB" "EFI" "FAT32" "${PART_TYPE_UUID[efi]}"
        printf "%-4s %-12s %-10s %-10s %s\n" "2" "Remaining" "Linux" "ext4" "$root_uuid"
    else
        printf "%-4s %-12s %-10s %-10s %s\n" "1" "1MB" "BIOS Boot" "-" "${PART_TYPE_UUID[bios_grub]}"
        printf "%-4s %-12s %-10s %-10s %s\n" "2" "Remaining" "Linux" "ext4" "$root_uuid"
    fi
    echo
    warn "WARNING: All data on $DISK will be destroyed!"
    info "============================================================================="
    echo
}

create_partitions() {
    local root_uuid=$(get_root_type_uuid)
    
    info "===> Creating partitions on $DISK..."
    
    parted --script "$DISK" mklabel gpt
    
    if $EFI; then
        parted --script "$DISK" \
            mkpart "EFI" fat32 1MiB 301MiB \
            set 1 esp on \
            mkpart "Linux" ext4 301MiB 100% \
            type 1 "${PART_TYPE_UUID[efi]}" \
            type 2 "$root_uuid"
    else
        parted --script "$DISK" \
            mkpart "BIOS" 1MiB 2MiB \
            set 1 bios_grub on \
            mkpart "Linux" ext4 2MiB 100% \
            type 1 "${PART_TYPE_UUID[bios_grub]}" \
            type 2 "$root_uuid"
    fi
    
    sleep 2
    partprobe "$DISK"
    sleep 1
    
    PARTITION1=$(get_partition_dev "$DISK" 1)
    PARTITION2=$(get_partition_dev "$DISK" 2)
}

format_partitions() {
    info "===> Formatting partitions..."
    
    if $EFI; then
        info "===> $PARTITION1 -> FAT32"
        mkfs.fat -I -F32 "$PARTITION1"
    fi
    
    info "===> $PARTITION2 -> ext4"
    mkfs.ext4 -F "$PARTITION2"
}

# ===================== Extract Rootfs Functions =====================

mount_target() {
    info "===> Mounting target partitions..."

    mount -t tmpfs tmpfs /mnt
    mkdir -p $TARGET
    mount "$PARTITION2" "$TARGET"
    if $EFI; then
        mkdir -p "$TARGET/boot/efi"
        mount "$PARTITION1" "$TARGET/boot/efi"
    fi
    mkdir -p /dev/shm
    mount -t tmpfs tmpfs /dev/shm
}

unmount_target() {
    info "===> Unmounting target partitions..."
    umount --recursive "$TARGET" || warn "===> Warning: Failed to unmount target partitions. Continuing..."
    sync
}

rsync_rootfs() {
    info "===> Syncing root filesystem to target..."

    rsync -aHAXS \
        --exclude="/boot/grub/*" \
        --exclude="/EFI/" \
        --exclude="/tmp/*" \
        --exclude="/proc/*" \
        --exclude="/sys/*" \
        --exclude="/dev/*" \
        --exclude="/run/*" \
        --exclude="/mnt/*" \
        --exclude="/media/*" \
        --exclude="/opt/init.sh" \
        --exclude="/opt/autodeploy.sh" \
        --exclude="/root/.ansible/" \
        / "$TARGET/"
    sed -i '/# ==== Auto-deploy toolkit block begin ====/,/# ==== Auto-deploy toolkit block end ====/d' "$TARGET/etc/bash.bashrc"
    sync
}

# ==================== Chroot Functions =====================

in_target() {
    arch-chroot "$TARGET" "$@"
}

gen_fstab() {
    info "===> Generating fstab..."
    local root_uuid=$(blkid -s UUID -o value $PARTITION2)

    touch $TARGET/etc/fstab
    cat > "$TARGET/etc/fstab" <<EOF
# Auto-generated by auto deployment toolkit: $(date --rfc-3339=seconds)
# <file system> <mount point> <type> <options> <dump> <pass>
UUID=$root_uuid    /    ext4    errors=remount-ro    0    1
EOF

    if $EFI; then
        local efi_uuid=$(blkid -s UUID -o value $PARTITION1)
        cat >> "$TARGET/etc/fstab" <<EOF
UUID=$efi_uuid    /boot/efi    vfat    umask=0077    0    1
EOF
    fi
}

install_bootloader() {
    info "===> Installing GRUB bootloader..."

    if $EFI; then
        in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Ubuntu
    else
        in_target grub-install --target=i386-pc $DISK
    fi

    in_target update-grub
    in_target apt-get clean
}

# ===================== Deployment Block =====================

echo "═════════════════════════════════════════════════════════════════════════════════════════════════════════════"
echo "                                                                                                             "
echo "██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗    ████████╗ ██████╗  ██████╗ ██╗     ██╗  ██╗██╗████████╗"
echo "██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██║ ██╔╝██║╚══██╔══╝"
echo "██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝        ██║   ██║   ██║██║   ██║██║     █████╔╝ ██║   ██║   "
echo "██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝         ██║   ██║   ██║██║   ██║██║     ██╔═██╗ ██║   ██║   "
echo "██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║          ██║   ╚██████╔╝╚██████╔╝███████╗██║  ██╗██║   ██║   "
echo "╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝          ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝   ╚═╝   "
echo "                                                                                                             "
echo "  Author: Frex & Charles          Version: 1.0-ubuntu-noble          Date: 2026-01-08          LICENSE: MIT  "
echo "═════════════════════════════════════════════════════════════════════════════════════════════════════════════"

main() {
    check_root
    detect_boot_mode

    if countdown 10 "Start automated deployment?" "y"; then
        if countdown 10 "Use automatic disk selection?" "y"; then
            select_disk_auto || exit 1
        else
            select_disk_manual || exit 1
        fi
    else
        exit 1
    fi

    show_partition_plan

    if ! countdown 10 "Proceed with partitioning?" "y"; then
        error "===> Cancelled by user."
        exit 1
    fi

    create_partitions
    format_partitions

    info "===> Partitioning completed!"
    echo
    parted "$DISK" print

    mount_target
    rsync_rootfs
    gen_fstab
    install_bootloader
    unmount_target
}

trap '' EXIT

main "$@"

info "===> Auto Deployment completed successfully!"

for i in {10..1}; do
    echo -ne "\rThe system will now reboot in $i seconds."
    sleep 1
done

echo -e "\nRebooting now..."
echo s > /proc/sysrq-trigger
echo u > /proc/sysrq-trigger
echo b > /proc/sysrq-trigger
