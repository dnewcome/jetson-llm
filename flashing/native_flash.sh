#!/bin/bash
# Native flash on the host (no Docker), for hosts whose Docker can't run L4T
# tools cleanly (e.g. Ubuntu 25.10 + kernel 6.17, where lsusb in any Ubuntu
# container fails with mprotect/mseal denials). NVIDIA's flash binaries link
# fine against modern Ubuntu's libs — verified with ldd.
#
# Requires the BSP + rootfs to already be extracted to ./Linux_for_Tegra/
# with apply_binaries.sh already applied. The Docker-based ./flash.sh does
# steps 1–4 (extract + apply_binaries) idempotently; this script does step 5.
#
# Usage:
#   sudo ./native_flash.sh                                       # AGX Xavier
#   sudo BOARD=jetson-xavier-nx-devkit-emmc ./native_flash.sh    # Xavier NX
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$HERE/Linux_for_Tegra"
BOARD="${BOARD:-jetson-agx-xavier-devkit}"
TARGET="${TARGET:-mmcblk0p1}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo $0)"; exit 1; }
[ -d "$TREE" ]       || { echo "ERROR: $TREE not found — run the Docker ./flash.sh first to extract + apply_binaries"; exit 1; }

# Board must be in recovery (APX = 0955:7019)
lsusb -d 0955: 2>/dev/null | grep -q 7019 || {
  echo "ERROR: no Jetson in recovery mode (lsusb 0955:7019 not found)"
  echo "Power on the board holding the FORCE_REC button, then retry."
  exit 2
}

echo "===== installing host prereqs (idempotent) ====="
# apt-get update may fail on third-party repos (e.g. transient Cursor hash mismatch);
# don't abort — the actual install only needs the main Ubuntu repos.
DEBIAN_FRONTEND=noninteractive apt-get update -qq || \
  echo "apt-get update: some repos failed (likely third-party), continuing"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 libxml2-utils libusb-1.0-0 dosfstools abootimg device-tree-compiler \
  openssl libssl3 usbutils cpio bc kmod file xxd uuid-runtime sshpass \
  whiptail libfdt1 lbzip2 lz4 zstd ca-certificates openssh-client \
  >/tmp/native_flash_apt.log 2>&1 || { echo "apt install failed:"; tail -20 /tmp/native_flash_apt.log; exit 1; }

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

echo "===== FLASH (destructive) — $BOARD $TARGET ====="
cd "$TREE"
./flash.sh "$BOARD" "$TARGET"
echo "===== flash complete — board will reboot into the new OS ====="
