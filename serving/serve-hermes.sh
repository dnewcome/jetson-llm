#!/bin/bash
# Launch Hermes-3-Llama-3.1-8B as an Anthropic-compatible API server on
# a single Jetson Xavier (32GB), tuned for use as a Claude CLI backend.
#
# Tradeoffs picked here:
# - Q4_K_M model (~4.6GB) — fits with massive headroom on one board, leaving
#   plenty of RAM for KV + prompt cache.
# - Llama-3.1 base → 128k native context, no rope-scaling/YaRN hacks needed.
# - q4_0 KV cache → 128k context fits in ~4GB instead of ~16GB at fp16.
#   Quality impact on Llama-family is negligible in practice.
# - 14GB prompt cache → holds many turns' worth of past prompt KV snapshots,
#   so multi-turn sessions stay fast.
# - --jinja → uses the GGUF's Jinja chat template so tool calling formats
#   correctly. (NO --reasoning off — Hermes-3 isn't a reasoning model.)
#
# Endpoint is at http://<board-ip>:8080
# - /v1/messages       — Anthropic format (what Claude CLI uses)
# - /v1/chat/completions — OpenAI format (Aider, Cline, etc.)
# - /v1/models, /props, /slots, /ui/ — info + web UI
set -euo pipefail

MODEL="${MODEL:-/mnt/nvme/zen/llm/models/Hermes-3-Llama-3.1-8B-Q4_K_M.gguf}"
LLAMA_BIN="${LLAMA_BIN:-/mnt/nvme/zen/llm/llama.cpp/build/bin/llama-server}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
LOG="${LOG:-/mnt/nvme/zen/llm/llama-hermes.log}"

[ -x "$LLAMA_BIN" ] || { echo "ERROR: $LLAMA_BIN not found / not executable"; exit 1; }
[ -f "$MODEL" ]     || { echo "ERROR: $MODEL not found — download with:"
  echo "  wget -O $MODEL https://huggingface.co/bartowski/Hermes-3-Llama-3.1-8B-GGUF/resolve/main/Hermes-3-Llama-3.1-8B-Q4_K_M.gguf"
  exit 1; }

# Refuse to launch if something else holds the port.
if ss -lnt 2>/dev/null | grep -q ":$PORT "; then
  echo "ERROR: port $PORT already in use:"
  ss -lntp | grep ":$PORT " | head -3
  exit 2
fi

echo "===== launching Hermes-3 on $HOST:$PORT ====="
echo "model: $MODEL"
echo "log:   $LOG"

cd "$(dirname "$LLAMA_BIN")"
nohup "$LLAMA_BIN" \
  -m "$MODEL" \
  -dev CUDA0 -ngl 99 \
  --parallel 1 -c 131072 \
  -ctk q4_0 -ctv q4_0 \
  -b 512 -ub 128 -fit off --no-mmap \
  --cache-ram 14336 \
  --jinja \
  --host "$HOST" --port "$PORT" \
  > "$LOG" 2>&1 &
PID=$!
echo "pid $PID"

# Wait for health endpoint to flip to 200 (model loaded + ready).
echo -n "waiting for ready"
for i in $(seq 1 30); do
  CODE=$(wget -qO/dev/null -S "http://127.0.0.1:$PORT/health" 2>&1 | awk '/HTTP\//{print $2; exit}')
  [ "$CODE" = "200" ] && { echo " — READY"; exit 0; }
  echo -n "."
  sleep 3
done
echo
echo "WARN: still not ready after 90s — check $LOG"
exit 3
