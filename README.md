# linux-server-image-builder

**Recommend to use a physical machine with Linux installed to build the image and ISO.**

## Branch Specification

Different distributions are distributed across different branches, with some distributions offer two build types: **rsync/livecd**.

### rsync

Use the distribution root filesystem as the boot environment, then partition within this environment and synchronise the root filesystem to the physical disk using rsync.

### livecd

Create a distribution Live CD as the boot environment, then partition within this environment and write the root filesystem to the physical disk.

## ubuntu-noble-rsync (current branch)

### On any ubuntu (>=22.04) / debian (>=11) machine

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt install time ansible debootstrap genisoimage cd-boot-images-amd64 xorriso

# Create work directory
sudo mkdir -p /var/cache/noble-img-build

# Bootstrap the base image
sudo ./scripts/bootstrap.sh /var/cache/noble-img-build/noble-rootfs

# Build base image
# For CN user, recommend to set proxies before this step.
sudo ./scripts/ansible.sh /var/cache/noble-img-build/noble-rootfs

# Build iso
sudo ./scripts/build.sh /var/cache/noble-img-build/noble-rootfs ubuntu-noble-repacked-2026XXXX.iso
```