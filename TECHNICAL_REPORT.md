# Technical Report — Enabling USB Audio on the Renesas RZ/V2H EVK

| | |
|---|---|
| **Date** | 2 July 2026 (rev. 8 July 2026 — added Mode B duplex) |
| **Target** | Renesas RZ/V2H EVK (SoC r9a09g057h44) |
| **Kernel** | Linux `6.1.141-cip43-yocto-standard` (aarch64) |
| **Distro** | rz-vlp, Poky *scarthgap* 5.0.11 (kernel originally built with gcc 13.4.0) |
| **Method** | Out-of-tree loadable kernel modules, cross-built in WSL2 — **no kernel reflash** |
| **Outcome** | ✅ **Mode A**: USB mic works as ALSA `card 1`, streamed to PC. ✅ **Mode B**: EVK presents itself to the PC as a USB microphone named **"MoilMeet"**. ✅ **Mode B duplex**: with a patched (adaptive-capture) `usb_f_uac2.ko`, the EVK is simultaneously a USB **mic and speaker** ("MoilMeet") within the USBHS 2-pipe limit. |

---

## 1. Executive Summary

The stock RZ/V2H VLP kernel ships without USB Audio Class support in either direction: neither the host-side capture driver (`snd-usb-audio`) nor any USB audio *gadget* is compiled in, and the kernel is monolithic (no modules on the rootfs). Two capabilities were delivered without reflashing the kernel, by rebuilding the exact kernel source as **loadable modules** whose `vermagic` matches the running kernel and `insmod`-ing them over SSH:

- **Mode A — USB mic → PC.** A USB microphone plugged into an EVK host port is exposed as an ALSA capture card and streamed to the PC.
- **Mode B — EVK → USB mic on PC.** The EVK's USB device controller runs a UAC2 gadget, so the PC sees the EVK itself as a microphone ("MoilMeet"); the physical mic is bridged into that gadget.
- **Mode B duplex — EVK → USB mic + speaker on PC.** A one-line source patch (capture sync default → *adaptive*) removes the capture feedback endpoint, letting a **bidirectional** UAC2 gadget bind within the USBHS 2-iso-pipe budget. The PC then sees the EVK as both a microphone and a speaker ("MoilMeet"), with a physical USB speaker on the EVK as the sink (§6.10).

This is viable because the kernel configuration permits unsigned, unversioned modules (§3), reducing the compatibility requirement to a single exact-match string, `vermagic`.

---

## 2. Background and Problem Statement

### 2.1 Device under test
The USB microphone **"ME6S"** (VID:PID `0C76:9688`, a JMTek UAC device) enumerates correctly on the EVK and exposes valid USB Audio Class interfaces:

| Interface | Class/Subclass | Function |
|-----------|----------------|----------|
| `x-1:1.0` | 01/01 | AudioControl |
| `x-1:1.1` | 01/02 | AudioStreaming (playback) |
| `x-1:1.2` | 01/02 | AudioStreaming (capture) |
| `x-1:1.3` | HID (03) | buttons (bound to `usbhid`) |

Despite correct enumeration, **no ALSA card was created** — the audio interfaces had no driver bound.

### 2.2 Root cause
The running kernel config contains:
```
CONFIG_SND_USB=y
# CONFIG_SND_USB_AUDIO is not set     ← the snd-usb-audio driver is absent
```
`snd-usb-audio` is not compiled, and because the kernel is monolithic (`lsmod` empty, `/lib/modules` empty) `modprobe` is impossible.

### 2.3 Why not the onboard codec?
The onboard DA7213 codec is non-functional: the SoC fails to enable the SSI/I²S clock —
```
rcar_sound 13c00000.sound: failed to enable clk, error -110   (ETIMEDOUT)
```
This is a BSP/device-tree CPG-clock defect, not fixable from userspace; onboard capture yields digital silence (flat −91 dBFS). USB audio was chosen because it bypasses `rcar_sound`/SSI entirely and is therefore immune to the `-110` clock fault.

---

## 3. Design Rationale — Loadable Modules Without Reflash

The EVK kernel configuration makes out-of-tree modules loadable:

| Setting | Value | Implication |
|---------|-------|-------------|
| `CONFIG_MODULES` | `y` | Modules can be loaded |
| `CONFIG_MODVERSIONS` | not set | Symbol CRCs are **not** checked — only `vermagic` matters |
| `CONFIG_MODULE_SIG` | not set | Modules need no signature |
| `CONFIG_SND` / `CONFIG_SND_PCM` | `y` | ALSA core is built-in and exports the needed symbols |

**Consequence:** the *only* hard requirement for a module to load is that its `vermagic` string equals the running kernel's exactly:
```
6.1.141-cip43-yocto-standard SMP preempt mod_unload aarch64
```
The undefined-symbol warnings emitted by `modpost` during an out-of-tree build are benign here (no `Module.symvers` for the built-in objects, `MODVERSIONS` off), because those symbols are resolved at load time against the running kernel.

---

## 4. Build Environment (WSL2)

- Enabled the WSL2 platform on Windows (`wsl --install --no-launch`; a reboot activated the VM platform), then installed Ubuntu (WSL2, 12 vCPU, 7.7 GB RAM).
- Installed the cross toolchain and kernel build dependencies:
  ```bash
  apt-get install -y build-essential bc bison flex libssl-dev libelf-dev \
                     gcc-aarch64-linux-gnu git kmod cpio
  ```
- The aarch64 cross-compiler is gcc 15.2 versus the kernel's original gcc 13.4. This is safe because `MODVERSIONS` is off and the ABI-relevant structures come from the pinned kernel source; `vermagic` is the only gate.

### 4.1 Locating the exact kernel source
From the Yocto layer `meta-renesas`, branch `scarthgap/rz`, recipe
`meta-rz-bsp/recipes-kernel/linux/linux-renesas_6.1.bb`:

| Variable | Value |
|----------|-------|
| Repository | `github.com/renesas-rz/rz_linux-cip.git` |
| Branch | `rz-6.1-cip43` |
| `SRCREV` | `6717c06c72df7430323d0d48258ae4090f2d76aa` |
| `LINUX_VERSION` | `6.1.141-cip43` |

Shallow-fetched exactly that commit:
```bash
git init && git remote add origin https://github.com/renesas-rz/rz_linux-cip.git
git fetch --depth 1 origin 6717c06c72df7430323d0d48258ae4090f2d76aa
git checkout FETCH_HEAD
```

### 4.2 Base configuration
The EVK's live `.config` (previously pulled from `/proc/config.gz`) was used verbatim as the build base, so all ABI-affecting options match the running kernel. It is archived at `usb-audio-modules/evk_kernel_config`.

### 4.3 Matching `vermagic` (the subtle part)
Target release string: `6.1.141-cip43-yocto-standard`. Its components originate from:
- `EXTRAVERSION` in the Makefile is **empty** → base `6.1.141`.
- `-cip43` comes from a **`localversion-cip`** file in the source tree.
- `-yocto-standard` comes from `CONFIG_LOCALVERSION`.

A naïve first build produced the wrong string `6.1.141-cip43-cip43-yocto-standard+` (doubled `-cip43`, plus a trailing `+`). The fix:
```bash
./scripts/config --set-str LOCALVERSION '-yocto-standard'   # NOT -cip43-yocto-standard
./scripts/config --disable LOCALVERSION_AUTO                 # suppress git-derived suffix
rm -rf .git ; printf '' > .scmversion                        # remove trailing '+'
```
Result: `include/config/kernel.release` = **`6.1.141-cip43-yocto-standard`** ✓.

### 4.4 Build invocation
```bash
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make olddefconfig
make -j12 modules_prepare
make -j12 modules        # ~30 s — only obj-m targets are compiled
```

---

## 5. Mode A — USB Microphone → PC

### 5.1 Module set
Enabling `CONFIG_SND_USB_AUDIO=m` (via `./scripts/config --module SND_USB_AUDIO`) auto-selects `SND_HWDEP=m`, `SND_RAWMIDI=m`, and `snd-usbmidi-lib`. Four modules result, all with identical matching `vermagic`:
`snd-hwdep.ko`, `snd-rawmidi.ko`, `snd-usbmidi-lib.ko`, `snd-usb-audio.ko`.

```
$ modinfo snd-usb-audio.ko | grep vermagic
vermagic: 6.1.141-cip43-yocto-standard SMP preempt mod_unload aarch64   # exact match
```

### 5.2 Deployment
Networking is a direct Ethernet link (PC `192.168.10.1` ↔ EVK `192.168.10.2` on interface `end1`), passwordless SSH as `weston`. Modules are copied and inserted **in dependency order** (`insmod` lives in `/usr/sbin`, outside `weston`'s `PATH`):
```bash
scp *.ko weston@192.168.10.2:/tmp/
sudo /usr/sbin/insmod snd-hwdep.ko
sudo /usr/sbin/insmod snd-rawmidi.ko
sudo /usr/sbin/insmod snd-usbmidi-lib.ko
sudo /usr/sbin/insmod snd-usb-audio.ko
```
On registration the driver re-probes the already-enumerated ME6S, and **`card 1` appears immediately.**

### 5.3 Verification
```
$ cat /proc/asound/cards
 0 [rcarsound] : rcar-sound
 1 [ME6S]      : USB-Audio - ME6S ... full speed
$ arecord -l
card 1: ME6S [ME6S], device 0: USB Audio [USB Audio]
```
- **Capture capability:** mono, S16_LE @ 48000/96000/192000 Hz (also S24_3LE).
- **Signal test** (3 s capture, `hw:1,0` @ 48 kHz): `peak −11.7 dBFS, rms −29.8 dBFS` — real audio, in contrast to the onboard codec's flat −91 dBFS.
- **Streaming:** `ssh 'arecord -t raw' | ffplay -f s16le` plays live on the PC speaker (clean exit).

### 5.4 Tooling
- `usb-mic-test.sh` — CLI: `check | load | stream [secs] | latency | record | level | stopdev`.
- `MicEVK.ps1` / `MicEVK.bat` — WinForms GUI (Turn On/Off, sample-rate, Test Signal, Record). Start/Stop tracks the `ffplay`/`ssh` worker processes **by command-line signature**, because Git Bash's `bin\bash.exe` is a launcher stub that exits immediately (its PID cannot be used for teardown).

---

## 6. Mode B — EVK as a USB Microphone ("MoilMeet")

### 6.1 Capability analysis
The SoC exposes a USB device controller usable as a gadget:
```
/sys/class/udc/15820000.usb   (renesas_usbhs, dr_mode = otg)
```
Relevant kernel config: `CONFIG_USB_GADGET=y`, `CONFIG_USB_LIBCOMPOSITE=m`, **`CONFIG_USB_CONFIGFS` is not set**. Because configfs is unavailable, the **legacy `g_*` gadgets** (module + module-parameters) are used rather than a configfs-composed gadget.

### 6.2 Gadget module set
Enabling `CONFIG_USB_AUDIO=m` (`./scripts/config --module USB_AUDIO`) selects `USB_F_UAC2=m` and `USB_U_AUDIO=m`; `USB_LIBCOMPOSITE=m` was already present. Modules produced (matching `vermagic`):
`libcomposite.ko`, `u_audio.ko`, `usb_f_uac2.ko`, `g_audio.ko`.
Load order: `libcomposite → u_audio → usb_f_uac2 → g_audio`.

### 6.3 Direction semantics (non-obvious)
For the `g_audio` module parameters, direction is named **from the gadget's perspective**:
- `p_*` (**playback**) = *gadget → host* = **microphone** (the host records).
- `c_*` (**capture**) = *host → gadget* = **speaker** (the host plays).

On the EVK a **playback** PCM appears (e.g. `card 2: UAC2 PCM`, listed by `aplay -l`); userspace **writes** audio to it, and the host records that as its microphone input. Therefore mic mode uses `p_chmask=1 c_chmask=0`.

### 6.4 Endpoint constraint
The USBHS controller offers only ~2 isochronous-capable pipes. Enabling **both** directions (plus the feedback endpoint) exhausts them and the bind fails:
```
g_audio gadget.0: afunc_bind:1261 Error!
udc 15820000.usb: failed to start g_audio: -19        (ENODEV)
UDC core: g_audio: couldn't find an available UDC
```
Line 1261 of `f_uac2.c` is the *IN* endpoint autoconfig. In `usb-gadget-mic.sh` the gadget is therefore configured **single-direction (mic only)**, which binds successfully. The default bidirectional gadget needs **three** iso endpoints — mic IN, speaker OUT, and a capture **feedback** IN — because a standard UAC2 capture is *asynchronous*. §6.10 shows how switching the capture to *adaptive* removes the feedback endpoint, dropping the requirement to two and enabling a working mic **+** speaker gadget.

### 6.5 Physical connection
The peripheral controller `15820000.usb` is wired to connector **CN2** (a **micro-AB** jack, USB2.0 Ch0). Key facts established during bring-up:
- **Use CN2, not CN12.** CN12 is the serial-debug port (USB-UART bridge), unrelated to the SoC USB device controller.
- A **data-capable** micro-USB cable is required; charge-only cables produce no enumeration on either side.
- The device tree has `dr_mode=otg` but no `vbus-gpios` and reports "no transceiver found"; nonetheless VBUS supplied by the host on CN2 is detected. When the PC is connected:
  ```
  /sys/class/udc/15820000.usb/state → configured   (current_speed: high-speed)
  ```

### 6.6 Bridging the physical mic into the gadget
The ME6S mic and the gadget stream run on **independent clocks**. A naïve `arecord | aplay` pipe delivers pure silence (−91 dBFS) due to continuous under/overruns. The correct tool is **`alsaloop`**, which performs rate/clock-drift adaptation:
```bash
alsaloop -C plughw:1,0 -P plughw:2,0 -r 48000 -c 1 -f S16_LE
#          ^ ME6S (card 1)   ^ UAC2 gadget (card 2)
```
(It prints "overrun" warnings during adaptation but passes audio.)

### 6.7 Naming the microphone ("MoilMeet")
The name the host displays as *"Microphone (⟨name⟩)"* is the UAC2 **`function_name`** string, **hardcoded** in the driver — not the `iProduct` module parameter. In `drivers/usb/gadget/function/f_uac2.c` (~line 2185):
```c
scnprintf(opts->function_name, sizeof(opts->function_name), "Source/Sink");
```
This was patched to `"MoilMeet"` and `usb_f_uac2.ko` rebuilt. Two facts were established:
1. Setting `iProduct=MoilMeet` alone did **not** rename the mic — that string only names the parent device; the audio interface (MI_00) uses `function_name`.
2. **Windows caches the audio-endpoint friendly name per USB VID:PID** (MMDevices registry). After changing the string, the gadget must be loaded with a **fresh `idProduct`** or the stale cached name persists.

Final load parameters:
```bash
g_audio p_chmask=1 p_srate=48000 p_ssize=2 c_chmask=0 \
        idVendor=0x1d6b idProduct=0x4d01 \
        iManufacturer=Moil iProduct=MoilMeet iSerialNumber=MoilMeet-001
```

### 6.8 Verification
- `/sys/class/udc/15820000.usb/state = configured (high-speed)`.
- PC capture endpoint: **`Microphone (MoilMeet)`** (confirmed via `Get-PnpDevice` and `ffmpeg -f dshow -list_devices`).
- End-to-end audio: recording `Microphone (MoilMeet)` at native 48 kHz mono on the PC captured real speech (e.g. `max −24…−34 dBFS`), not silence. A fixed test tone fed to the gadget was also received cleanly, isolating the earlier silence to the clock-drift pipe (§6.6).
- Windows records dshow at its default 44.1 kHz/stereo unless told otherwise; capturing at the device's native **48000 Hz mono** avoided misleading results during bring-up.

### 6.9 Tooling
`usb-gadget-mic.sh` — `up | status | down | pc-test`. It deploys the gadget modules, loads `g_audio` in mic mode with the naming parameters, starts the `alsaloop` bridge, and (on `down`) tears everything down and frees CN2. `MIC_NAME`/`USB_PID`/… are overridable variables.

### 6.10 Mode B duplex — simultaneous USB mic **and** speaker

> A dedicated, self-contained write-up of this speaker/full-duplex work is in
> [TECHNICAL_REPORT_SPEAKER.md](TECHNICAL_REPORT_SPEAKER.md). The summary below is the condensed version.

**Goal.** Make the EVK present *both* a microphone and a speaker to the PC at once, so a
host application can capture from the ME6S mic **and** play audio out through a USB speaker
attached to the EVK — a single full-duplex UAC2 device.

**Obstacle (from §6.4).** A bidirectional gadget needs mic-IN + speaker-OUT + capture-
feedback-IN = 3 iso endpoints; USBHS provides ~2, so `g_audio p_chmask=1 c_chmask=1` fails
with `-19`. The feedback endpoint exists only because a UAC2 **asynchronous** capture reports
its clock back to the host.

**Root-cause lever.** In the kernel UAC2 function driver the feedback endpoint is gated by the
capture synchronization type:
```c
/* drivers/usb/gadget/function/f_uac2.c */
#define EPOUT_FBACK_IN_EN(_opts) ((_opts)->c_sync == USB_ENDPOINT_SYNC_ASYNC)
```
When `c_sync` is **adaptive** rather than **async**, `EPOUT_FBACK_IN_EN()` is false: the
feedback descriptor is omitted, the feedback endpoint is not autoconfigured, and the OUT
endpoint's `bmAttributes` is set to `USB_ENDPOINT_SYNC_ADAPTIVE`. `u_audio.c` already guards
every feedback-endpoint access with `if (audio_dev->in_ep_fback)`, so a NULL feedback ep is a
supported configuration. Endpoint count then drops to **mic-IN + speaker-OUT = 2**, which fits.

**Why a rebuild is required.** `c_sync` is a *configfs* attribute, but this image has
`CONFIG_USB_CONFIGFS` disabled and uses the **legacy** `g_audio` module, which exposes no
`c_sync` module parameter (`insmod … c_sync=adaptive` logs `unknown parameter 'c_sync'
ignored`). The only lever for the legacy path is the compile-time **default**:
```c
/* drivers/usb/gadget/function/u_uac2.h */
-#define UAC2_DEF_CSYNC   USB_ENDPOINT_SYNC_ASYNC
+#define UAC2_DEF_CSYNC   USB_ENDPOINT_SYNC_ADAPTIVE
```
Only `usb_f_uac2.ko` is rebuilt (the change lives in a header consumed by `f_uac2.c`; `u_audio.ko`
is unchanged). The existing "MoilMeet" `function_name` patch (§6.7) is retained in the same module.
```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     drivers/usb/gadget/function/usb_f_uac2.ko
aarch64-linux-gnu-strip --strip-debug .../usb_f_uac2.ko   # vermagic 6.1.141-cip43-yocto-standard
```

**Load parameters (bidirectional).** Mic mono, speaker stereo, fresh PID so Windows builds
fresh endpoint names:
```bash
g_audio p_chmask=1 p_srate=48000 p_ssize=2 \
        c_chmask=3 c_srate=48000 c_ssize=2 \
        idVendor=0x1d6b idProduct=0x4d03 \
        iManufacturer=Moil iProduct=MoilMeet iSerialNumber=MoilMeet-duo
```
The gadget card now exposes **both** a playback PCM (mic side) and a capture PCM (speaker side)
on device 0; `UDC state = configured`, no `-19`.

**Two bridges.** The gadget card is opened full-duplex by two `alsaloop` instances:
```bash
alsaloop -C plughw:<mic>,0    -P plughw:<gadget>,0 -c 1   # ME6S  → gadget playback (mic)
alsaloop -C plughw:<gadget>,0 -P plughw:<spk>,0    -c 2   # gadget capture → USB speaker
```

**Verification.**
- PC enumerates **both** `Microphone (MoilMeet)` and `Speakers (MoilMeet)` with `Status = OK`
  (`Get-PnpDevice -Class AudioEndpoint`).
- Mic path: recording `Microphone (MoilMeet)` captured real speech (`max −9.9 dBFS`).
- Speaker path: while the PC played a 440 Hz tone to `Speakers (MoilMeet)`, the EVK's gadget
  **capture** substream and the USB-speaker **playback** substream both showed `state: RUNNING`
  (`/proc/asound/card*/pcm*/sub0/status`), confirming end-to-end flow; the tone was audible on
  the physical USB speaker.

**Trade-off.** Adaptive capture has no USB rate feedback (open-loop); `alsaloop` compensates the
residual clock drift (benign over/underrun logs, no audible dropouts in testing). The USB speaker
used was a GeneralPlus device (`1B3F:2008`, ALSA "USB Audio Device").

**Audio-quality tuning.** The first duplex build crackled badly: with `alsaloop`'s small default
ring buffer, the two bridges (each crossing an independent USB clock domain) produced thousands of
over/underruns per second. Two `alsaloop` knobs fixed it: a **large ring buffer** (`-t 150000`, 150 ms)
to absorb drift, and **sample-shift sync** (`-S 2` captshift on the mic bridge, `-S 3` playshift on the
speaker bridge) to correct rate mismatch without inserting clicks. Measured steady-state xruns dropped
from ~4820/6820 log lines to **≈0** (only a startup transient). Higher `-t` (e.g. 300 ms via `TLAT=`)
trades latency for even more drift tolerance. (An external `samplerate` ALSA converter would allow the
higher-quality `-S 4`, but none is installed on the EVK.)

**Endpoint naming & the Windows "N-" prefix.** The mic/speaker friendly names were recapitalized to
**"MoilMeet"** (edit the `function_name` string in `f_uac2.c`, rebuild `usb_f_uac2.ko`, load with a fresh
`idProduct`). Separately, Windows prepends a disambiguation counter ("Speakers (3- MoilMeet)") when
multiple **ghost** device instances accumulate — one per past USB PID used during development. The
prefix is not part of the device name; removing every stale/ghost MoilMeet node with
`pnputil /remove-device` (script `cleanup-moilmeet-devices.ps1`, run elevated) lets the next connection
enumerate as instance #1, yielding a clean **"Microphone (MoilMeet)" / "Speakers (MoilMeet)"**. (Deleting
the orphaned MMDevices registry keys additionally requires taking ownership from SYSTEM; it was found
unnecessary — removing the device nodes alone cleared the prefix.)

**Tooling.** `usb-gadget-duplex.sh` — `up | status | down`. It deploys the patched module set,
loads `g_audio` bidirectionally, auto-detects the mic/speaker/gadget cards by name, and starts
both bridges with the tuned `alsaloop` settings. Card selection is overridable via `MIC_CARD`/`SPK_CARD`,
and buffer/sync via `TLAT`/`SYNC_MIC`/`SYNC_SPK`.

---

## 7. Results

| Capability | Status | Evidence |
|-----------|--------|----------|
| USB mic → EVK → PC (Mode A) | ✅ | `card 1: ME6S`; captured `−11.7 dBFS` peak; live `ffplay` stream |
| EVK → USB mic on PC (Mode B) | ✅ | UDC `configured`; PC shows `Microphone (MoilMeet)`; real audio recorded |
| EVK → USB mic **+ speaker** (Mode B duplex) | ✅ | patched adaptive `usb_f_uac2.ko`; PC shows `Microphone (MoilMeet)` **and** `Speakers (MoilMeet)` (both OK); mic `−9.9 dBFS`, speaker substreams `RUNNING` |
| No kernel reflash | ✅ | all functionality via `insmod` of `vermagic`-matched modules |

---

## 8. Limitations

- **Not persistent across EVK reboots.** `/lib/modules` is empty, so modules must be re-inserted, and the `end1` IP re-applied, after each boot. For permanence: install the `.ko` into `/lib/modules/$(uname -r)/` + `depmod`, or fold them into the Yocto image.
- **Onboard audio (DA7213) remains dead** — the SSI clock `-110` BSP defect is out of scope.
- **Mode B mic-only vs duplex.** The default (async) UAC2 gadget fits only **one** direction in the USBHS 2-iso-pipe budget (§6.4). Simultaneous mic+speaker (§6.10) is possible **only** with the rebuilt *adaptive-capture* `usb_f_uac2.ko`; on the stock module set the gadget must stay one-way.
- **Duplex capture is open-loop (adaptive).** Removing the feedback endpoint means no USB clock feedback on the speaker path; `alsaloop` masks the drift but this is less rigorous than standard async capture. Acceptable here; revisit if strict A/V sync is required.
- **Mic display name is baked into `usb_f_uac2.ko`** (§6.7); changing it requires editing `f_uac2.c`, rebuilding, and bumping `USB_PID` to defeat the Windows name cache.
- **gcc mismatch** (build gcc 15 vs kernel gcc 13.4) is safe only because `MODVERSIONS` is disabled; if a future image enables it, the modules must be rebuilt against that tree.

---

## 9. Reproduction & Artifacts

All under `C:\habb\projects\Audio Test RZ v2h\` (see [README.md](README.md) for the step-by-step run guide):

| Path | Contents |
|------|----------|
| `usb-audio-modules/` | Mode A modules (4× `.ko`) + `evk_kernel_config` |
| `usb-gadget-modules/` | Mode B modules (`libcomposite`, `u_audio`, `usb_f_uac2` [patched: name + adaptive], `g_audio`); `usb_f_uac2.ko.async-bak` = previous mic-only build |
| `usb-mic-test.sh` / `.bat` | Mode A CLI + launcher |
| `MicEVK.ps1` / `.bat` | Mode A GUI application |
| `usb-gadget-mic.sh` | Mode B mic-only orchestration (`up`/`status`/`down`/`pc-test`) |
| `usb-gadget-duplex.sh` | Mode B duplex mic+speaker orchestration (`up`/`status`/`down`); tuned `alsaloop` (`-t 150000 -S 2/3`) to kill cross-clock xruns |
| `cleanup-moilmeet-devices.ps1` | (Admin) removes ghost MoilMeet device instances so the endpoint name has no Windows "N-" prefix |
| `README.md` | End-user setup guide |
| `HOW_TO_RUN.md` | Boot-to-audio runbook (network/SSH + all modes) |
| `TECHNICAL_REPORT.md` | This report |
| `TECHNICAL_REPORT_SPEAKER.md` | Dedicated report for the speaker / full-duplex addition |

The WSL2 build tree at `/root/build/linux` can rebuild any module on demand.

### One-line summaries
- **Mode A:** Build `snd-usb-audio.ko` + 3 dependencies from `rz_linux-cip@rz-6.1-cip43` in WSL2 against the EVK's own `.config`, with `vermagic` forced to `6.1.141-cip43-yocto-standard`, then `insmod` on the EVK — enabling the USB mic as ALSA `card 1` with no reflash.
- **Mode B:** Build the UAC2 gadget (`g_audio`/`usb_f_uac2`/`u_audio`) from the same tree, patch the function name to "MoilMeet", load it single-direction on the USBHS UDC via CN2, and bridge the physical mic with `alsaloop` — making the EVK a USB microphone to the PC.
- **Mode B duplex:** Additionally patch `UAC2_DEF_CSYNC` to *adaptive* and rebuild `usb_f_uac2.ko` to drop the capture feedback endpoint, so a bidirectional gadget fits USBHS's 2 iso pipes; load `p_chmask=1 c_chmask=3` and run two `alsaloop` bridges — making the EVK a simultaneous USB microphone **and** speaker to the PC.
