# Jetson AGX Xavier LLM Benchmarks

Local LLM inference benchmarks using [llama.cpp](https://github.com/ggerganov/llama.cpp) on a NVIDIA Jetson AGX Xavier 32GB.

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
└── 04_quick_test.sh    # interactive llama-cli test
```

## Benchmark Results

All benchmarks: `llama-bench --n-prompt 512 --n-gen 128 --repetitions 3 --n-gpu-layers 99 --threads 8`

| Model | Size | Prompt pp512 (tok/s) | Generation tg128 (tok/s) |
|-------|------|---------------------:|-------------------------:|
| Llama 3.2 3B Q4_K_M | 1.9 GB | 646 | **27.3** |
| Qwen3 8B Q4_K_M | 4.7 GB | 277 | **13.7** |
| Qwen2.5 14B Q4_K_M | 8.4 GB | 139 | **7.6** |
| Qwen2.5 32B Q4_K_M | 19 GB | ❌ OOM | — |

Generation speed roughly halves with each model size doubling. The **8B range** is the practical sweet spot: good quality at ~14 tok/s.

## Running Models

### Benchmark a model

```bash
# Standard (works for models up to ~8GB)
/data/george/llama.cpp/build/bin/llama-bench \
  --model /data/george/models/qwen3-8b-q4km.gguf \
  --n-gpu-layers 99 --threads 8 \
  --n-prompt 512 --n-gen 128 --repetitions 3

# For 14B and larger — requires GGML_CUDA_NO_VMM=1
env GGML_CUDA_NO_VMM=1 /data/george/llama.cpp/build/bin/llama-bench \
  --model /data/george/models/qwen2.5-14b-q4km.gguf \
  --n-gpu-layers 99 --threads 8 \
  --n-prompt 512 --n-gen 128 --repetitions 3
```

### Interactive chat

```bash
env GGML_CUDA_NO_VMM=1 /data/george/llama.cpp/build/bin/llama-cli \
  --model /data/george/models/qwen3-8b-q4km.gguf \
  --n-gpu-layers 99 --threads 8 --ctx-size 4096 \
  --conversation --log-disable
```

## Memory Constraints

The Xavier has 32GB unified memory but **NvMap** (NVIDIA's Tegra memory allocator) limits individual GPU-accessible contiguous allocations to roughly **8-9GB**. This means:

- Models up to ~8-9GB: load fully on GPU, full speed
- Models 9-19GB: fail with `NvMapMemAllocInternalTagged: error 12` (ENOMEM) unless using CPU offload
- Models >19GB: OOM at load time, cannot run on GPU

### `GGML_CUDA_NO_VMM=1`

The 14B model needs this env var to disable CUDA's Virtual Memory Manager pool, which uses a different (failing) allocation path for scratch buffers. Without it, the 14B crashes mid-computation. Models ≤8B do **not** need this flag (and actually crash with it set).

### NvMap vs. Linux CMA — why you can't fix this with `cma=`

NvMap's contiguous heap is **not** Linux CMA. The Tegra bootloader carves out a fixed contiguous region from physical memory at boot, configured in the device tree (DTB), before Linux starts. This is the source of the ~8-9GB ceiling.

Linux's `cma=` kernel parameter controls a completely separate allocator used by display, V4L2 cameras, and similar subsystems — it has no effect on NvMap or GPU compute allocations.

**Experiment:** We tried adding `cma=20G` to `/boot/extlinux/extlinux.conf` hoping to increase GPU-accessible memory. It failed in two ways:

1. The kernel rejected the request outright: `cma: Size (0x500000000) of region exceeds limit (0x100000000)` — Tegra's CMA ceiling is 4GB.
2. Even though CMA never allocated (`0K cma-reserved`), the failed reservation disrupted the GPU driver's memory layout. All models — including ones that previously worked — crashed with `NvRmGpuLibOpen failed, error=4`.

The fix was to revert `/boot/extlinux/extlinux.conf` from its backup and reboot.

**The real fix** would require modifying the Tegra device tree binary (DTB) to increase the NvMap carveout size (`nvidia,carveout-size`), recompiling the DTB, and flashing it. This is significantly more involved and not guaranteed to work within the Xavier's physical memory constraints. In practice, **~8-9GB is the hard ceiling** for GPU-resident model weights on this board.

## Downloaded Models

| File | Size |
|------|------|
| `llama-3.2-3b-q4km.gguf` | 1.9 GB |
| `qwen3-8b-q4km.gguf` | 4.7 GB |
| `qwen2.5-14b-q4km.gguf` | 8.4 GB |
| `qwen2.5-32b-q4km.gguf` | 19 GB |

## Notes

- HuggingFace throttles large unauthenticated downloads. Use `huggingface-cli login` with a token for faster speeds on models >5GB.
- The NVMe is not auto-mounted at boot unless `/etc/fstab` has been updated (done during setup).
- llama.cpp build hash: `871b0b7`
