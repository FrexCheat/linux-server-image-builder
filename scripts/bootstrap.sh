#!/usr/bin/env bash

set -euo pipefail

green='\033[0;32m'
red='\033[0;31m'
reset='\033[0m'

info() {
    echo -e "${green}$1${reset}"
}

error() {
    echo -e "${red}$1${reset}" >&2
}

if [ $# -ne 1 ]; then
    error "Usage: $0 <debootstrap target directory>"
    exit 1
fi

DESTROOTFS=$1
VERSION=noble
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
CACHEDIR=/var/cache/debootstrap

# =====================Start debootstrap process=====================

info "Debootstrapping ubuntu-$VERSION into $DESTROOTFS"

mkdir -p "$CACHEDIR"
mkdir -p "$DESTROOTFS"

debootstrap --arch=amd64 \
    --components=main,universe,multiverse,restricted \
    --cache-dir=$CACHEDIR --include=python3-debian \
    "$VERSION" "$DESTROOTFS" $MIRROR

rm -rf "$DESTROOTFS/etc/hostname" \
    "$DESTROOTFS/var/cache/apt/archives/"* \
    "$DESTROOTFS/var/lib/apt/lists/"*

info "Debootstrap ubuntu-$VERSION successfully"