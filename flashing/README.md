# Jetson flashing

Flash a Jetson with NVIDIA **L4T**, natively (no Docker), from any modern
Linux host. Single-script flow (`native_flash.sh`) that downloads + extracts +
overlays + flashes. Used to (re)flash the cluster boards — including the 16GB
AGX Xavier that came with unknown credentials and had to be reflashed for
access.

## Prerequisites

- Target board in **recovery / APX mode** — power on holding the recovery
  (FORCE_REC) button; confirm with `lsusb -d 0955:` showing `0955:7019`
  (`7019` = APX/recovery; `7020` = normal booted L4T → not ready to flash).
- root (the script enforces `id -u == 0`).
- ~25 GB free in `WORKDIR` for the BSP + rootfs + extracted tree.

## Run

```bash
sudo ./native_flash.sh                                       # AGX Xavier, L4T 35.6.0
sudo BOARD=jetson-xavier-nx-devkit-emmc ./native_flash.sh    # Xavier NX
sudo WORKDIR=/mnt/big/jetson-flash ./native_flash.sh         # cache tarballs elsewhere
```

`native_flash.sh` is idempotent — re-running skips already-done steps (download
cached, BSP extracted, `apply_binaries` run). To pre-stage (or refresh) the
tarballs on their own — without flashing:

```bash
./download-l4t.sh                            # L4T 35.6.0 -> ./
L4T_VER=35.5.0 L4T_REL_DIR=r35_release_v5.0 ./download-l4t.sh
WORKDIR=/mnt/big/jetson-flash ./download-l4t.sh
```

The downloader is resumable and verifies each file against the server's size,
so re-running is a cheap "already have it, ok" check. **If a tarball already
exists locally it is reused** (verified by size when online; trusted as-is when
offline) — only missing or size-mismatched files are (re)downloaded.

`WORKDIR` defaults to **this `flashing/` directory**, so the ~2.3 GB tarballs
and the extracted `Linux_for_Tegra/` tree live next to the scripts. They're
gitignored (`*.tbz2`, `Linux_for_Tegra/`, `work/`) and never committed. Point
`WORKDIR` elsewhere if you'd rather not keep 2.3 GB inside the repo checkout.

Env knobs: `BOARD`, `TARGET` (default `mmcblk0p1`), `WORKDIR`
(default this directory), `L4T_VER` + `L4T_REL_DIR` (default `35.6.0` /
`r35_release_v6.0`).

## What it does

1. Verifies the board is in recovery mode (`lsusb 0955:7019`).
2. Installs host flash prereqs — idempotent, most are already on modern Ubuntu.
3. Downloads (and caches) NVIDIA's official L4T tarballs via `download-l4t.sh`:
   - `Jetson_Linux_R<ver>_aarch64.tbz2` — BSP: bootloader + kernel + drivers +
     flashing tools + board configs.
   - `Tegra_Linux_Sample-Root-Filesystem_R<ver>_aarch64.tbz2` — base Ubuntu
     20.04 aarch64 rootfs.
4. Extracts BSP + rootfs into `Linux_for_Tegra/` (skipped if already present).
5. Runs `apply_binaries.sh` to overlay NVIDIA drivers onto the rootfs (skipped
   if already applied).
6. Patches one DSA-related L4T regression (see Notes).
7. Invokes the real L4T `flash.sh <board> <target>`.

The flash is **destructive** — it wipes the board's eMMC and installs a fresh
OS. Takes ~20–30 min; don't interrupt it.

## Notes

- **Why native (no Docker)**: on modern hosts (e.g. Ubuntu 25.10 + kernel
  6.17), `lsusb` inside *any* Ubuntu container (20.04, 22.04, 24.04) fails with
  `mprotect`/`mseal` denials from the new kernel's memory-protection
  restrictions. NVIDIA's tegra binaries (`tegradevflash_v2`, `tegrabct_v2`,
  `tegrarcm_v2`, `tegrahost_v2`) link cleanly against modern Ubuntu's libs
  (verified with `ldd`) — the Ubuntu 20.04 *userland* requirement is a tested
  config, not a hard kernel-level one.
- **DSA patch**: includes one idempotent sed patch for an L4T regression.
  OpenSSH 9.x refuses to generate DSA keys (deprecated), which silently breaks
  L4T's `ota_make_recovery_img_dtb.sh` (the failure is hidden by `2>&1`, but
  `check_error` aborts with `command is failed`). The script replaces the DSA
  line with a no-op so the recovery image still builds — modern systems
  wouldn't ship a DSA host key anyway.
- Keep `WORKDIR` **outside this repo** if you don't want the ~2.3 GB tarballs +
  extracted tree inside the checkout. They're gitignored anyway.
- `0955:7019` is shared across the Xavier family; the **board config** you pass
  (`BOARD=`) is what selects the right partition layout — get it right.
- **Don't interrupt the flash.** If you do, the bootloader can be left in a
  half-written state where USB still advertises `0955:7019` but the board
  stops responding to ECID probes (`Error: probing the target board failed`).
  Recovery is hardware-enforced: unplug power, wait, hold REC + power on,
  release. The board re-enters recovery cleanly and you can re-run from scratch.

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
