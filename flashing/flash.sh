#!/bin/bash
# Flash a Jetson (in recovery/APX mode) with NVIDIA L4T, from a host that ISN'T
# Ubuntu 20.04 — by running the whole flow in a privileged ubuntu:20.04
# container with USB passthrough. Docker must be usable (no sudo needed if your
# user is in the docker group).
#
# Usage:
#   ./flash.sh                     # AGX Xavier, L4T 35.6.0, workdir ~/jetson-flash
#   BOARD=jetson-xavier-nx-devkit-emmc ./flash.sh
#   WORKDIR=/path/with/space ./flash.sh
#
# The big L4T tarballs (~2.3GB) are cached in WORKDIR and reused across runs —
# keep WORKDIR OUTSIDE this repo so they're never committed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOARD="${BOARD:-jetson-agx-xavier-devkit}"
TARGET="${TARGET:-mmcblk0p1}"
WORKDIR="${WORKDIR:-$HERE}"                       # default: tarballs/tree next to the scripts
L4T_VER="${L4T_VER:-35.6.0}"
L4T_REL_DIR="${L4T_REL_DIR:-r35_release_v6.0}"   # NVIDIA's redist path for this L4T
IMAGE="${IMAGE:-ubuntu:20.04}"
mkdir -p "$WORKDIR"

echo "board=$BOARD target=$TARGET L4T=$L4T_VER workdir=$WORKDIR"

# 1. board must be in recovery (APX = 0955:7019)
if ! lsusb -d 0955: 2>/dev/null | grep -q 7019; then
  echo "ERROR: no Jetson in recovery mode (lsusb 0955:7019 not found)."
  echo "Power on the board holding the recovery/FORCE_REC button, then retry."
  exit 1
fi

# 2. fetch tarballs if missing (delegates to download-l4t.sh; single source of
#    truth for the L4T URLs + size verification)
WORKDIR="$WORKDIR" L4T_VER="$L4T_VER" L4T_REL_DIR="$L4T_REL_DIR" "$HERE/download-l4t.sh"

# 3. stage the in-container script + run the flash in a privileged container
[ "$HERE" = "$WORKDIR" ] || cp "$HERE/run_flash.sh" "$WORKDIR/run_flash.sh"
echo "launching privileged $IMAGE container to flash ..."
docker run --rm --privileged \
  -v "$WORKDIR:/work" \
  -v /dev/bus/usb:/dev/bus/usb \
  "$IMAGE" bash /work/run_flash.sh "$BOARD" "$TARGET"
