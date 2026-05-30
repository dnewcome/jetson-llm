#!/bin/bash
# Native flash on the host (no Docker). Single-script flow: downloads L4T
# tarballs if missing, extracts BSP + rootfs, overlays NVIDIA drivers via
# apply_binaries.sh, and flashes a Jetson in recovery mode. Idempotent —
# re-running skips already-done steps.
#
# Used because Docker can't run the L4T flash flow cleanly on modern hosts
# (e.g. Ubuntu 25.10 + kernel 6.17, where lsusb in any Ubuntu container —
# 20.04, 22.04, 24.04 — fails with mprotect/mseal denials from the new
# kernel's memory-protection restrictions). NVIDIA's tegra binaries link
# cleanly against modern Ubuntu's libs (verified with ldd) — the Ubuntu 20.04
# *userland* requirement is a tested config, not a hard kernel-level one.
#
# Usage:
#   sudo ./native_flash.sh                                       # AGX Xavier
#   sudo BOARD=jetson-xavier-nx-devkit-emmc ./native_flash.sh    # Xavier NX
#   sudo WORKDIR=/mnt/big/jetson-flash ./native_flash.sh         # tarballs elsewhere
#
# Env knobs: BOARD, TARGET (default mmcblk0p1), WORKDIR (default this dir),
# L4T_VER (default 35.6.0), L4T_REL_DIR (default r35_release_v6.0).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD="${BOARD:-jetson-agx-xavier-devkit}"
TARGET="${TARGET:-mmcblk0p1}"
WORKDIR="${WORKDIR:-$HERE}"
L4T_VER="${L4T_VER:-35.6.0}"
L4T_REL_DIR="${L4T_REL_DIR:-r35_release_v6.0}"
TREE="$WORKDIR/Linux_for_Tegra"
mkdir -p "$WORKDIR"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo $0)"; exit 1; }

# Board must be in recovery (APX = 0955:7019)
lsusb -d 0955: 2>/dev/null | grep -q 7019 || {
  echo "ERROR: no Jetson in recovery mode (lsusb 0955:7019 not found)"
  echo "Power on the board holding the FORCE_REC button, then retry."
  exit 2
}

echo "===== [1/6] install host prereqs (idempotent) ====="
# apt-get update may fail on third-party repos (e.g. transient Cursor hash mismatch);
# don't abort — the actual install only needs the main Ubuntu repos.
DEBIAN_FRONTEND=noninteractive apt-get update -qq || \
  echo "apt-get update: some repos failed (likely third-party), continuing"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 libxml2-utils libusb-1.0-0 dosfstools abootimg device-tree-compiler \
  openssl libssl3 usbutils cpio bc kmod file xxd uuid-runtime sshpass \
  whiptail libfdt1 lbzip2 lz4 zstd ca-certificates openssh-client \
  >/tmp/native_flash_apt.log 2>&1 || { echo "apt install failed:"; tail -20 /tmp/native_flash_apt.log; exit 1; }

echo "===== [2/6] fetch L4T tarballs if missing (delegates to download-l4t.sh) ====="
WORKDIR="$WORKDIR" L4T_VER="$L4T_VER" L4T_REL_DIR="$L4T_REL_DIR" "$HERE/download-l4t.sh"

echo "===== [3/6] extract BSP + rootfs (idempotent) ====="
cd "$WORKDIR"
[ -d Linux_for_Tegra ] || tar -I lbzip2 -xf "Jetson_Linux_R${L4T_VER}_aarch64.tbz2"
# rootfs must be extracted as root to preserve perms / device nodes (we are root).
[ -e Linux_for_Tegra/rootfs/etc/passwd ] || \
  tar -I lbzip2 -xpf "Tegra_Linux_Sample-Root-Filesystem_R${L4T_VER}_aarch64.tbz2" \
    -C Linux_for_Tegra/rootfs

cd "$TREE"
echo "BSP: $(head -1 nv_tegra/nv_tegra_release 2>/dev/null || echo unknown)"

echo "===== [4/6] l4t_flash_prerequisites (if present) ====="
[ -f tools/l4t_flash_prerequisites.sh ] && \
  ./tools/l4t_flash_prerequisites.sh >/tmp/l4t_prereq.log 2>&1 || true

echo "===== [5/6] apply_binaries (overlay NVIDIA drivers onto rootfs) ====="
[ -e rootfs/usr/lib/aarch64-linux-gnu/tegra ] && echo "already applied, skipping" || ./apply_binaries.sh

echo "===== patching L4T recovery script (idempotent) ====="
# Modern OpenSSH (9.x on Ubuntu 25.10) refuses to generate DSA keys (deprecated).
# L4T's ota_make_recovery_img_dtb.sh calls `ssh-keygen -t dsa` while building the
# recovery initrd; the failure is hidden by 2>&1 but check_error sees non-zero
# and aborts with "command is failed". Replace the line with a no-op so the
# recovery image still builds (just without a DSA host key — modern systems
# wouldn't use it anyway).
_OTAREC="$TREE/tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh"
if [ -f "$_OTAREC" ] && grep -q '^\s*ssh-keygen -t dsa' "$_OTAREC"; then
  sed -i 's|^\(\s*\)ssh-keygen -t dsa.*|\1true # patched: DSA deprecated in modern openssh|' "$_OTAREC"
  echo "  patched: ssh-keygen -t dsa -> true ($_OTAREC)"
else
  echo "  ssh-keygen DSA line already patched or not present"
fi

echo "===== [6/6] FLASH (destructive) — $BOARD $TARGET ====="
lsusb -d 0955: | grep -q 7019 || { echo "BOARD NOT IN RECOVERY (0955:7019 missing) — aborting"; exit 2; }
./flash.sh "$BOARD" "$TARGET"
echo "===== flash complete — board will reboot into the new OS ====="
