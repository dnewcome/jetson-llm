# Distributed 70B across two Jetson AGX Xavier

A 42.5GB model (Llama 3.3 70B, Q4_K_M) doesn't fit on one 30GB board, so we split it across two with llama.cpp's **RPC backend**: board 1 holds ~half the layers on its GPU and streams activations to board 2, which holds the other half (pipeline parallelism).

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

## Notes / gotchas

- **Memory — the ~10GB ceiling is not a hardware limit.** Each board allocated a single ~21GB weight buffer, *above* the ~10GB single-contiguous-allocation ceiling documented for single-board runs (see [main README → Memory Constraints](../README.md#memory-constraints)). That ceiling looks like a **software-path artifact**, not silicon: a raw `cudaMalloc` probe (`memprobe.cu`) reached a **28GB single block** after a cache flush. What differed from the single-board benchmarks: newer llama.cpp build (`33c718d` vs `871b0b7`), **VMM left enabled** (no `GGML_CUDA_NO_VMM=1` — that workaround, needed on the old build, forces the physically-contiguous path that caps ~10GB), and `--no-mmap`. Still flush page cache before loading. Worth retesting big *single-board* loads on the newer build with VMM on before assuming partial offload is required.
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
