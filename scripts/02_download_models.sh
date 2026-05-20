#!/bin/bash
# Download a selection of GGUF models for benchmarking
# Models chosen to cover a range of sizes on 32GB unified memory

set -e
BASE=/data/george
MODELS_DIR=$BASE/models
mkdir -p "$MODELS_DIR"

download_model() {
    local url="$1"
    local filename="$2"
    local dest="$MODELS_DIR/$filename"
    if [ -f "$dest" ]; then
        echo "Already exists: $filename ($(du -sh $dest | cut -f1))"
        return
    fi
    echo "Downloading: $filename ..."
    wget -q --show-progress -O "$dest.tmp" "$url" && mv "$dest.tmp" "$dest"
    echo "Done: $filename ($(du -sh $dest | cut -f1))"
}

echo "=== Downloading benchmark models to $MODELS_DIR ==="
echo "Available disk: $(df -h /data | tail -1 | awk '{print $4}')"
echo ""

# --- 1B class ---
echo "--- 1B class ---"
download_model \
    "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf" \
    "llama-3.2-1b-q4km.gguf"
download_model \
    "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q8_0.gguf" \
    "llama-3.2-1b-q8.gguf"

# --- 3B class ---
echo "--- 3B class ---"
download_model \
    "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
    "llama-3.2-3b-q4km.gguf"
download_model \
    "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf" \
    "phi-3.5-mini-q4km.gguf"

# --- 7B-8B class ---
echo "--- 7B-8B class ---"
download_model \
    "https://huggingface.co/bartowski/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf" \
    "qwen3-8b-q4km.gguf"
download_model \
    "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf" \
    "llama-3.1-8b-q4km.gguf"
download_model \
    "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf" \
    "mistral-7b-q4km.gguf"
download_model \
    "https://huggingface.co/bartowski/gemma-2-9b-it-GGUF/resolve/main/gemma-2-9b-it-Q4_K_M.gguf" \
    "gemma-2-9b-q4km.gguf"

# --- 14B class ---
echo "--- 14B class ---"
download_model \
    "https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf" \
    "qwen2.5-14b-q4km.gguf"

# --- Large class (tests limits of 32GB RAM) ---
echo "--- Large class ---"
download_model \
    "https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q2_K.gguf" \
    "llama-3.1-70b-q2k.gguf"

echo ""
echo "=== Download complete ==="
ls -lh $MODELS_DIR/*.gguf 2>/dev/null
echo "Total: $(du -sh $MODELS_DIR/ | cut -f1)"
