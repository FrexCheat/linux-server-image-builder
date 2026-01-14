#!/bin/bash

green="\033[0;32m"
red="\033[0;31m"
yellow="\033[0;33m"
reset="\033[0m"

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

TARGET="/tmp/target"
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
    x86_64) echo "${PART_TYPE_UUID[linux_x86_64]}" ;;
    i?86) echo "${PART_TYPE_UUID[linux_x86]}" ;;
    aarch64) echo "${PART_TYPE_UUID[linux_arm64]}" ;;
    *) echo "${PART_TYPE_UUID[linux_generic]}" ;;
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
    if [[ $disk =~ nvme|mmcblk|loop ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

confirm_with_timeout() {
    local prompt="$1"
    local timeout="$2"
    local default="${3:-Y}"
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
        echo -n "$prompt $display_format (${timeout}s): "
        if ! read -t "$timeout" user_input; then
            echo ""
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
            echo "Invalid input, please try again."
            ;;
        esac
    done
}

# ===================== Disk Selection =====================

list_available_disks() {
    local disks=()
    while read -r name type; do
        [ $type = "disk" ] || continue
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
    info "===> Auto selected disk: $DISK$(lsblk -ndo SIZE $DISK)"
}

select_disk_manual() {
    local disks=($(list_available_disks))

    if [ ${#disks[@]} -eq 0 ]; then
        error "===> No available disks found!"
        return 1
    fi

    echo ""
    info "===> Available disks:"
    printf "%-15s %-10s %s\n" "DEVICE" "SIZE" "MODEL"
    for dev in "${disks[@]}"; do
        printf "%-15s %-10s %s\n" "$dev" "$(lsblk -ndo SIZE "$dev")" "$(lsblk -ndo MODEL "$dev" 2>/dev/null || echo "-")"
    done
    echo ""

    while true; do
        read -rp "Enter disk (e.g., sda or /dev/sda): " input
        input="/dev/${input#/dev/}"
        if [ -b $input ]; then
            DISK=$input
            break
        else
            error "===> Invalid disk: $input"
        fi
    done
}

# ===================== Partition Functions =====================

show_partition_plan() {
    local root_uuid=$(get_root_type_uuid)
    local total_bytes=$(lsblk -bndo SIZE $DISK)
    local used_bytes
    if $EFI; then
        used_bytes=$((300 * 1024 * 1024))
    else
        used_bytes=$((1 * 1024 * 1024))
    fi
    local remaining_bytes=$((total_bytes - used_bytes))
    local remaining_size=$(numfmt --to=iec-i --suffix=B $remaining_bytes)
    echo
    info "============================== Partition Plan =============================="
    echo "Disk: $DISK$(lsblk -ndo SIZE $DISK)"
    echo "Table: GPT"
    echo
    printf "%-4s %-12s %-10s %-10s %s\n" "NUM" "SIZE" "TYPE" "FORMAT" "TYPE UUID"
    echo "---------------------------------------------------------------"

    if $EFI; then
        printf "%-4s %-12s %-10s %-10s %s\n" "1" "300MB" "EFI" "FAT32" "${PART_TYPE_UUID[efi]}"
        printf "%-4s %-12s %-10s %-10s %s\n" "2" "$remaining_size" "Linux" "ext4" "$root_uuid"
    else
        printf "%-4s %-12s %-10s %-10s %s\n" "1" "1MB" "BIOS Boot" "-" "${PART_TYPE_UUID[bios_grub]}"
        printf "%-4s %-12s %-10s %-10s %s\n" "2" "$remaining_size" "Linux" "ext4" "$root_uuid"
    fi
    echo
    warn "WARNING: All data on $DISK will be destroyed!"
    info "============================================================================="
    echo
}

create_partitions() {
    local root_uuid=$(get_root_type_uuid)

    info "===> Creating partitions on $DISK..."

    parted --script $DISK mklabel gpt

    if $EFI; then
        parted --script $DISK mkpart "EFI" fat32 1MiB 301MiB
        parted --script $DISK set 1 esp on
        parted --script $DISK mkpart "Linux" ext4 301MiB 100%
        parted --script $DISK type 2 "$root_uuid"
    else
        parted --script $DISK mkpart "BIOS" 1MiB 2MiB
        parted --script $DISK set 1 bios_grub on
        parted --script $DISK mkpart "Linux" ext4 2MiB 100%
        parted --script $DISK type 2 "$root_uuid"
    fi

    sleep 2
    partprobe $DISK
    sleep 1

    PARTITION1=$(get_partition_dev $DISK 1)
    PARTITION2=$(get_partition_dev $DISK 2)
}

format_partitions() {
    info "===> Formatting partitions..."

    if $EFI; then
        info "===> $PARTITION1 -> FAT32"
        mkfs.fat -I -F32 $PARTITION1
    fi

    info "===> $PARTITION2 -> ext4"
    mkfs.ext4 -F $PARTITION2
}

# ===================== Extract Rootfs Functions =====================

mount_target() {
    info "===> Mounting target partitions..."
    mkdir -p /dev/shm
    mount -t tmpfs tmpfs /tmp
    mount -t tmpfs tmpfs /run
    mount -t tmpfs tmpfs /dev/shm
    mkdir -p $TARGET
    mount $PARTITION2 $TARGET
    if $EFI; then
        mkdir -p $TARGET/boot/efi
        mount $PARTITION1 $TARGET/boot/efi
    fi
}

unmount_target() {
    info "===> Unmounting target partitions..."
    umount -R $TARGET || warn "===> Warning: Failed to unmount target partitions. Continuing..."
    umount -R /tmp || warn "===> Warning: Failed to unmount /tmp. Continuing..."
    umount -R /run || warn "===> Warning: Failed to unmount /run. Continuing..."
    umount -R /dev/shm || warn "===> Warning: Failed to unmount /dev/shm. Continuing..."
    sync
}

rsync_rootfs() {
    info "===> Syncing root filesystem to target..."

    rsync -aHAXS \
        --exclude="/boot/grub/" \
        --exclude="/EFI/" \
        --exclude="/tmp/*" \
        --exclude="/proc/*" \
        --exclude="/sys/*" \
        --exclude="/dev/*" \
        --exclude="/run/*" \
        --exclude="/mnt/*" \
        --exclude="/media/*" \
        --exclude="/lost+found/" \
        --exclude="/opt/init.sh" \
        --exclude="/opt/autodeploy.sh" \
        --exclude="/root/.ansible/" \
        / $TARGET/
    sed -i '/# ==== Auto-deploy toolkit block begin ====/,/# ==== Auto-deploy toolkit block end ====/d' $TARGET/etc/bash.bashrc
    sync
}

# ==================== Chroot Functions =====================

in_target() {
    arch-chroot $TARGET "$@"
}

gen_fstab() {
    info "===> Generating fstab..."
    touch "$TARGET/etc/fstab"
    local root_uuid=$(blkid -s UUID -o value $PARTITION2)
    local efi_uuid=$(blkid -s UUID -o value $PARTITION1)
    cat >"$TARGET/etc/fstab" <<EOF
UUID=$root_uuid  /  ext4  defaults  0  1
EOF
    if $EFI; then
        cat >>"$TARGET/etc/fstab" <<EOF
UUID=$efi_uuid  /boot/efi  vfat  defaults  0  1
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
}

# ===================== Deployment Block =====================

clear

echo "═════════════════════════════════════════════════════════════════════════════════════════════════════════════"
echo "                                                                                                             "
echo "██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗    ████████╗ ██████╗  ██████╗ ██╗     ██╗  ██╗██╗████████╗"
echo "██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██║ ██╔╝██║╚══██╔══╝"
echo "██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝        ██║   ██║   ██║██║   ██║██║     █████╔╝ ██║   ██║   "
echo "██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝         ██║   ██║   ██║██║   ██║██║     ██╔═██╗ ██║   ██║   "
echo "██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║          ██║   ╚██████╔╝╚██████╔╝███████╗██║  ██╗██║   ██║   "
echo "╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝          ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝   ╚═╝   "
echo "                                                                                                             "
echo "  Author: Frex & Charles          Version: 1.1-ubuntu-noble          Date: 2026-01-13          LICENSE: MIT  "
echo "═════════════════════════════════════════════════════════════════════════════════════════════════════════════"

main() {
    check_root
    detect_boot_mode

    warn "********************************** Partitioning Part **********************************"
    if confirm_with_timeout "Auto select disk?" 10; then
        select_disk_auto || exit 1
    else
        select_disk_manual || exit 1
    fi

    show_partition_plan

    warn "DANGER: This action is irreversible!"
    local required_text="FUCK MY DISK"
    echo -e "\033[1;33mPlease type: \033[1;31m$required_text\033[1;33m to confirm:\033[0m"
    while true; do
        read -p "> " user_input
        if [[ "$user_input" != "$required_text" ]]; then
            error "===> Confirmation text mismatch. Partitioning aborted."
        else 
            break
        fi
    done

    create_partitions
    format_partitions

    echo ""
    parted $DISK print
    echo ""
    info "===> Partitioning completed!"

    warn "********************************** Mount and Extract Part **********************************"
    mount_target
    rsync_rootfs
    gen_fstab
    install_bootloader
    unmount_target
}

trap 'echo ""; exit' SIGINT

main "$@"

info "===> Auto Deployment completed successfully!"

for i in {10..1}; do
    echo -ne "\rThe system will now reboot in $i seconds."
    sleep 1
done

echo -e "\nRebooting now..."
echo s >/proc/sysrq-trigger
echo u >/proc/sysrq-trigger
echo b >/proc/sysrq-trigger
