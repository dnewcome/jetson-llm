#!/bin/bash
# Runs INSIDE a privileged ubuntu:20.04 container (see flash.sh) with:
#   -v <workdir>:/work   and   -v /dev/bus/usb:/dev/bus/usb
# Extracts the L4T BSP + sample rootfs, applies NVIDIA binaries, and flashes a
# Jetson in recovery mode. Idempotent: re-running skips already-done steps.
#
# Args:  $1 = board config (default: jetson-agx-xavier-devkit)
#        $2 = target partition (default: mmcblk0p1, internal eMMC)
set -euo pipefail

BOARD="${1:-jetson-agx-xavier-devkit}"
TARGET="${2:-mmcblk0p1}"
cd /work
export DEBIAN_FRONTEND=noninteractive

echo "===== [1/5] install flash prerequisites ====="
apt-get update -qq
apt-get install -y --no-install-recommends \
  sudo python3 libxml2-utils qemu-user-static binfmt-support abootimg bc cpio \
  device-tree-compiler lbzip2 sshpass udev uuid-runtime whiptail openssl \
  dosfstools libfdt1 file kmod usbutils xxd ca-certificates >/tmp/apt.log 2>&1 || {
    echo "apt install failed"; tail -20 /tmp/apt.log; exit 1; }

# Let apply_binaries chroot the arm64 rootfs (privileged container).
update-binfmts --enable qemu-aarch64 2>/dev/null || true

echo "===== [2/5] extract BSP + rootfs (idempotent) ====="
[ -d Linux_for_Tegra ] || tar -I lbzip2 -xf bsp.tbz2
# rootfs must be extracted as root to preserve perms / device nodes.
[ -e Linux_for_Tegra/rootfs/etc/passwd ] || \
  tar -I lbzip2 -xpf rootfs.tbz2 -C Linux_for_Tegra/rootfs

cd Linux_for_Tegra
echo "BSP: $(head -1 nv_tegra/nv_tegra_release 2>/dev/null || echo unknown)"

echo "===== [3/5] l4t flash prerequisites (if present) ====="
[ -f tools/l4t_flash_prerequisites.sh ] && \
  ./tools/l4t_flash_prerequisites.sh >/tmp/l4t_prereq.log 2>&1 || true

echo "===== [4/5] apply_binaries (overlay NVIDIA drivers onto rootfs) ====="
[ -e rootfs/usr/lib/aarch64-linux-gnu/tegra ] && echo "already applied, skipping" || ./apply_binaries.sh

echo "===== [5/5] FLASH (destructive) — $BOARD $TARGET ====="
lsusb -d 0955: || { echo "BOARD NOT IN RECOVERY (0955:7019 missing) — aborting"; exit 2; }
./flash.sh "$BOARD" "$TARGET"
echo "===== FLASH COMPLETE — board will reboot into the new OS ====="
