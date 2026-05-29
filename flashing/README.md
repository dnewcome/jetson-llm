# Jetson flashing

Flash a Jetson with NVIDIA **L4T** from a host that isn't Ubuntu 20.04, by
running the whole flow in a **privileged `ubuntu:20.04` Docker container** with
USB passthrough. Used to (re)flash the cluster boards (e.g. the 16GB AGX Xavier
with no known credentials → reflash to regain access).

## Prerequisites

- Target board in **recovery / APX mode** — power on holding the recovery
  (FORCE_REC) button; confirm with `lsusb -d 0955:` showing `0955:7019`
  (`7019` = APX/recovery; `7020` = normal booted L4T → not ready to flash).
- **Docker** usable without sudo (user in the `docker` group).
- ~25 GB free for the BSP + rootfs + extracted tree.

## Run

```bash
./flash.sh                                   # AGX Xavier, L4T 35.6.0
BOARD=jetson-xavier-nx-devkit-emmc ./flash.sh
WORKDIR=/mnt/big/jetson-flash ./flash.sh     # cache tarballs elsewhere
```

`flash.sh` downloads the tarballs on first run and reuses them after. To
pre-stage (or refresh) them on their own — without flashing:

```bash
./download-l4t.sh                            # L4T 35.6.0 -> ~/jetson-flash
L4T_VER=35.5.0 L4T_REL_DIR=r35_release_v5.0 ./download-l4t.sh
WORKDIR=/mnt/big/jetson-flash ./download-l4t.sh
```

It's resumable and verifies each file against the server's size, so re-running
is a cheap "already have it, ok" check. **If a tarball already exists locally it
is reused** (verified by size when online; trusted as-is when offline) — only
missing or size-mismatched files are (re)downloaded.

`WORKDIR` defaults to **this `flashing/` directory**, so the ~2.3 GB tarballs
and the extracted `Linux_for_Tegra/` tree live next to the scripts. They're
gitignored (`*.tbz2`, `Linux_for_Tegra/`, `work/`) and never committed. Point
`WORKDIR` elsewhere if you'd rather not keep 2.3 GB inside the repo checkout.

Env knobs: `BOARD`, `TARGET` (default `mmcblk0p1`), `WORKDIR`
(default `~/jetson-flash`), `L4T_VER` + `L4T_REL_DIR` (default `35.6.0` /
`r35_release_v6.0`), `IMAGE`.

## What it does

1. Verifies a board is in recovery mode.
2. Downloads (and caches) NVIDIA's official L4T tarballs:
   - `Jetson_Linux_R<ver>_aarch64.tbz2` — BSP: bootloader + kernel + drivers +
     flashing tools + board configs.
   - `Tegra_Linux_Sample-Root-Filesystem_R<ver>_aarch64.tbz2` — base Ubuntu
     20.04 aarch64 rootfs.
3. In a privileged `ubuntu:20.04` container (`run_flash.sh`): installs flash
   prerequisites, extracts BSP + rootfs, runs `apply_binaries.sh` (overlays the
   NVIDIA drivers onto the rootfs), then `flash.sh <board> <target>`.

The flash is **destructive** — it wipes the board's eMMC and installs a fresh
OS. Takes ~20–30 min; don't interrupt it.

## Notes

- Keep `WORKDIR` **outside this repo** — the tarballs (~2.3 GB) and extracted
  tree must not be committed. `work/` here is gitignored as a safety net.
- The container runs as root, so files it writes under `WORKDIR` may be
  root-owned; clean up with `sudo rm -rf` or a throwaway root container.
- `0955:7019` is shared across the Xavier family; the **board config** you pass
  (`BOARD=`) is what selects the right partition layout — get it right.
- **Don't interrupt the flash.** If you do, the bootloader can be left in a half-
  written state where USB still advertises `0955:7019` but the board stops
  responding to ECID probes (`Error: probing the target board failed`). Recovery
  is hardware-enforced: unplug power, wait, hold REC + power on, release. The
  board re-enters recovery cleanly and you can re-run from scratch.

## First boot — headless over USB serial (no HDMI needed)

After the flash, the board reboots out of recovery and appears on USB as
`0955:7020 NVIDIA Corp. L4T running on Tegra`. The **same USB-C cable used for
flashing** exposes a CDC serial console at `/dev/ttyACM0` on the host — so the
`nv-oem-config` first-boot wizard is reachable without HDMI/keyboard:

```bash
sudo apt install -y screen           # or picocom / minicom
sudo screen /dev/ttyACM0 115200
```

Press Enter to wake the wizard, then walk through locale / timezone / keyboard
/ hostname / **user creation** (use `george` to match the other boards) / 
password. Detach with `Ctrl-A K` (kill the screen session, releases the serial)
or `Ctrl-A D` (detach without killing — reattach later with `sudo screen -r`).

Once the wizard finishes, `sshd` is enabled by default; SSH in over the LAN IP
and the board is ready to provision.

## Native flash (without Docker)

On hosts where Docker can't run the L4T flow cleanly — e.g. **Ubuntu 25.10 /
kernel 6.17**, where `lsusb` inside *any* Ubuntu container (20.04, 22.04, 24.04)
fails with `mprotect`/`mseal` denials from the new kernel's memory-protection
restrictions — use `native_flash.sh` instead. It runs the same flash on the
host, reusing the BSP + extracted tree the Docker pass produced (steps 1–4 are
idempotent; this is step 5 done natively):

```bash
sudo ./native_flash.sh                                       # AGX Xavier
sudo BOARD=jetson-xavier-nx-devkit-emmc ./native_flash.sh    # Xavier NX
```

It enforces root, re-verifies recovery (`0955:7019`), `apt-get install`s the
host prereqs (idempotent — most are already on Ubuntu 25.10), then runs the
real L4T `flash.sh`. Why it works where Docker doesn't: NVIDIA's tegra binaries
(`tegradevflash_v2`, `tegrabct_v2`, `tegrarcm_v2`, `tegrahost_v2`) link cleanly
against modern Ubuntu's libs (verified with `ldd`) — the Ubuntu 20.04
*userland* requirement is a tested config, not a hard kernel-level one.

Includes one idempotent sed patch for an L4T regression on modern hosts:
**OpenSSH 9.x refuses to generate DSA keys** (deprecated), which silently
breaks L4T's `ota_make_recovery_img_dtb.sh` (the failure is hidden by `2>&1`,
but `check_error` aborts with `command is failed`). The script replaces the
DSA line with a no-op so the recovery image still builds — modern systems
shouldn't ship a DSA host key anyway.
