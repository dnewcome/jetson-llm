#!/bin/bash
# Download NVIDIA's official L4T tarballs (BSP + sample rootfs) into WORKDIR.
# Standalone so you can pre-stage them without flashing (e.g. ahead of time, or
# to refresh the cache). Resumable; verifies each file against the server's
# Content-Length. flash.sh calls this; you can also run it directly.
#
# Usage:
#   ./download-l4t.sh                          # L4T 35.6.0 -> ~/jetson-flash
#   L4T_VER=35.5.0 L4T_REL_DIR=r35_release_v5.0 ./download-l4t.sh
#   WORKDIR=/mnt/big/jetson-flash ./download-l4t.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$HERE}"                       # default: cache next to the scripts
L4T_VER="${L4T_VER:-35.6.0}"
L4T_REL_DIR="${L4T_REL_DIR:-r35_release_v6.0}"   # NVIDIA redist path for this L4T

BASE="https://developer.nvidia.com/downloads/embedded/l4t/${L4T_REL_DIR}/release"
BSP_URL="$BASE/Jetson_Linux_R${L4T_VER}_aarch64.tbz2"
RFS_URL="$BASE/Tegra_Linux_Sample-Root-Filesystem_R${L4T_VER}_aarch64.tbz2"

mkdir -p "$WORKDIR"
echo "L4T $L4T_VER  ->  $WORKDIR"

# Expected size from the server (follows the 302 to the CDN).
remote_size() { curl -sIL --max-time 30 "$1" | awk 'BEGIN{IGNORECASE=1} /^content-length:/{n=$2} END{gsub(/\r/,"",n); print n}'; }

get() { # url dest
  local url="$1" dest="$2" name want have
  name="$(basename "$dest")"
  # Prefer an existing local file. Verify against the server size when we can
  # reach it; if it matches, use it. If the server is unreachable (offline),
  # trust a non-empty local file rather than failing.
  if [ -s "$dest" ]; then
    want="$(remote_size "$url" 2>/dev/null || true)"
    have="$(stat -c %s "$dest")"
    if [ -z "$want" ]; then
      echo "have $name ($have bytes) — using local (couldn't verify size, offline?)"; return
    fi
    if [ "$have" = "$want" ]; then
      echo "have $name ($have bytes) — ok, using local"; return
    fi
    echo "$name is $have bytes but server says $want — re-downloading"
  fi
  echo "downloading $name ..."
  curl -fL -C - -o "$dest" "$url"
  have="$(stat -c %s "$dest")"
  want="$(remote_size "$url" 2>/dev/null || true)"
  if [ -n "$want" ] && [ "$have" != "$want" ]; then
    echo "WARNING: $name is $have bytes, expected $want — incomplete/corrupt?"; exit 1
  fi
  echo "ok: $name $have bytes"
}

get "$BSP_URL" "$WORKDIR/bsp.tbz2"
get "$RFS_URL" "$WORKDIR/rootfs.tbz2"
echo "done."
