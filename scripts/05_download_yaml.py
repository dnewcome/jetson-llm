#!/usr/bin/env python3
"""Download all llamacpp models from models.yaml.
Run on the Jetson: python3 /data/george/05_download_yaml.py
"""

import os
import subprocess
import sys
import yaml

MODELS_DIR = "/data/george/models"
YAML_PATH = "/data/george/models.yaml"
HF_BASE = "https://huggingface.co"


def hf_url(repo, filename):
    return f"{HF_BASE}/{repo}/resolve/main/{filename}"


def download(repo, filename, dest):
    if os.path.exists(dest):
        mb = os.path.getsize(dest) // (1024 * 1024)
        if mb > 50:
            print(f"  already have {os.path.basename(dest)} ({mb} MB), skipping")
            return True
        else:
            print(f"  found tiny file ({mb} MB), re-downloading")

    url = hf_url(repo, filename)
    print(f"  -> {url}")
    # -C - resumes a partial download if dest exists
    cmd = ["curl", "-L", "-C", "-", "--progress-bar", "-o", dest, url]
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"  ERROR: curl exited {result.returncode}")
        return False
    return True


def main():
    with open(YAML_PATH) as f:
        config = yaml.safe_load(f)

    models = config.get("llamacpp", [])
    print(f"Models to download: {len(models)}")
    os.makedirs(MODELS_DIR, exist_ok=True)

    ok, failed = 0, []
    for m in models:
        name = m["name"]
        dest = os.path.join(MODELS_DIR, m["file"])
        print(f"\n[{name}]")
        if download(m["repo"], m["file"], dest):
            ok += 1
        else:
            failed.append(name)

    print(f"\n{'='*50}")
    print(f"Downloaded/skipped: {ok}/{len(models)}")
    if failed:
        print(f"Failed: {', '.join(failed)}")


if __name__ == "__main__":
    main()
