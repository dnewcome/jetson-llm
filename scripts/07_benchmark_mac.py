#!/usr/bin/env python3
"""
Benchmark each model via a fresh SSH session from the Mac.
Each model gets a clean CUDA context with no state from prior runs.

Usage: python3 scripts/07_benchmark_mac.py
"""

import os, re, subprocess, sys, yaml
from datetime import datetime

JETSON = "george@192.168.68.61"
JETSON_PASS = "jetson"
MODELS_DIR = "/data/george/models"
LLAMA_BENCH = "/data/george/llama.cpp/build/bin/llama-bench"

# Empirical bounds for GGML_CUDA_NO_VMM=1:
#   < LOW  → VMM pool works fine, flag not needed
#   LOW–HIGH → disable VMM to avoid scratch-buffer OOM
#   > HIGH → over NvMap ceiling regardless of flag
NO_VMM_LOW_GB  = 7.0
NO_VMM_HIGH_GB = 9.2


def ssh(remote_cmd, timeout=600):
    """Run a command on the Jetson and return its output."""
    script = (
        f"set timeout {timeout}\n"
        f"spawn ssh -o StrictHostKeyChecking=no {JETSON}\n"
        f'expect "password:"\n'
        f'send "{JETSON_PASS}\\r"\n'
        f'expect "$ "\n'
        f'send "{remote_cmd}\\r"\n'
        f'expect -timeout {timeout} "$ "\n'
        f'send "exit\\r"\n'
        f"expect eof\n"
    )
    r = subprocess.run(
        ["expect"], input=script, capture_output=True, text=True,
        timeout=timeout + 30
    )
    return r.stdout


def clean(text):
    """Strip terminal noise from expect output."""
    text = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', text)
    text = re.sub(r'\]0;[^\r\n]*', '', text)
    noise = [
        "Welcome to", "Documentation:", "Management:", "Support:",
        "system has been minimized", "restore", "Expanded Security",
        "updates can be applied", "standard security update",
        "To see these additional", "Learn more", "Last login",
        "not required on a system", "george@ubuntu", "$ exit",
        "logout", "Connection to", "password:", "spawn ssh",
    ]
    lines = [l for l in text.splitlines()
             if not any(n in l for n in noise) and l.strip()]
    return '\n'.join(lines)


def get_sizes():
    """Return {filename: bytes} for all .gguf files on the Jetson."""
    out = ssh(r"stat -c '%n %s' /data/george/models/*.gguf 2>/dev/null")
    sizes = {}
    for line in clean(out).splitlines():
        parts = line.strip().split()
        if len(parts) == 2 and parts[1].isdigit():
            sizes[os.path.basename(parts[0])] = int(parts[1])
    return sizes


def flush_mem():
    """Drop page cache and compact physical memory on the Jetson."""
    ssh("bash /data/george/flush_mem.sh", timeout=30)


def bench(model, size_bytes, fh):
    name      = model["name"]
    filename  = model["file"]
    ngl       = model.get("n_gpu_layers", 99)
    filepath  = f"{MODELS_DIR}/{filename}"
    gb        = size_bytes / 1024 ** 3

    no_vmm = NO_VMM_LOW_GB < gb <= NO_VMM_HIGH_GB
    env    = "env GGML_CUDA_NO_VMM=1 " if no_vmm else ""

    cmd = (
        f"{env}{LLAMA_BENCH} "
        f"--model {filepath} "
        f"--n-gpu-layers {ngl} "
        f"--threads 8 "
        f"--n-prompt 512 --n-gen 128 --repetitions 3"
    )

    flag_note = "  NO_VMM=1" if no_vmm else ""
    print(f"\n[{name}]  {gb:.1f} GB  ngl={ngl}{flag_note}")
    print("  flushing memory…", end=" ", flush=True)
    flush_mem()
    print("done")
    sys.stdout.flush()

    out = clean(ssh(cmd, timeout=600))
    print(out)
    sys.stdout.flush()

    fh.write(f"\n{'='*60}\n")
    fh.write(f"model: {name}\n")
    fh.write(f"file:  {filename}\n")
    fh.write(f"size:  {gb:.1f} GB  ngl={ngl}{flag_note}\n")
    fh.write(out + "\n")
    fh.flush()


def main():
    here      = os.path.dirname(os.path.abspath(__file__))
    yaml_path = os.path.join(here, '..', 'models.yaml')

    with open(yaml_path) as f:
        config = yaml.safe_load(f)
    models = config.get("llamacpp", [])

    print("Fetching file sizes from Jetson…")
    sizes = get_sizes()
    print(f"Found {len(sizes)} model files.\n")

    ts      = datetime.now().strftime("%Y%m%d_%H%M%S")
    outpath = os.path.join(here, '..', f'results_isolated_{ts}.txt')
    print(f"Results → {outpath}\n")

    with open(outpath, 'w') as fh:
        fh.write(f"Isolated benchmark — {datetime.now()}\n")
        for m in models:
            size = sizes.get(m["file"], 0)
            if not size:
                print(f"[{m['name']}] SKIP — not on Jetson")
                continue
            bench(m, size, fh)

    print(f"\nAll done. Results in {outpath}")


if __name__ == "__main__":
    main()
