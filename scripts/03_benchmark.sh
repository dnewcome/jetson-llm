#!/bin/bash
# Run llama-bench on all downloaded models and save results

BASE=/data/george
LLAMA_BENCH=$BASE/llama.cpp/build/bin/llama-bench
MODELS_DIR=$BASE/models
RESULTS_DIR=$BASE/benchmark-results
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/bench_${TIMESTAMP}.csv"
LOG_FILE="$RESULTS_DIR/bench_${TIMESTAMP}.log"

export PATH=$BASE/llama.cpp/build/bin:$PATH

mkdir -p "$RESULTS_DIR"

if [ ! -f "$LLAMA_BENCH" ]; then
    echo "ERROR: llama-bench not found. Run 01_setup.sh first."
    exit 1
fi

echo "model,size_gb,n_gpu_layers,pp_tokens_per_sec,tg_tokens_per_sec" > "$RESULTS_FILE"

bench_model() {
    local model_path="$1"
    local ngl="${2:-99}"
    local model_name=$(basename "$model_path" .gguf)
    local size=$(du -sh "$model_path" | awk '{print $1}')

    echo ""
    echo "== $model_name ($size, ngl=$ngl) =="

    local raw
    raw=$("$LLAMA_BENCH" \
        --model "$model_path" \
        --n-gpu-layers "$ngl" \
        --threads 8 \
        --n-prompt 512 \
        --n-gen 128 \
        --repetitions 3 \
        --output-format csv \
        2>>"$LOG_FILE")

    if [ $? -eq 0 ]; then
        echo "$raw"
        # Extract pp and tg t/s from csv (cols 5 and 6 after header)
        local pp tg
        pp=$(echo "$raw" | tail -2 | head -1 | cut -d, -f5)
        tg=$(echo "$raw" | tail -1 | cut -d, -f6)
        echo "$model_name,$size,$ngl,$pp,$tg" >> "$RESULTS_FILE"
    else
        echo "  FAILED"
        echo "$model_name,$size,$ngl,ERROR,ERROR" >> "$RESULTS_FILE"
    fi
}

echo "=== Xavier LLM Benchmark - $(date) ==="
echo "GPU: Volta / compute 7.2 / CUDA 11.4"
echo "RAM: $(grep MemTotal /proc/meminfo | awk '{printf "%.0f MB", $2/1024}')"
echo "Results: $RESULTS_FILE"

for model in "$MODELS_DIR"/*.gguf; do
    [ -f "$model" ] || continue
    bench_model "$model" 99
done

echo ""
echo "=== Summary ==="
printf "%-40s %6s %12s %12s\n" "Model" "Size" "PP tok/s" "TG tok/s"
printf "%-40s %6s %12s %12s\n" "-----" "----" "--------" "--------"
tail -n +2 "$RESULTS_FILE" | while IFS=, read -r name size ngl pp tg; do
    printf "%-40s %6s %12s %12s\n" "$name" "$size" "$pp" "$tg"
done

echo ""
echo "Done: $RESULTS_FILE"
