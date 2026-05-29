#!/usr/bin/env bash
# Board 1 (coordinator) — run a 70B split across the local GPU + board 2 via RPC.
# OpenAI-compatible API on :8080.
set -euo pipefail
export PATH=/usr/local/cuda/bin:${PATH:-}

LLAMA_BIN="${LLAMA_BIN:-/mnt/nvme/zen/llm/llama.cpp/build/bin}"
MODEL="${MODEL:-/mnt/nvme/zen/llm/models/Llama-3.3-70B-Instruct-Q4_K_M.gguf}"
RPC="${RPC:-192.168.68.65:50052}"   # board 2 rpc-server
CTX="${CTX:-4096}"
TS="${TS:-0.5,0.5}"                 # weight split: board1,board2
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"

# Drop page cache so the ~21GB weight buffer allocates contiguously.
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

# -dev CUDA0,RPC0 : force BOTH the local GPU and the remote RPC GPU into the
#                   offload set (default would dump the whole model on one).
# --no-mmap        : read straight into the GPU buffers instead of leaving
#                   42GB in page cache (which then starves the next alloc).
# -fit off         : disable auto-placement; we set -ngl/-ts explicitly.
exec "$LLAMA_BIN/llama-server" \
  -m "$MODEL" \
  --rpc "$RPC" \
  -dev CUDA0,RPC0 -ngl 99 -sm layer -ts "$TS" \
  --parallel 1 -c "$CTX" -b 512 -ub 128 \
  -fit off --no-mmap \
  --host "$HOST" --port "$PORT"
