# Audio Test — Renesas RZ/V2H EVK

Complete guide: connect the **RZ/V2H EVK** to a **Windows PC** and run a USB microphone — **without reflashing the kernel**.

This project enables USB audio that is missing from the stock VLP image (kernel `6.1.141-cip43-yocto-standard` was built without `CONFIG_SND_USB_AUDIO` and without an audio gadget). The kernel modules are rebuilt as *loadable modules* in WSL2 and `insmod`-ed on the EVK.

Two working, verified modes:

| Mode | Direction | EVK role | Result |
|------|-----------|----------|--------|
| **A. USB Mic → PC** | A USB mic plugged into the EVK, its audio streamed to the PC | USB **host** | PC plays/records sound from the "ME6S" mic |
| **B. EVK → USB Mic on PC** | The EVK itself appears as a USB microphone | USB **device/gadget** | PC sees "Microphone (moilmeet)" |

> A deep technical write-up is in [TECHNICAL_REPORT.md](TECHNICAL_REPORT.md).

---

## Table of Contents
1. [Prerequisites](#1-prerequisites)
2. [Topology](#2-topology)
3. [Step 1 — PC ↔ EVK network](#3-step-1--pc--evk-network)
4. [Step 2 — Mode A: USB Mic → PC](#4-step-2--mode-a-usb-mic--pc)
5. [Step 3 — Mode B: EVK as a USB Mic](#5-step-3--mode-b-evk-as-a-usb-mic)
6. [Rebuilding the modules (WSL2)](#6-rebuilding-the-modules-wsl2)
7. [File layout](#7-file-layout)
8. [Troubleshooting](#8-troubleshooting)
9. [Limitations](#9-limitations)

---

## 1. Prerequisites

**Hardware**
- RZ/V2H EVK (SoC r9a09g057h44), rz-vlp image (kernel `6.1.141-cip43-yocto-standard`).
- Direct Ethernet cable PC ↔ EVK.
- USB microphone "ME6S" (VID:PID `0C76:9688`) — for Mode A/B.
- A **data** micro-USB cable (not charge-only) — for Mode B (to connector **CN2**).

**On the PC (Windows)**
- **Git for Windows** (provides Git Bash) — `C:\Program Files\Git\...`.
- **FFmpeg/ffplay**: `winget install Gyan.FFmpeg`.
- Private SSH key at `C:\Users\User\.ssh\evk_rzv2h` (logs in as `weston`).
- *(Optional, only to rebuild modules)* WSL2 + Ubuntu + aarch64 toolchain.

---

## 2. Topology

```
                Ethernet (static IP)
   PC 192.168.10.1  <───────────────>  EVK 192.168.10.2 (end1)
        │  SSH (weston)                       │
        │                                     │
   ┌────┴─────────── MODE A ──────────────────┴────┐
   │  ME6S mic ─(USB host)→ EVK ─(arecord|ffplay)→ PC speaker │
   └───────────────────────────────────────────────┘

   ┌──────────────── MODE B ───────────────────────┐
   │  ME6S mic → EVK → (UAC2 gadget on CN2) ─USB→ PC "Microphone (moilmeet)" │
   └───────────────────────────────────────────────┘
```

---

## 3. Step 1 — PC ↔ EVK network

The EVK is cabled directly to the PC's **"Ethernet 2"** adapter (no router/DHCP), using static IPs.

### 3a. PC IP (PowerShell **as Administrator**)
```powershell
New-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress 192.168.10.1 -PrefixLength 24
```
> Requires UAC. Re-run after each reboot unless made persistent.

### 3b. EVK IP (via serial console / root)
RZ/V2H uses `end0`/`end1` (not `eth0`); use **`end1`** (`end0` is NO-CARRIER):
```bash
ip addr add 192.168.10.2/24 dev end1
ip link set end1 up
```
> Needs root, and **must be re-applied every time the EVK reboots** (not persistent).

### 3c. Test SSH (Git Bash on the PC)
```bash
ping 192.168.10.2
ssh -i /c/Users/User/.ssh/evk_rzv2h weston@192.168.10.2 'uname -r'
# -> 6.1.141-cip43-yocto-standard
```
Login is **passwordless** using an ed25519 key (`weston` already has `authorized_keys`).

---

## 4. Step 2 — Mode A: USB Mic → PC

The USB mic is plugged into an **EVK USB-A host port**. The stock kernel lacks the `snd-usb-audio` driver, so we load it.

### 4a. Load the driver (once per EVK boot)
```bash
cd "/c/habb/projects/Audio Test RZ v2h"
./usb-mic-test.sh load        # scp the 4 modules + insmod in order
./usb-mic-test.sh check       # should show "card 1: ME6S"
```
Modules load in order: `snd-hwdep → snd-rawmidi → snd-usbmidi-lib → snd-usb-audio`.

### 4b. Listen / record
```bash
./usb-mic-test.sh stream      # live mic -> PC speaker (Ctrl+C to stop)
./usb-mic-test.sh stream 6    # 6 seconds only
./usb-mic-test.sh latency     # low latency
./usb-mic-test.sh record 5 out.wav   # record 5s to a file on the PC
./usb-mic-test.sh level 3     # signal test: peak/RMS dBFS
```
The ME6S mic = `card 1`, capture at **48000 Hz mono S16_LE** (`hw:1,0`).

### 4c. GUI app (double-click)
Run **`MicEVK.bat`** — a GUI with *Turn On / Turn Off / Check / Test Signal / Record* buttons, sample-rate selection, and a low-latency mode. (Stop kills the ffplay/ssh processes by signature, not by the launcher PID.)

---

## 5. Step 3 — Mode B: EVK as a USB Mic

The EVK appears as a **USB microphone** to the PC via a UAC2 gadget. The physical ME6S mic audio is bridged into the gadget with `alsaloop`.

### 5a. Physical connection — important
- Connect **CN2** (the **micro-AB** connector, USB2.0 Ch0) on the EVK to a PC USB port with a **data** micro-USB cable.
- **NOT CN12** — that is the serial-debug port (USB-UART), not the device port.
- Charge-only cables will not be detected.

### 5b. Bring up the gadget + bridge (Git Bash)
```bash
cd "/c/habb/projects/Audio Test RZ v2h"
./usb-gadget-mic.sh up        # load gadget (mic mode) + start the alsaloop bridge
./usb-gadget-mic.sh status    # UDC state should be "configured (high-speed)"
```
On the PC, select the recording device **"Microphone (moilmeet)"** (USB `1d6b:4d01`).

> **Renaming the mic:** the display name is the UAC2 `function_name` **baked into `usb_f_uac2.ko`** (patched from the default "Source/Sink" to "moilmeet" in `drivers/usb/gadget/function/f_uac2.c`, line ~2185). To use a different name you must edit that string and rebuild (see §6), then bump `USB_PID` in `usb-gadget-mic.sh` — Windows caches the endpoint name per USB VID:PID, so a fresh PID forces it to re-read the new name. `iProduct`/manufacturer are set via the `g_audio` module params in the script.

### 5c. Test from the PC
```bash
./usb-gadget-mic.sh pc-test   # record 5s from the gadget mic + measure level
```

### 5d. Tear down
```bash
./usb-gadget-mic.sh down       # stop bridge + unload gadget (frees CN2)
```

**Direction note (important):** the `g_audio` parameter `p_chmask=1` means direction *gadget→host* = **microphone** (not `c_*`, which is a speaker). USBHS only has ~2 isochronous pipes → the gadget is configured **one direction (mic)** only. The bridge must use **`alsaloop`** (clock-drift compensation); a plain `arecord | aplay` pipe yields silence.

---

## 6. Rebuilding the modules (WSL2)

Only needed if the kernel changes or the modules are lost. Condensed (details in [TECHNICAL_REPORT.md](TECHNICAL_REPORT.md)):

```bash
# in WSL2 Ubuntu
sudo apt-get install -y build-essential bc bison flex libssl-dev libelf-dev \
                        gcc-aarch64-linux-gnu git kmod cpio
git init linux && cd linux && git remote add origin \
   https://github.com/renesas-rz/rz_linux-cip.git
git fetch --depth 1 origin 6717c06c72df7430323d0d48258ae4090f2d76aa
git checkout FETCH_HEAD
cp <evk_kernel_config> .config
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
# Mode A:
./scripts/config --module SND_USB_AUDIO
# Mode B:
./scripts/config --module USB_AUDIO
# vermagic must be EXACTLY "6.1.141-cip43-yocto-standard":
./scripts/config --set-str LOCALVERSION '-yocto-standard'
./scripts/config --disable LOCALVERSION_AUTO
rm -rf .git; printf '' > .scmversion
make olddefconfig && make -j"$(nproc)" modules_prepare && make -j"$(nproc)" modules
```
Kernel source: `renesas-rz/rz_linux-cip` @ `rz-6.1-cip43` (SRCREV `6717c06…`).

---

## 7. File layout

```
Audio Test RZ v2h/
├─ README.md                 ← this document
├─ TECHNICAL_REPORT.md       ← detailed technical report
├─ .gitignore
│
├─ usb-mic-test.sh           ← Mode A CLI (check/load/stream/latency/record/level/stopdev)
├─ usb-mic-test.bat          ← Mode A CLI launcher
├─ MicEVK.ps1 / MicEVK.bat   ← Mode A GUI app
│
├─ usb-gadget-mic.sh         ← Mode B: up/status/down/pc-test
│
├─ usb-audio-modules/        ← Mode A modules (prebuilt) + evk_kernel_config
│   ├─ snd-hwdep.ko  snd-rawmidi.ko  snd-usbmidi-lib.ko  snd-usb-audio.ko
│   └─ evk_kernel_config
└─ usb-gadget-modules/       ← Mode B modules (prebuilt)
    └─ libcomposite.ko  u_audio.ko  usb_f_uac2.ko  g_audio.ko
```

---

## 8. Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `ping` to EVK fails | PC IP (`192.168.10.1`) lost after reboot → re-run `New-NetIPAddress` (admin). EVK IP on `end1` is lost every reboot → re-apply via serial. |
| SSH asks for a password | Wrong/missing key; ensure `-i /c/Users/User/.ssh/evk_rzv2h` and the pubkey is in `weston@…:~/.ssh/authorized_keys`. |
| `insmod: command not found` | `insmod` lives in `/usr/sbin/` (outside `weston`'s PATH) — the scripts already use the full path. |
| Mode A: no `card 1` | Run `./usb-mic-test.sh load` again; confirm the mic is plugged into a USB-A port. |
| Mode A: `arecord -r 48000` I/O error | That is the onboard audio (broken, SSI clock bug). For the USB mic use `hw:1,0` at 48000 — that works. |
| Mode B: UDC stays `not attached` | Wrong connector (must be **CN2**, not CN12) or a charge-only cable. Try a data cable. |
| Mode B: PC records silence | Don't use a plain pipe — use `alsaloop` (`./usb-gadget-mic.sh up`). Record at native 48000 mono. |
| Mode B: `afunc_bind:1261 / -19` | Gadget was configured bidirectional; USBHS only fits one direction. The script already sets mic-only (`p_chmask=1 c_chmask=0`). |
| `vermagic` mismatch on insmod | Modules built for a different kernel; rebuild (see §6) so it is `6.1.141-cip43-yocto-standard`. |

---

## 9. Limitations

- **Not persistent across EVK reboots**: `/lib/modules` is empty → modules must be `insmod`-ed again, and the `end1` IP must be re-applied. To make it permanent: copy the `.ko` into `/lib/modules/$(uname -r)/` + `depmod`, or add them to the Yocto image.
- **Onboard audio (DA7213) is dead** — an SSI clock `-110` bug in the BSP, out of scope for this project.
- **Mode B is one-way** (mic only) due to the USBHS isochronous-endpoint limit.
- Modules are built with gcc 15 vs the kernel's gcc 13.4; this is safe because `MODVERSIONS` is off (only `vermagic` is validated).
