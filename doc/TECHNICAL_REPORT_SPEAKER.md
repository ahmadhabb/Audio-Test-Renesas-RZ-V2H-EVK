# Technical Report — Adding a USB **Speaker** to the RZ/V2H EVK Audio Gadget (Full‑Duplex "MoilMeet")

| | |
|---|---|
| **Date** | 8 July 2026 |
| **Target** | Renesas RZ/V2H EVK (SoC r9a09g057h44) |
| **Kernel** | Linux `6.1.141-cip43-yocto-standard` (aarch64) |
| **UDC** | `15820000.usb` (renesas_usbhs, `dr_mode=otg`), connector **CN2** |
| **Method** | One-line source patch + rebuild of `usb_f_uac2.ko` — **no kernel reflash** |
| **Outcome** | ✅ The EVK is simultaneously a USB **microphone _and_ speaker** to the PC (`Microphone (MoilMeet)` + `Speakers (MoilMeet)`), within the USBHS 2‑iso‑pipe limit. |

> This document extends the base work in [TECHNICAL_REPORT.md](TECHNICAL_REPORT.md) (Mode A host
> capture and Mode B mic-only gadget). It focuses solely on the **speaker / full‑duplex** addition.
> Operational runbook: [HOW_TO_RUN.md](HOW_TO_RUN.md) §5b.

---

## 1. Executive Summary

The mic-only UAC2 gadget (Mode B) makes the EVK a USB microphone. The goal here was to **also**
present the EVK as a USB **speaker**, so a host PC can play audio *through* the EVK to a physical
USB speaker attached to it — a single full-duplex device.

A naïve attempt (`g_audio p_chmask=1 c_chmask=1`) **fails to bind** on the RZ/V2H because the USBHS
device controller offers only ~2 isochronous pipes, while a standard UAC2 gadget with both directions
needs **three** endpoints. The extra endpoint is the capture **feedback** endpoint, mandated by the
*asynchronous* synchronization model of the capture (speaker) stream.

The fix is a **one-line source change**: set the UAC2 capture synchronization default to **adaptive**
instead of **asynchronous**. Adaptive capture carries no feedback endpoint, so the gadget needs only
**two** endpoints (mic-IN + speaker-OUT) and binds successfully. Only `usb_f_uac2.ko` is rebuilt.
Host audio arriving at the gadget's capture PCM is bridged to the physical USB speaker with `alsaloop`.

---

## 2. Direction Semantics (recap)

For `g_audio` module parameters, direction is named **from the gadget's point of view**:

| Params | Gadget direction | Host sees | On the EVK |
|--------|------------------|-----------|------------|
| `p_*` (**playback**) | gadget → host | **Microphone** (host records) | a **playback** PCM (userspace *writes* the mic audio into it) |
| `c_*` (**capture**) | host → gadget | **Speaker** (host plays) | a **capture** PCM (userspace *reads* the host audio out of it) |

So the **speaker** is the `c_*` (capture) direction: the host plays into it, and on the EVK a
**capture** PCM appears that we drain and forward to the physical USB speaker.

---

## 3. The Endpoint Constraint

### 3.1 Symptom
Loading the gadget bidirectionally initially failed:
```
g_audio: unknown parameter 'c_sync' ignored
g_audio gadget.0: afunc_bind:1261 Error!
udc 15820000.usb: failed to start g_audio: -19
UDC core: g_audio: couldn't find an available UDC
```
`-19` is `ENODEV`: the bind ran out of usable isochronous endpoints.

### 3.2 Endpoint budget
| Configuration | ISO endpoints needed | Fits USBHS (~2)? |
|---------------|----------------------|------------------|
| Mic only (`p_chmask=1 c_chmask=0`) | 1 IN | ✅ |
| Speaker only (`p_chmask=0 c_chmask=1`) | 1 OUT (+1 IN feedback, async) = 2 | ✅ (just) |
| **Mic + speaker, async capture** | 1 IN + 1 OUT + 1 IN feedback = **3** | ❌ (`-19`) |
| **Mic + speaker, adaptive capture** | 1 IN + 1 OUT = **2** | ✅ (the fix) |

The third endpoint is the **isochronous feedback IN** endpoint that an *asynchronous* UAC2 capture
uses to tell the host how fast to send samples. Removing it is the key to fitting both directions.

---

## 4. Root Cause & Fix

### 4.1 Where the feedback endpoint is gated
In the kernel UAC2 function driver the feedback endpoint is controlled entirely by the capture
synchronization type:
```c
/* drivers/usb/gadget/function/f_uac2.c */
#define EPOUT_FBACK_IN_EN(_opts) ((_opts)->c_sync == USB_ENDPOINT_SYNC_ASYNC)
```
When `c_sync != ASYNC` (i.e. **adaptive**):
- the feedback **descriptor** is omitted from the config (`if (EPOUT_FBACK_IN_EN(opts)) …`),
- the feedback endpoint is **not** autoconfigured (`agdev->in_ep_fback` stays `NULL`),
- the OUT (speaker) endpoint's `bmAttributes` is set to `USB_ENDPOINT_SYNC_ADAPTIVE`.

The companion driver `u_audio.c` already guards **every** feedback-endpoint access with
`if (audio_dev->in_ep_fback)`, so a NULL feedback endpoint is a fully supported configuration — no
further code change is required there.

### 4.2 Why a parameter alone won't do it
`c_sync` is exposed as a **configfs** attribute, but this VLP image is built with
`CONFIG_USB_CONFIGFS` **disabled**, so the **legacy** `g_audio` module is used. The legacy module
exposes no `c_sync` parameter — hence `unknown parameter 'c_sync' ignored`. The only lever on the
legacy path is the compile-time **default**.

### 4.3 The patch (one line)
```diff
  /* drivers/usb/gadget/function/u_uac2.h */
- #define UAC2_DEF_CSYNC   USB_ENDPOINT_SYNC_ASYNC
+ #define UAC2_DEF_CSYNC   USB_ENDPOINT_SYNC_ADAPTIVE
```
`UAC2_DEF_CSYNC` is consumed by `afunc_alloc_inst()` in `f_uac2.c` (`opts->c_sync = UAC2_DEF_CSYNC;`),
so only **`usb_f_uac2.ko`** needs rebuilding; `u_audio.ko` is unchanged. The existing `function_name`
patch that names the device (§7) is retained in the same module.

### 4.4 Rebuild
```bash
# in the WSL2 kernel tree /root/build/linux
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     drivers/usb/gadget/function/usb_f_uac2.ko
aarch64-linux-gnu-strip --strip-debug drivers/usb/gadget/function/usb_f_uac2.ko
# vermagic must stay 6.1.141-cip43-yocto-standard SMP preempt mod_unload aarch64
```
The `modpost` "undefined symbol" warnings from a single-module build are benign (resolved at load
time against the running kernel; `MODVERSIONS` is off).

---

## 5. Loading the Full-Duplex Gadget

```bash
# load order: libcomposite -> u_audio -> (patched) usb_f_uac2 -> g_audio
g_audio p_chmask=1 p_srate=48000 p_ssize=2 \        # mic: mono, gadget->host
        c_chmask=3 c_srate=48000 c_ssize=2 \        # speaker: stereo, host->gadget
        idVendor=0x1d6b idProduct=0x4d05 \          # fresh PID => fresh Windows endpoint name
        iManufacturer=Moil iProduct=MoilMeet iSerialNumber=MoilMeet-01
```
Result — the gadget card exposes **both** PCMs on device 0:
```
UDC state = configured
card N: UAC2Gadget [UAC2_Gadget], device 0: UAC2 PCM   # playback (mic) AND capture (speaker)
```
`aplay -l` lists card N device 0 (mic playback side); `arecord -l` lists the same card/device
(speaker capture side). No `-19`.

---

## 6. The Speaker Bridge

The host's audio lands on the gadget **capture** PCM; a physical **USB speaker** (its own ALSA
playback card) is the sink. The two run on **independent clocks**, so a raw `arecord | aplay` pipe
would under/overrun to silence. `alsaloop` performs the rate/clock-drift adaptation:

```bash
# speaker path: gadget capture  ->  USB speaker (stereo)
alsaloop -C plughw:<gadget>,0 -P plughw:<usbspk>,0 -r 48000 -c 2 -f S16_LE -t 150000 -S 3
# mic path (unchanged): ME6S    ->  gadget playback (mono)
alsaloop -C plughw:<mic>,0    -P plughw:<gadget>,0 -r 48000 -c 1 -f S16_LE -t 150000 -S 2
```

Both `alsaloop` instances open the **same** gadget card in **opposite** directions (full-duplex on
one PCM device). The USB speaker used in testing is a GeneralPlus device (`1B3F:2008`, ALSA name
"USB Audio Device"), native **48000 Hz / S16_LE / stereo** — matching the gadget, so no resampling
is needed (only `plughw`'s format/channel safety layer).

Signal chains:
```
  MIC:      ME6S  --alsaloop-->  gadget playback  --USB(CN2)-->  PC "Microphone (MoilMeet)"
  SPEAKER:  PC "Speakers (MoilMeet)"  --USB(CN2)-->  gadget capture  --alsaloop-->  USB speaker
```

---

## 7. Naming — "MoilMeet" and the Windows "N-" Prefix

### 7.1 The name string
The host's *"Microphone (⟨name⟩)"* / *"Speakers (⟨name⟩)"* text is the UAC2 **`function_name`**,
hardcoded in `f_uac2.c` (~line 2185), **not** the `iProduct` parameter. It was patched to
**`"MoilMeet"`** and the module rebuilt. Because Windows caches the endpoint friendly name **per USB
VID:PID**, the gadget is loaded with a **fresh `idProduct`** after any name change, or the stale
cached name persists.

### 7.2 The numeric prefix is not the name
Windows prepends a disambiguation counter — e.g. *"Speakers (3- MoilMeet)"* — when several **ghost**
(disconnected) device instances remain, one per USB PID used during development (`0x4d01…0x4d04`).
To obtain a clean **"MoilMeet"** with no prefix, all stale/ghost instances are removed so the fresh
gadget enumerates as instance #1:
```powershell
# cleanup-moilmeet-devices.ps1  (run as Administrator)
Get-PnpDevice | ? { $_.FriendlyName -match 'moilmeet' -or $_.InstanceId -match 'VID_1D6B&PID_4D0' } |
  % { pnputil /remove-device $_.InstanceId }
```
This removes every MoilMeet USB-composite, MEDIA, and AudioEndpoint node (present + ghost).
Deleting the orphaned MMDevices registry keys additionally needs ownership taken from SYSTEM and was
found **unnecessary** — removing the device nodes alone cleared the prefix. After cleanup, reconnect
the gadget with a fresh PID.

---

## 8. Audio-Quality Tuning

The first working duplex build **crackled** badly. Cause: two `alsaloop` bridges, each crossing an
independent USB clock domain, with `alsaloop`'s small **default** ring buffer → thousands of
over/underruns per second.

Two `alsaloop` knobs resolved it:

| Knob | Value | Purpose |
|------|-------|---------|
| `-t` (target latency / ring buffer) | **150000 µs (150 ms)** | absorbs cross-clock drift |
| `-S` (sync type) | **2 = captshift** (mic), **3 = playshift** (speaker) | corrects rate mismatch by shifting samples, no clicks |

**Measured effect** (6 s window, xrun log lines):

| Bridge | Default settings | Tuned (`-t 150000 -S 2/3`) |
|--------|------------------|----------------------------|
| Mic (ME6S → gadget) | 4820 | **3** (startup transient) |
| Speaker (gadget → USB spk) | 7850 | **0** |

Speaker-bridge CPU also dropped from ~7.5 % to ~0.3 %. Raising `-t` further (e.g. `TLAT=300000`,
300 ms) trades latency for even more drift tolerance. A higher-quality resampling sync (`-S 4`,
`samplerate`) would need the external `samplerate` ALSA converter plugin, which is not installed on
the EVK; the sample-shift modes are sufficient here.

---

## 9. Verification

| Check | Method | Result |
|-------|--------|--------|
| Gadget binds bidirectional | `insmod … p_chmask=1 c_chmask=3`; `dmesg` | `g_audio ready`, `UDC state = configured`, **no** `-19` |
| Both PCMs present | `aplay -l` + `arecord -l` on gadget card | playback (mic) **and** capture (speaker) on device 0 |
| PC sees both endpoints | `Get-PnpDevice -Class AudioEndpoint` | `Microphone (MoilMeet)` **OK** + `Speakers (MoilMeet)` **OK** |
| Mic audio flows | record `Microphone (MoilMeet)` @ 48 kHz mono | real speech, **max −9.9 dBFS** |
| Speaker audio flows | play 440 Hz tone to `Speakers (MoilMeet)` | gadget **capture** + USB-speaker **playback** substreams both `state: RUNNING`; tone audible on the physical USB speaker |
| No crackle | xrun log after tuning | mic ≈3 (startup), speaker 0 in 6 s |
| Clean name | after `cleanup-moilmeet-devices.ps1` + reconnect | `Microphone (MoilMeet)` / `Speakers (MoilMeet)`, **no** "N-" prefix |

---

## 10. Reproduction

```bash
# 0. one-time: patch + rebuild the module (WSL2 kernel tree)
sed -i 's/UAC2_DEF_CSYNC\t\tUSB_ENDPOINT_SYNC_ASYNC/UAC2_DEF_CSYNC\t\tUSB_ENDPOINT_SYNC_ADAPTIVE/' \
    drivers/usb/gadget/function/u_uac2.h
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/usb/gadget/function/usb_f_uac2.ko
aarch64-linux-gnu-strip --strip-debug drivers/usb/gadget/function/usb_f_uac2.ko
cp drivers/usb/gadget/function/usb_f_uac2.ko "<project>/usb-gadget-modules/"

# 1. on the PC (Git Bash): plug ME6S + USB speaker into the EVK, CN2 data cable to the PC
cd "/c/habb/projects/Audio Test RZ v2h"
./usb-gadget-duplex.sh up        # loads duplex gadget + both tuned alsaloop bridges
./usb-gadget-duplex.sh status    # UDC configured, 2 bridges, cards listed
# (optional, once) remove ghost devices for a clean name:
#   powershell -ExecutionPolicy Bypass -File cleanup-moilmeet-devices.ps1   (as Admin)
#   then: ./usb-gadget-duplex.sh down && ./usb-gadget-duplex.sh up
./usb-gadget-duplex.sh down      # tear down, free CN2
```
Tunables: `TLAT` (buffer µs), `SYNC_MIC`/`SYNC_SPK` (alsaloop sync mode), `MIC_CARD`/`SPK_CARD`
(force ALSA devices), `USB_PID` / `MIC_NAME`.

---

## 11. Limitations

- **Adaptive (open-loop) capture.** Dropping the feedback endpoint means the speaker path has no USB
  rate feedback; `alsaloop` compensates the residual drift. This is less rigorous than standard async
  capture and could matter for strict A/V lip-sync, but showed no audible dropouts in testing.
- **USBHS 2-pipe ceiling.** Two iso pipes is the hard limit; there is no room for a third stream
  (e.g. a second capture) alongside mic+speaker.
- **Not persistent.** Modules live in `/tmp`; the gadget, bridges, `end1` IP and SSH server must be
  re-established after any EVK reboot (see [HOW_TO_RUN.md](HOW_TO_RUN.md)).
- **Windows name cache.** Any future rename requires a fresh USB PID and (for a clean, unprefixed
  name) removing the ghost instances via `cleanup-moilmeet-devices.ps1`.
- **Card auto-detect by name.** The bridge resolves ME6S / "USB Audio Device" / UAC2Gadget cards by
  substring each run; a different USB speaker model needs `SPK_MATCH`/`SPK_CARD` overrides.

---

## 12. Artifacts

| Path | Contents |
|------|----------|
| `usb-gadget-modules/usb_f_uac2.ko` | patched module: `function_name="MoilMeet"` **+** `UAC2_DEF_CSYNC=ADAPTIVE` |
| `usb-gadget-modules/usb_f_uac2.ko.async-bak` | previous async (mic-only) build, for reference |
| `usb-gadget-duplex.sh` | full-duplex orchestration (`up`/`status`/`down`) with tuned `alsaloop` |
| `cleanup-moilmeet-devices.ps1` | (Admin) removes ghost MoilMeet devices → clean endpoint name |
| `drivers/usb/gadget/function/u_uac2.h` | the one-line patch site (`UAC2_DEF_CSYNC`) in the WSL tree |

### One-line summary
Switch the legacy UAC2 gadget's **capture sync default to adaptive** (a single `u_uac2.h` line,
rebuild `usb_f_uac2.ko`) to drop the isochronous feedback endpoint; the bidirectional gadget then
fits USBHS's two iso pipes, and a second `alsaloop` bridge (gadget capture → USB speaker, tuned
`-t 150000 -S 3`) makes the EVK a simultaneous USB **microphone and speaker** ("MoilMeet") to the PC.
