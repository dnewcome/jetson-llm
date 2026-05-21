#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

echo "Before:"
free -h

sync
echo 3 > /proc/sys/vm/drop_caches

if [[ -w /proc/sys/vm/compact_memory ]]; then
    echo 1 > /proc/sys/vm/compact_memory
fi

if command -v swapoff >/dev/null && command -v swapon >/dev/null; then
    if [[ -n "$(swapon --show --noheadings)" ]]; then
        swapoff -a && swapon -a
    fi
fi

echo
echo "After:"
free -h
