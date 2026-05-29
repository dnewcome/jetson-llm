#!/usr/bin/env bash
# Board 2 (RPC worker) — serve the local GPU to board 1 over RPC.
# Power-capped to 30W: board 2's PSU browns out at MAXN under model load.
set -euo pipefail
export PATH=/usr/local/cuda/bin:${PATH:-}

LLAMA_BIN="${LLAMA_BIN:-/data/zen/llm/llama.cpp/build/bin}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-50052}"

# Cap power draw so a marginal supply stays up under GPU load (MODE_30W_ALL).
sudo nvpmodel -m 3 >/dev/null 2>&1 || true
# Drop page cache so the ~21GB weight buffer can allocate contiguously.
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

exec "$LLAMA_BIN/rpc-server" -H "$HOST" -p "$PORT"
