# Audio Test — Renesas RZ/V2H EVK

Complete guide: connect the **RZ/V2H EVK** to a **Windows PC** and run a USB microphone — **without reflashing the kernel**.

This project enables USB audio that is missing from the stock VLP image (kernel `6.1.141-cip43-yocto-standard` was built without `CONFIG_SND_USB_AUDIO` and without an audio gadget). The kernel modules are rebuilt as *loadable modules* in WSL2 and `insmod`-ed on the EVK.

Three working, verified modes:

| Mode | Direction | EVK role | Result |
|------|-----------|----------|--------|
| **A. USB Mic → PC** | A USB mic plugged into the EVK, its audio streamed to the PC | USB **host** | PC plays/records sound from the "ME6S" mic |
| **B. EVK → USB Mic on PC** | The EVK itself appears as a USB microphone | USB **device/gadget** | PC sees "Microphone (MoilMeet)" |
| **B-duplex. EVK → USB Mic + Speaker** | The EVK is *both* a USB mic **and** a USB speaker at once | USB **device/gadget** | PC sees "Microphone (MoilMeet)" **and** "Speakers (MoilMeet)" |

> A deep technical write-up is in [doc/TECHNICAL_REPORT.md](doc/TECHNICAL_REPORT.md).
> The **speaker / full-duplex** addition has its own report: [doc/TECHNICAL_REPORT_SPEAKER.md](doc/TECHNICAL_REPORT_SPEAKER.md).
> A boot-to-audio runbook (incl. the dropbear/SSH gotcha) is in [doc/HOW_TO_RUN.md](doc/HOW_TO_RUN.md).
> The **video-conference / camera** integration has its own report: [doc/TECHNICAL_REPORT_VIDEOCONF.md](doc/TECHNICAL_REPORT_VIDEOCONF.md).

---

## Table of Contents
1. [Prerequisites](#1-prerequisites)
2. [Topology](#2-topology)
3. [Step 1 — PC ↔ EVK network](#3-step-1--pc--evk-network)
4. [Step 2 — Mode A: USB Mic → PC](#4-step-2--mode-a-usb-mic--pc)
5. [Step 3 — Mode B: EVK as a USB Mic](#5-step-3--mode-b-evk-as-a-usb-mic)
5b. [Step 3b — Mode B duplex: USB Mic + Speaker](#5b-step-3b--mode-b-duplex-usb-mic--speaker)
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
- *(Mode B duplex only)* a **USB speaker** (tested with a GeneralPlus `1B3F:2008`) plugged into an EVK USB-A port.

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
   │  ME6S mic → EVK → (UAC2 gadget on CN2) ─USB→ PC "Microphone (MoilMeet)" │
   └───────────────────────────────────────────────┘

   ┌──────────────── MODE B (duplex) ──────────────┐
   │  ME6S mic  → EVK → gadget playback ─USB→ PC "Microphone (MoilMeet)" │
   │  USB spkr ← EVK ← gadget capture  ←USB─ PC "Speakers (MoilMeet)"    │
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
On the PC, select the recording device **"Microphone (MoilMeet)"** (USB `1d6b:4d01`).

> **Renaming the mic:** the display name is the UAC2 `function_name` **baked into `usb_f_uac2.ko`** (patched from the default "Source/Sink" to "MoilMeet" in `drivers/usb/gadget/function/f_uac2.c`, line ~2185). To use a different name you must edit that string and rebuild (see §6), then bump `USB_PID` in `usb-gadget-mic.sh` — Windows caches the endpoint name per USB VID:PID, so a fresh PID forces it to re-read the new name. `iProduct`/manufacturer are set via the `g_audio` module params in the script.

### 5c. Test from the PC
```bash
./usb-gadget-mic.sh pc-test   # record 5s from the gadget mic + measure level
```

### 5d. Tear down
```bash
./usb-gadget-mic.sh down       # stop bridge + unload gadget (frees CN2)
```

**Direction note (important):** the `g_audio` parameter `p_chmask=1` means direction *gadget→host* = **microphone** (not `c_*`, which is a speaker). The bridge must use **`alsaloop`** (clock-drift compensation); a plain `arecord | aplay` pipe yields silence. `usb-gadget-mic.sh` runs the gadget **mic-only** (`c_chmask=0`); for mic **and** speaker together see §5b.

---

## 5b. Step 3b — Mode B duplex: USB Mic + Speaker

The EVK appears as **both** a USB microphone **and** a USB speaker at the same time.
The PC gets **"Microphone (MoilMeet)"** (EVK mic → PC) and **"Speakers (MoilMeet)"**
(PC → the USB speaker attached to the EVK).

### 5b-1. Why this needs a patched module
USBHS has only ~2 isochronous pipes. A standard UAC2 capture is *asynchronous* and adds
an ISO-IN **feedback** endpoint, so mic (1 IN) + speaker (1 OUT) + feedback (1 IN) = 3
endpoints → the gadget fails to bind: `afunc_bind:1261 / failed to start g_audio: -19 /
couldn't find an available UDC`.

The fix (already built into `usb-gadget-modules/usb_f_uac2.ko`): the module is rebuilt with
the capture default switched to **adaptive** —
`UAC2_DEF_CSYNC = USB_ENDPOINT_SYNC_ADAPTIVE` in `drivers/usb/gadget/function/u_uac2.h`.
Adaptive capture drops the feedback endpoint (`EPOUT_FBACK_IN_EN()` → false; `u_audio.c`
already guards for a missing feedback ep), so mic (1) + speaker (1) = **2 endpoints → fits**.
The legacy `g_audio` can't set `c_sync` via a module param (`unknown parameter 'c_sync'
ignored`), so the header default is the only lever; only `usb_f_uac2.ko` is rebuilt. `alsaloop`
absorbs the resulting clock drift (benign over/underrun logs).

### 5b-2. Physical connection
- **CN2** micro-USB **data** cable to the PC (as in Mode B).
- Plug **both** the **ME6S mic** and the **USB speaker** into EVK USB-A ports.

### 5b-3. Bring up + tear down (Git Bash)
```bash
cd "/c/habb/projects/Audio Test RZ v2h"
./usb-gadget-duplex.sh up       # load duplex gadget + 2 alsaloop bridges
./usb-gadget-duplex.sh status   # UDC state, cards, source/sink, bridge count (expect 2)
./usb-gadget-duplex.sh down     # stop bridges + unload gadget (frees CN2)
```
It **auto-detects** the mic (ME6S), speaker (GeneralPlus "USB Audio Device") and gadget
cards each run, so card numbers may shift freely between reboots. Override if needed:
```bash
MIC_CARD=plughw:2,0 SPK_CARD=plughw:1,0 ./usb-gadget-duplex.sh up
```

### 5b-4. Use / verify on the PC
Pick **"Microphone (MoilMeet)"** for input and **"Speakers (MoilMeet)"** for output in any
app. To confirm both endpoints are active (PowerShell):
```powershell
Get-PnpDevice -Class AudioEndpoint |
  Where-Object { $_.FriendlyName -match 'MoilMeet' -and $_.Status -eq 'OK' } |
  Select Status,FriendlyName
```
The mic is loaded as `p_chmask=1` (mono) and the speaker as `c_chmask=3` (stereo), both at
48000 Hz, with a fresh USB PID `0x4d05` so Windows builds fresh endpoint names.

### 5b-5. Audio quality (avoiding crackle)
Duplex runs **two** `alsaloop` bridges, each crossing an independent USB clock domain. With
tiny default buffers they generate constant over/underruns → audible crackle. The script sets
a **150 ms ring buffer + sample-shift sync** (`-t 150000 -S 2/3`), cutting steady-state xruns
from thousands/sec to ≈0. If artifacts remain, raise the buffer (more latency, fewer xruns):
```bash
TLAT=300000 ./usb-gadget-duplex.sh up      # 300 ms
```

### 5b-6. Clean device name — removing the Windows "N-" prefix
Windows prepends a counter (e.g. "Speakers (3- MoilMeet)") when several **stale/ghost** MoilMeet
device instances remain — one per past USB PID. For a clean **"MoilMeet"** with no prefix, remove
the ghosts then reconnect:
```powershell
# run as Administrator:
powershell -ExecutionPolicy Bypass -File cleanup-moilmeet-devices.ps1
```
Then `./usb-gadget-duplex.sh down && ./usb-gadget-duplex.sh up`. The script `pnputil
/remove-device`s every present+ghost MoilMeet node so the fresh gadget enumerates as instance
#1. (It also attempts to delete stale MMDevices registry keys; that step may print "access not
allowed" and is safe to ignore — removing the *devices* is what clears the prefix.)

---

## 6. Rebuilding the modules (WSL2)

Only needed if the kernel changes or the modules are lost. Condensed (details in [doc/TECHNICAL_REPORT.md](doc/TECHNICAL_REPORT.md)):

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
# Mode B duplex (mic+speaker in 2 iso pipes): edit the capture sync default
#   drivers/usb/gadget/function/u_uac2.h
#   -#define UAC2_DEF_CSYNC   USB_ENDPOINT_SYNC_ASYNC
#   +#define UAC2_DEF_CSYNC   USB_ENDPOINT_SYNC_ADAPTIVE
# then rebuild only usb_f_uac2.ko:
#   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/usb/gadget/function/usb_f_uac2.ko
#   aarch64-linux-gnu-strip --strip-debug drivers/usb/gadget/function/usb_f_uac2.ko
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
├─ doc/
│  ├─ TECHNICAL_REPORT.md              ← detailed technical report (Mode A + Mode B)
│  ├─ TECHNICAL_REPORT_SPEAKER.md      ← technical report for the speaker / full-duplex addition
│  ├─ TECHNICAL_REPORT_VIDEOCONF.md    ← technical report for the video-conference / camera integration
│  ├─ TECHNICAL_REPORT_VIDEOCONF_SLIDES.md ← slide-deck source for the above (+ .docx/.pptx exports)
│  └─ HOW_TO_RUN.md                    ← boot-to-audio runbook (network/SSH + all modes)
├─ .gitignore
│
├─ usb-mic-test.sh           ← Mode A CLI (check/load/stream/latency/record/level/stopdev)
├─ usb-mic-test.bat          ← Mode A CLI launcher
├─ MicEVK.ps1 / MicEVK.bat   ← Mode A GUI app
│
├─ usb-gadget-mic.sh         ← Mode B (mic-only): up/status/down/pc-test
├─ usb-gadget-duplex.sh      ← Mode B duplex (mic+speaker): up/status/down
├─ cleanup-moilmeet-devices.ps1 ← (Admin) remove ghost MoilMeet devices → clean name, no "N-" prefix
│
├─ usb-audio-modules/        ← Mode A modules (prebuilt) + evk_kernel_config
│   ├─ snd-hwdep.ko  snd-rawmidi.ko  snd-usbmidi-lib.ko  snd-usb-audio.ko
│   └─ evk_kernel_config
└─ usb-gadget-modules/       ← Mode B modules (prebuilt)
    ├─ libcomposite.ko  u_audio.ko  g_audio.ko
    ├─ usb_f_uac2.ko            ← PATCHED: "MoilMeet" name + adaptive c_sync (duplex)
    └─ usb_f_uac2.ko.async-bak  ← previous async build (mic-only)
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
| Mode B: `afunc_bind:1261 / -19` | Bidirectional gadget with an async-capture feedback ep needs 3 iso pipes; USBHS has ~2. Use mic-only (`usb-gadget-mic.sh`), or the duplex path (`usb-gadget-duplex.sh`) whose patched **adaptive** `usb_f_uac2.ko` drops the feedback ep so mic+speaker fit. |
| Duplex: bridge count < 2 / one side silent | A source card wasn't auto-detected. Check `./usb-gadget-duplex.sh status`, then force `MIC_CARD=plughw:X,0 SPK_CARD=plughw:Y,0 ./usb-gadget-duplex.sh up`. |
| Duplex: speaker not heard | Set **"Speakers (MoilMeet)"** as the Windows default playback device, then play audio. Gadget capture + USB-speaker substreams should show `state: RUNNING`. |
| `vermagic` mismatch on insmod | Modules built for a different kernel; rebuild (see §6) so it is `6.1.141-cip43-yocto-standard`. |

---

## 9. Limitations

- **Not persistent across EVK reboots**: `/lib/modules` is empty → modules must be `insmod`-ed again, and the `end1` IP must be re-applied. To make it permanent: copy the `.ko` into `/lib/modules/$(uname -r)/` + `depmod`, or add them to the Yocto image.
- **Onboard audio (DA7213) is dead** — an SSI clock `-110` bug in the BSP, out of scope for this project.
- **Mode B duplex uses adaptive (open-loop) capture** — the USBHS 2-iso-pipe limit forces dropping the capture feedback endpoint to fit mic+speaker, so the speaker path has no USB rate feedback; `alsaloop` compensates the clock drift (occasional over/underrun logs, no audible dropouts in testing). Plain mic-only Mode B keeps standard async capture.
- Modules are built with gcc 15 vs the kernel's gcc 13.4; this is safe because `MODVERSIONS` is off (only `vermagic` is validated).
