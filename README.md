# Jetson AGX Xavier LLM Benchmarks

Local LLM inference benchmarks using [llama.cpp](https://github.com/ggerganov/llama.cpp) on a NVIDIA Jetson AGX Xavier 32GB.

> ## Update: the "~10GB ceiling" was `mmap`, not NvMap — use `--no-mmap`
>
> The single-allocation ceiling documented in [Memory Constraints](#memory-constraints) is **not** a hardware / NvMap / CMA limit. It's **`mmap` double-counting**: with mmap on (llama.cpp's default), a model is resident in RAM *twice* during load — the page-cached file **plus** the GPU buffer it's copied into (~2× its size). On a 30GB unified board that caps you near half (~10GB), and `NvMapMemAllocInternalTagged: error 12` is plain **ENOMEM**, not a contiguity failure. So the CMA/DTB hunt was the wrong tree — the GPU's SMMU/IOMMU already maps scattered pages into a contiguous GPU address space, so no large physically-contiguous block is ever needed (a raw `cudaMalloc` probe reaches 28GB after a flush).
>
> **Fix: add `--no-mmap` (or `--mmap 0` to `llama-bench`)** — it reads weights straight into the GPU buffer with no cached duplicate. Models up to ~24GB then load **full-GPU on one board**. Proof — same board, `-ngl 99`, flushed: `Qwen2.5-Coder-32B-Q4_K_M` (18.5GB) **OOMs with `--mmap 1`, loads fine with `--mmap 0`**, on *both* the old (`871b0b7`) and new builds (so it's not the build or VMM).
>
> Re-benchmarked with `--no-mmap -ngl 99` (previously OOM / partial-only):
>
> | Model | Size | Was | Now | pp64 | tg16 |
> |---|--:|---|---|--:|--:|
> | Qwen2.5-Coder 32B | 18.5 GB | OOM | ✅ full GPU | 12.8 | 2.58 |
> | Qwen2.5 32B | 18.5 GB | OOM | ✅ full GPU | 12.8 | 2.58 |
> | Qwen3.6 27B | 16.7 GB | OOM | ✅ full GPU | 16.9 | 2.90 |
> | Nemotron-3-Nano 30B MoE | 16.9 GB | partial (ngl 20, 7.5) | ✅ full GPU | 74.0 | **16.9** |
> | Gemma4 26B Q3_K_S | 11.4 GB | failed | ✗ still fails — unsupported quant, *not* memory | | |
>
> The Nemotron MoE more than doubles (7.5 → 16.9 tg) going full-GPU. The original investigation below is kept as the debugging record. For a 70B that *still* won't fit one board, see [`distributed-70b/`](distributed-70b/) — split across two Xaviers via RPC.

## Hardware

| | |
|---|---|
| **Device** | NVIDIA Jetson AGX Xavier 32GB (p2888-0004) |
| **GPU** | Volta, compute capability 7.2, 512 CUDA cores |
| **Memory** | 32GB LPDDR4X unified (CPU + GPU share the same pool) |
| **CPU** | 8x ARM Cortex-A57 @ 2265 MHz |
| **Storage** | 28GB eMMC (OS) + 931GB NVMe at `/data` |
| **CUDA** | 11.4.315 |
| **cuDNN** | 8.6.0.166 |
| **OS** | Ubuntu 20.04.6, L4T 35.6.4 |
| **Power mode** | MAXN (maximum performance) |

## Setup

### NVMe mount

The NVMe drive holds all models and the llama.cpp build:

```bash
sudo mount /dev/nvme0n1 /data   # persistent via /etc/fstab after setup
```

### Build llama.cpp

```bash
bash /data/george/01_setup.sh
```

Builds with CUDA enabled for Volta (`-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=72`). Takes ~30 minutes on the Xavier. Requires cmake 3.21+ (installed via pip since system cmake is 3.16).

### Directory layout

```
/data/george/
├── llama.cpp/          # source + build
│   └── build/bin/      # llama-bench, llama-cli, llama-server
├── models/             # GGUF model files
├── benchmark-results/  # CSV/text output from llama-bench
├── 01_setup.sh         # build llama.cpp
├── 02_download_models.sh  # download full model suite
├── 03_benchmark.sh     # run llama-bench on all models
├── 04_quick_test.sh    # interactive llama-cli test
├── 05_download_yaml.py # download models listed in models.yaml
├── 06_benchmark_yaml.py # benchmark models on-device
└── flush_mem.sh        # drop page cache + compact memory before benchmarking
```

## Benchmark Results

All benchmarks: `llama-bench --n-prompt 512 --n-gen 128 --repetitions 3 --n-gpu-layers 99 --threads 8`

**Important:** run `flush_mem.sh` before each model to drop the Linux page cache and compact physical memory. Without it, large file downloads fragment RAM and cause spurious NvMap ENOMEM errors even on models that easily fit (see [Memory Constraints](#memory-constraints)).

### Full GPU (all layers on GPU)

| Model | Size | Quant | pp512 (tok/s) | tg128 (tok/s) | Notes |
|-------|-----:|-------|-------------:|-------------:|-------|
| Qwen2.5-Coder 3B Instruct | 1.8 GB | Q4_K_M | 643 | **27.6** | |
| Llama 3.2 3B Instruct | 1.9 GB | Q4_K_M | 646 | **27.3** | |
| Qwen3.5 4B | 4.3 GB | Q8_0 | 453 | **14.1** | |
| Qwen3 8B | 4.7 GB | Q4_K_M | 277 | **13.7** | |
| Gemma4 E4B | 7.5 GB | Q8_0 | 474 | **13.5** | NO_VMM=1 |
| Qwen2.5-Coder 7B Instruct | 5.8 GB | Q6_K | 323 | **10.5** | |
| Nemotron-Nano 9B v2 | 6.1 GB | Q4_K_M | 195 | **11.9** | |
| Qwen3.5 9B | 7.4 GB | Q6_K | 285 | **9.6** | NO_VMM=1 |
| Qwen2.5 14B Instruct | 8.4 GB | Q4_K_M | 139 | **7.6** | NO_VMM=1 |
| Apriel-Nemotron 15B Thinker | 8.5 GB | Q4_K_M | 135 | **7.7** | NO_VMM=1 |
| Qwen2.5 14B Instruct | 9.8 GB | Q5_K_M | 152 | **6.8** | NO_VMM=1 |
| DeepSeek-R1-Distill Qwen 14B | 9.8 GB | Q5_K_M | 153 | **6.8** | NO_VMM=1 |

### Partial GPU (large models — 20 layers on GPU, rest on CPU)

| Model | Size | Quant | pp512 (tok/s) | tg128 (tok/s) | Active params |
|-------|-----:|-------|-------------:|-------------:|--------------|
| Gemma4 26B MoE | 15.9 GB | Q4_K_M | 168 | **9.6** | ~4B |
| Qwen3.5 35B MoE | 14.7 GB | IQ3_XXS | 149 | **6.6** | ~3B |
| Qwen3.6 35B MoE | 14.7 GB | IQ3_XXS | 147 | **6.6** | ~3B |
| Nemotron3-Nano 30B MoE | 16.9 GB | IQ3_XXS | 119 | **7.5** | ~3.5B |

### Failed / Not runnable

> **Update:** three of these (Coder-32B, Qwen2.5-32B, Qwen3.6-27B) now run **full-GPU with `--no-mmap`** — see the Update section at top. Only Gemma4 26B Q3_K_S still fails, and that's an unsupported-quant load error, not memory.

| Model | Size | Reason |
|-------|-----:|--------|
| Qwen2.5-Coder 32B | 18.5 GB | OOM — exceeds NvMap ceiling |
| Qwen2.5 32B | 19 GB | OOM — exceeds NvMap ceiling |
| Qwen3.6 27B Q4_K_M | 16.7 GB | OOM with full GPU; untested at ngl=20 |
| Gemma4 26B Q3_K_S | 11.4 GB | Failed to load — likely unsupported quant |

### Observations

- The **MoE models punch above their weight**: the 26B and 35B MoE models generate at the same speed as dense 14B models (~7-10 tok/s) because only ~3-4B parameters are active per token, while benefiting from much larger total model capacity.
- **Gemma4 E4B is the speed/quality sweet spot**: 7.5 GB Q8_0 at 13.5 tok/s — full precision, Google claims ~Gemma 3 27B quality in a 4B effective model.
- The **~10 GB threshold** (with `GGML_CUDA_NO_VMM=1` and flushed memory) is the real ceiling for full-GPU models, not the ~8-9 GB we initially measured.

## Running Models

### Flush memory before loading

Large model downloads fill the Linux page cache, which fragments the physically contiguous memory NvMap needs. Always flush before benchmarking or loading a model:

```bash
bash /data/george/flush_mem.sh
```

This runs `drop_caches` and `compact_memory`, reclaiming page cache and defragmenting RAM. Takes ~2 seconds.

### Benchmark a model

```bash
# Small models (≤7 GB) — no special flags needed
bash /data/george/flush_mem.sh
/data/george/llama.cpp/build/bin/llama-bench \
  --model /data/george/models/qwen3-8b-q4km.gguf \
  --n-gpu-layers 99 --threads 8 \
  --n-prompt 512 --n-gen 128 --repetitions 3

# Medium models (7–10 GB) — disable CUDA VMM pool
bash /data/george/flush_mem.sh
env GGML_CUDA_NO_VMM=1 /data/george/llama.cpp/build/bin/llama-bench \
  --model /data/george/models/qwen2.5-14b-q4km.gguf \
  --n-gpu-layers 99 --threads 8 \
  --n-prompt 512 --n-gen 128 --repetitions 3

# Large models (>10 GB) — partial GPU offload required
bash /data/george/flush_mem.sh
/data/george/llama.cpp/build/bin/llama-bench \
  --model /data/george/models/google_gemma-4-26B-A4B-it-Q4_K_M.gguf \
  --n-gpu-layers 20 --threads 8 \
  --n-prompt 512 --n-gen 128 --repetitions 3
```

### Interactive chat

```bash
bash /data/george/flush_mem.sh
env GGML_CUDA_NO_VMM=1 /data/george/llama.cpp/build/bin/llama-cli \
  --model /data/george/models/qwen2.5-14b-q4km.gguf \
  --n-gpu-layers 99 --threads 8 --ctx-size 4096 \
  --conversation --log-disable
```

## Memory Constraints

> **Resolved — see the Update section at the top of this README.** The "physical contiguity / NvMap ceiling" framing below turned out to be wrong: the real cause was `mmap` double-counting RAM, fixed with `--no-mmap`. This section is kept as the debugging record.

The Xavier has 32GB unified memory shared between CPU and GPU. The key constraint is **NvMap** (NVIDIA's Tegra memory allocator), which requires physically contiguous pages for GPU allocations.

### The page cache problem

After downloading large model files (tens of GB), the Linux kernel caches those file contents in RAM. This fragmented physical memory makes it impossible for NvMap to find the large contiguous block it needs — even if `free` shows gigabytes available. The symptom is `NvMapMemAllocInternalTagged: error 12` (ENOMEM) on models that should easily fit.

**Fix:** `flush_mem.sh` writes to `/proc/sys/vm/drop_caches` (frees page cache) and `/proc/sys/vm/compact_memory` (defragments physical pages). Before flushing, a fresh system shows ~700 MB free with 28 GB in cache. After flushing: ~29 GB free and contiguous.

### `GGML_CUDA_NO_VMM=1`

Models in the 7–10 GB range need this env var to disable CUDA's Virtual Memory Manager pool. The VMM pool uses a different allocation path for scratch buffers that fails on Xavier for medium-large models. Models ≤7 GB work fine without it; do **not** set it for those (it causes crashes).

### NvMap ceiling

The true NvMap ceiling for a single contiguous GPU allocation on this board (after flushing) is approximately **~10 GB**. Models up to 9.8 GB load fine with `GGML_CUDA_NO_VMM=1`. Models over ~10 GB require partial offload (`--n-gpu-layers 20`) to split weight storage across CPU and GPU memory.

### NvMap vs. Linux CMA — why you can't fix this with `cma=`

NvMap's contiguous heap is **not** Linux CMA. The Tegra bootloader carves out a fixed contiguous region from physical memory at boot, configured in the device tree (DTB), before Linux starts. Linux's `cma=` kernel parameter controls a completely separate allocator used by display and camera subsystems — it has no effect on NvMap or GPU compute allocations.

**Experiment:** We tried adding `cma=20G` to `/boot/extlinux/extlinux.conf`. It failed in two ways:

1. The kernel rejected the request: `cma: Size (0x500000000) of region exceeds limit (0x100000000)` — Tegra's CMA ceiling is 4 GB.
2. Even though CMA never allocated, the failed reservation disrupted the GPU driver. All models crashed with `NvRmGpuLibOpen failed, error=4`. Fix: revert from backup and reboot.

The real fix for a larger NvMap ceiling would require modifying the Tegra device tree binary (DTB) — significantly more involved and not guaranteed to work.

## Notes

- HuggingFace throttles large unauthenticated downloads. Use `huggingface-cli login` with a token for faster speeds on models >5 GB.
- The NVMe is auto-mounted at boot via `/etc/fstab` (set up during initial setup).
- llama.cpp build hash: `871b0b7`
- Benchmarks run with `scripts/07_benchmark_mac.py`, which flushes memory before each model via SSH from a Mac.
