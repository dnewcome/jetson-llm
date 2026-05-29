# Distributed 70B across two Jetson AGX Xavier

A 42.5GB model (Llama 3.3 70B, Q4_K_M) doesn't fit on one 30GB board, so we split it across two with llama.cpp's **RPC backend**: board 1 holds ~half the layers on its GPU and streams activations to board 2, which holds the other half (pipeline parallelism).

## Model

[`Llama-3.3-70B-Instruct-Q4_K_M.gguf`](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF) — Meta Llama 3.3 70B Instruct, Q4_K_M, **42.5 GB** (ungated GGUF; no HF token needed). Download to board 1:

```bash
wget -c "https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf" \
  -O /mnt/nvme/zen/llm/models/Llama-3.3-70B-Instruct-Q4_K_M.gguf
```

## Hardware

|  | Board 1 (coordinator) | Board 2 (RPC worker) |
|---|---|---|
| Host | `192.168.68.62` | `192.168.68.65` |
| Role | runs `llama-server`, holds the model file | runs `rpc-server` |
| Work dir | `/mnt/nvme/zen/llm` | `/data/zen/llm` |
| Power mode | MAXN | **MODE_30W_ALL** (PSU stability) |

Both: Jetson AGX Xavier 32GB, JetPack 5.1.x (L4T R35.6), CUDA 11.4, sm_72. Connected by **gigabit ethernet**.

## Build

llama.cpp on each board:
```bash
cmake -B build -DGGML_CUDA=ON -DGGML_RPC=ON \
      -DCMAKE_CUDA_ARCHITECTURES=72 -DGGML_RPC_RDMA=OFF -DLLAMA_CURL=OFF
cmake --build build --config Release -j8
```
`GGML_RPC_RDMA=OFF` is required — JetPack 5's rdma-core is too old to compile the RDMA path (`ibv_query_gid_ex` undefined); TCP over gigabit is plenty. cmake must be ≥3.18 (grab a prebuilt aarch64 binary if `pip` is unavailable).

## Run

Board 2 (worker):
```bash
./rpc-server.sh           # caps power to 30W, serves the GPU on :50052
```

Board 1 (coordinator):
```bash
./serve-distributed.sh    # loads the 70B split across CUDA0 + RPC0, API on :8080
```

Board-1 env vars: `MODEL`, `RPC` (board 2 `host:port`), `CTX`, `TS` (split ratio `board1,board2`), `PORT`.

Test:
```bash
wget -qO- --post-data='{"messages":[{"role":"user","content":"hi"}],"max_tokens":40}' \
  --header='Content-Type: application/json' \
  http://192.168.68.62:8080/v1/chat/completions
```

## Boot (systemd)

Copy each script to its board's work dir, then install the units:
```bash
# board 2
sudo cp llama-rpc.service    /etc/systemd/system/ && sudo systemctl enable --now llama-rpc
# board 1
sudo cp llama-server.service /etc/systemd/system/ && sudo systemctl enable --now llama-server
```
Board 1's service retries until board 2's `rpc-server` is reachable. Boot both headless (`sudo systemctl set-default multi-user.target`) — the desktop eats ~4GB the model needs.

## Results

- ~21GB of weights per board; OpenAI-compatible API at `http://192.168.68.62:8080`.
- Both GPUs confirmed computing (GR3D 99% each, alternating — that's the pipeline).
- Throughput (board 2 capped at 30W): **~7.6 tok/s prompt, ~1.7 tok/s generation.** Slow — a 70B is memory-bandwidth-bound on Volta — but it runs a model neither board could hold alone.

## Scaling — pushing past 70B

We then loaded **Qwen2.5-72B-Instruct-Q4_K_M (47.4GB)** — the largest dense model that fits on two boards.

| Model | Size | Per board | TTFT (prefill) | Generation |
|---|--:|--:|--:|--:|
| Llama 3.3 70B Q4_K_M | 42.5GB | ~21.3GB | ~130 ms/tok | ~1.7 tok/s |
| Qwen2.5-72B Q4_K_M | 47.4GB | ~23.7GB | ~183 ms/tok (8.2s @ 45-tok prompt) | ~1.59 tok/s |

After the 72B loaded, each board still showed **~6GB `available`** — read the **`available`** column, not `free`. Linux keeps `free` low and holds reclaimable page cache; `available` (= free + reclaimable) is the real headroom. So the ceiling for two boards:

- **Combined weight budget ≈ 57GB** (~28.5GB usable per board) → about **85B at Q4_K_M**. A 90B at Q4_K_M (~59GB) is ~2GB over the line; it needs Q4_0 (~53GB) or Q3.
- **TTFT scales with prompt length** (~183 ms/token on the 72B): a 512-token prompt is ~90s to first token. Batch/agentic-friendly, rough for interactive.
- **A third RPC worker lifts the wall** — each board adds ~28GB, so three boards ≈ 85GB budget → a 90B at full Q4_K_M, or ~120B.

To run the 72B, set `MODEL=` to its path and use a tighter config (`-c 2048`, `-b 256 -ub 64`) — it fits with ~6GB/board to spare:
```bash
MODEL=/mnt/nvme/zen/llm/models/Qwen2.5-72B-Instruct-Q4_K_M.gguf CTX=2048 ./serve-distributed.sh
```

## Notes / gotchas

- **Memory — the "~10GB NvMap ceiling" is `mmap` double-counting, not hardware.** With `mmap` on (llama.cpp's default), a model is resident in RAM *twice* during load — the page-cached file plus the GPU buffer it's copied into (~2× its size). On a 30GB unified board that caps you near half (~10GB), and the `NvMapMemAllocInternalTagged: error 12` is plain ENOMEM, not a contiguity failure. **`--no-mmap` removes the duplicate**, so models up to ~24GB load full-GPU on one board (and the 70B's ~21GB half fits per board here). Proof — same board, `-ngl 99`, flushed: `Qwen2.5-Coder-32B-Q4_K_M` (18.48 GiB) **OOMs with `--mmap 1`, loads fine with `--mmap 0`**, on *both* the old (`871b0b7`) and new (`33c718d`) builds, so it's not the build or VMM. The Xavier GPU's SMMU/IOMMU maps scattered pages into a contiguous GPU address space, so no large physically-contiguous block is ever needed — which is why CMA/DTB tweaks were the wrong fix. (A raw `cudaMalloc` probe, `memprobe.cu`, reaches a 28GB single block after a flush — the allocator was never the limit.) Still flush page cache before loading.
- **Pass `-dev CUDA0,RPC0` explicitly.** Without it the loader puts the *whole* model on the remote device instead of splitting.
- **Bad ethernet cable → silent 100Mb/s.** `ethtool eth0` showed only `10baseT` advertised modes despite gigabit hardware. Check link speed *first* when RPC appears to "crash."
- **Marginal PSU → brownout under load.** Board 2 powered fully off (clean cut — empty `journalctl -b -1`, no panic/OOM/thermal) whenever it held a large model under MAXN. Fixed with a stronger 15V supply + the 30W power cap (`nvpmodel -m 3`) to keep peak draw down.

## Files

```
rpc-server.sh          board 2: power-cap + start rpc-server
serve-distributed.sh   board 1: load 70B split across CUDA0 + RPC0
llama-rpc.service      board 2 systemd unit
llama-server.service   board 1 systemd unit
memprobe.cu            CUDA allocation probe (nvcc -arch=sm_72 -o memprobe memprobe.cu)
```
