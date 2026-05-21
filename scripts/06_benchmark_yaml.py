#!/usr/bin/env python3
"""Benchmark all downloaded llamacpp models from models.yaml.
Run on the Jetson: python3 /data/george/06_benchmark_yaml.py
Results appended to /data/george/benchmark-results/
"""

import os
import subprocess
import sys
import yaml
from datetime import datetime

MODELS_DIR = "/data/george/models"
YAML_PATH = "/data/george/models.yaml"
LLAMA_BENCH = "/data/george/llama.cpp/build/bin/llama-bench"
RESULTS_DIR = "/data/george/benchmark-results"

# Files larger than this threshold need GGML_CUDA_NO_VMM=1.
# Boundary is empirically between ~4.7GB (8B Q4_K_M, works fine without)
# and ~8.4GB (14B Q4_K_M, crashes without it). 7GB leaves the 7B Q6_K
# models safely below the cutoff.
NO_VMM_THRESHOLD = 7 * 1024 * 1024 * 1024


def benchmark(model, results_fh):
    name = model["name"]
    filepath = os.path.join(MODELS_DIR, model["file"])
    n_gpu_layers = model.get("n_gpu_layers", 99)

    if not os.path.exists(filepath):
        print(f"[{name}] SKIP — not downloaded")
        return

    size_gb = os.path.getsize(filepath) / (1024 ** 3)
    use_no_vmm = size_gb * 1024 * 1024 * 1024 > NO_VMM_THRESHOLD

    print(f"\n[{name}] {size_gb:.1f}GB, ngl={n_gpu_layers}"
          + (" GGML_CUDA_NO_VMM=1" if use_no_vmm else ""))

    env = os.environ.copy()
    if use_no_vmm:
        env["GGML_CUDA_NO_VMM"] = "1"

    cmd = [
        LLAMA_BENCH,
        "--model", filepath,
        "--n-gpu-layers", str(n_gpu_layers),
        "--threads", "8",
        "--n-prompt", "512",
        "--n-gen", "128",
        "--repetitions", "3",
    ]

    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    output = result.stdout + (result.stderr if result.returncode != 0 else "")
    print(output)

    results_fh.write(f"\n{'='*60}\n")
    results_fh.write(f"model: {name}\n")
    results_fh.write(f"file:  {model['file']}\n")
    results_fh.write(f"size:  {size_gb:.1f}GB  ngl={n_gpu_layers}"
                     + ("  NO_VMM=1\n" if use_no_vmm else "\n"))
    results_fh.write(output)
    results_fh.flush()


def main():
    with open(YAML_PATH) as f:
        config = yaml.safe_load(f)

    models = config.get("llamacpp", [])
    os.makedirs(RESULTS_DIR, exist_ok=True)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = os.path.join(RESULTS_DIR, f"benchmark_yaml_{ts}.txt")
    print(f"Results -> {out_path}")

    with open(out_path, "w") as fh:
        fh.write(f"llama-bench run from models.yaml — {datetime.now()}\n")
        for m in models:
            benchmark(m, fh)

    print(f"\nDone. Results in {out_path}")


if __name__ == "__main__":
    main()
