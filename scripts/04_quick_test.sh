#!/bin/bash
# Quick interactive test with a specific model
# Usage: ./04_quick_test.sh [model_path_or_name]

BASE=/data/george
export PATH=$BASE/llama.cpp/build/bin:$PATH

# Default to qwen3-8b if no arg
MODEL="${1:-$BASE/models/qwen3-8b-q4km.gguf}"

# Allow short name: ./04_quick_test.sh qwen3
if [ ! -f "$MODEL" ]; then
    FOUND=$(ls $BASE/models/*${MODEL}*.gguf 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        MODEL="$FOUND"
    else
        echo "Model not found: $MODEL"
        echo "Available:"
        ls $BASE/models/*.gguf 2>/dev/null | xargs -I{} basename {}
        exit 1
    fi
fi

echo "Model: $(basename $MODEL)  ($(du -sh $MODEL | cut -f1))"
echo ""

llama-cli \
    --model "$MODEL" \
    --n-gpu-layers 99 \
    --threads 8 \
    --ctx-size 4096 \
    --prompt "Hello! Please introduce yourself briefly." \
    --n-predict 200 \
    --log-disable
