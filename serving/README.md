# Serving — local Claude CLI backend on one Xavier

Run an Anthropic-compatible local LLM endpoint on a single Jetson Xavier (32GB),
usable by **Claude CLI**, Aider, Cline, Open WebUI, or any client that speaks
OpenAI or Anthropic chat APIs. Picked **Hermes-3-Llama-3.1-8B** after benchmarking
several alternatives — see [Why this model](#why-this-model) below.

## Hardware

| | |
|---|---|
| **Device** | NVIDIA Jetson AGX Xavier 32GB |
| **GPU** | Volta, sm_72, 512 CUDA cores |
| **Memory** | 32GB LPDDR4X unified |
| **CUDA** | 11.4 |
| **Build** | `llama.cpp` with `GGML_CUDA=ON CMAKE_CUDA_ARCHITECTURES=72` |

A single board only. The 3-board RPC cluster from [`../distributed-70b/`](../distributed-70b/)
isn't needed here — the 8B model + 128k context fits comfortably on one Xavier
with ~5GB RAM to spare, and distributing would only add gigabit-RPC latency
without enabling any context the model can actually use coherently.

## Run

```bash
# Download model once (~4.6GB)
wget -O /mnt/nvme/zen/llm/models/Hermes-3-Llama-3.1-8B-Q4_K_M.gguf \
  https://huggingface.co/bartowski/Hermes-3-Llama-3.1-8B-GGUF/resolve/main/Hermes-3-Llama-3.1-8B-Q4_K_M.gguf

# Launch the server
./serve-hermes.sh
```

Env knobs: `MODEL`, `LLAMA_BIN`, `HOST`, `PORT`, `LOG`. Defaults assume the
paths used elsewhere in this repo (`/mnt/nvme/zen/llm/...`).

Endpoint: `http://<board-ip>:8080`
- `/v1/messages` — Anthropic format (Claude CLI)
- `/v1/chat/completions` — OpenAI format (Aider, Cline, OpenWebUI)
- `/v1/models`, `/props`, `/slots` — info
- `/ui/` — built-in web chat UI

## Client: Claude CLI

```bash
export ANTHROPIC_BASE_URL=http://192.168.68.62:8080   # <-- use IP, see Gotchas
export ANTHROPIC_AUTH_TOKEN=no-auth                    # any non-empty string
claude
```

Claude CLI sends `model: claude-opus-4-X` by default; llama-server happily
serves whatever's loaded regardless of the requested model name, so no aliases
needed.

## Performance characteristics

Measured on a single Jetson Xavier 32GB with Hermes-3-Llama-3.1-8B-Q4_K_M,
this config (`-c 131072 -ctk q4_0 -ctv q4_0 --cache-ram 14336 --jinja`):

| | speed |
|---|--:|
| Prefill (GPU prompt processing) | **~130–170 tok/s** |
| Generation (single-slot) | **~20–25 tok/s** |

What that means for Claude CLI specifically:

| Turn | Tokens to prefill | TTFT |
|---|--:|--:|
| Cold first turn (full system prompt + tools + pansophia hook injection) | ~22k | **~165s** |
| Cached follow-up (~87% hit rate, only new message processed) | ~1k | **~8s** |
| Multi-turn long session, context stays cached | < 2k delta per turn | **~5–15s** |

The cold first turn is the unavoidable cost of Claude Code's ~22k-token system
prompt. After that, the in-process prompt cache (14GB pool, ~125 KB/token at
q4 = ~115k tokens of historical state) keeps follow-up turns fast as long as
the conversation prefix is unchanged.

## Tunables

`serve-hermes.sh` uses the config we landed on, but the knobs to play with:

| Flag | What it does | Why |
|---|---|---|
| `-c 131072` | per-slot context window | Llama-3.1 trained on 128k natively. Coherent up to this; degrades sharply beyond. |
| `-ctk q4_0 -ctv q4_0` | quantize KV cache to 4-bit | 4× smaller KV → 128k context fits in ~4GB instead of ~16GB. Negligible quality loss on Llama-family. |
| `--cache-ram 14336` | prompt-cache RAM pool (MB) | KV snapshots of past prompts; reused as prefixes for new requests. Bigger = better hit rate on multi-turn / multi-session. |
| `--no-mmap` | read weights straight to GPU | mmap on Xavier double-counts the model in RAM (page-cached file + GPU buffer) → ~2× cost. See root [`README.md`](../README.md). |
| `--jinja` | use GGUF's Jinja chat template | Required for tool calling to be parsed into structured `tool_use` blocks instead of raw text. |
| `-b 512 -ub 128` | prefill batch / micro-batch | Tuned for Xavier's compute. Higher `-ub` uses more VRAM, gains diminishing. |

## Why this model

Tried four configurations in order. Findings:

| Config | First-turn TTFT | Generation | Verdict |
|---|--:|--:|---|
| **Qwen2.5-72B-Q4_K_M, 3-board RPC, 128k YaRN** | **5+ min** prefill | ~1.5 tok/s | ✗ Deadlocks at 13 tokens on Claude Code's full tool set ([llama.cpp #/v1/messages bug](https://github.com/ggml-org/llama.cpp)) |
| Qwen3.6-35B-A3B MoE (single board) | ~280s | ~17 tok/s | ✗ GGUF template injects empty `<think></think>` markers → model emits 0 content. Fixable with `--chat-template-kwargs '{"enable_thinking":false}'` but other quirks remain. |
| Qwen2.5-Coder-32B (single board) | ~150s | ~12 tok/s | Untested with Claude CLI but should work; slower than Hermes. |
| **Hermes-3-Llama-3.1-8B-Q4_K_M** | **~165s** | **~20–25 tok/s** | ✓ Works, no template gotchas, plain ChatML, purpose-tuned for agentic tool calls. |

Hermes-3 is **NousResearch's fine-tune of Llama-3.1-8B** explicitly tuned for
ChatML tool calling and agentic loops. The base Llama-3.1 gives 128k context
for free. The Q4_K_M quant is ~4.6GB — small enough that single-board with
massive cache headroom is the obvious play.

Trade-off vs the larger models: noticeably less capable on hard reasoning
(novel algorithms, complex refactors). For "run bash, read file, edit, summarize,
follow tool-call protocol reliably" — which is most of Claude Code's actual
work — it's plenty.

## Gotchas (the ones that took hours to find)

- **mDNS hostnames break with Claude CLI's POSTs.** Discovery probes (HEAD,
  GET) from `Bun/1.3.14` resolve `dan-jetson-1.local` fine, but POSTs from
  Node's `undici` bypass nsswitch/avahi and fail with what looks like
  "connection refused". **Always use the IP** in `ANTHROPIC_BASE_URL`.
- **The big "system prompt" isn't all Claude.** Of the ~22k tokens that hit
  the server on first turn, only ~12–15k is Claude Code's actual prompt+tools.
  The rest is whatever you have injecting into prompts via hooks (e.g. our
  pansophia memory hook adds ~8–10k). Disabling the hook for local-model
  sessions cuts the first-turn from ~165s to ~95s.
- **llama-swap's default request timeout (~2m28s) kills slow prefills with a
  502.** Not a deadlock — just a proxy timeout firing before the legitimate
  ~3-min prefill finishes. **Run llama-server directly** instead of behind
  llama-swap for this model, since we only have one model loaded anyway.
- **Qwen3-family models inject `<think></think>` template markers by default,
  even with `--reasoning off`.** Model interprets the empty block as "thinking
  done" and immediately emits end-of-turn with zero content. Fix:
  `--chat-template-kwargs '{"enable_thinking":false}'`. Hermes-3 avoids this
  entirely — not a reasoning model, plain ChatML.
- **Claude CLI's `Bun/1.3.14` user agent does HEAD probes against `/`, `/ui/`,
  `/v1/models` for endpoint discovery before sending the actual POST.** Seeing
  HEAD probes in the log but no POST = client is connected but the POST is
  going somewhere else (usually the mDNS issue above).

## Files

- [`serve-hermes.sh`](serve-hermes.sh) — launch script with the tested config
- This README

## See also

- [`../README.md`](../README.md) — single-board benchmarks across many models
- [`../distributed-70b/`](../distributed-70b/) — 3-board RPC for a 70B+ model that won't fit on one Xavier
- [`../flashing/`](../flashing/) — native (no-Docker) L4T flashing for new boards
