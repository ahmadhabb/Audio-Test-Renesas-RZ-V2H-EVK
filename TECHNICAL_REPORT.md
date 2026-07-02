# Technical Report — Enabling USB Audio on the Renesas RZ/V2H EVK

| | |
|---|---|
| **Date** | 2 July 2026 |
| **Target** | Renesas RZ/V2H EVK (SoC r9a09g057h44) |
| **Kernel** | Linux `6.1.141-cip43-yocto-standard` (aarch64) |
| **Distro** | rz-vlp, Poky *scarthgap* 5.0.11 (kernel originally built with gcc 13.4.0) |
| **Method** | Out-of-tree loadable kernel modules, cross-built in WSL2 — **no kernel reflash** |
| **Outcome** | ✅ **Mode A**: USB mic works as ALSA `card 1`, streamed to PC. ✅ **Mode B**: EVK presents itself to the PC as a USB microphone named **"moilmeet"**. |

---

## 1. Executive Summary

The stock RZ/V2H VLP kernel ships without USB Audio Class support in either direction: neither the host-side capture driver (`snd-usb-audio`) nor any USB audio *gadget* is compiled in, and the kernel is monolithic (no modules on the rootfs). Two capabilities were delivered without reflashing the kernel, by rebuilding the exact kernel source as **loadable modules** whose `vermagic` matches the running kernel and `insmod`-ing them over SSH:

- **Mode A — USB mic → PC.** A USB microphone plugged into an EVK host port is exposed as an ALSA capture card and streamed to the PC.
- **Mode B — EVK → USB mic on PC.** The EVK's USB device controller runs a UAC2 gadget, so the PC sees the EVK itself as a microphone ("moilmeet"); the physical mic is bridged into that gadget.

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

## 6. Mode B — EVK as a USB Microphone ("moilmeet")

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
Line 1261 of `f_uac2.c` is the *IN* endpoint autoconfig (the microphone direction). The gadget is therefore configured **single-direction (mic only)**, which binds successfully.

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

### 6.7 Naming the microphone ("moilmeet")
The name the host displays as *"Microphone (⟨name⟩)"* is the UAC2 **`function_name`** string, **hardcoded** in the driver — not the `iProduct` module parameter. In `drivers/usb/gadget/function/f_uac2.c` (~line 2185):
```c
scnprintf(opts->function_name, sizeof(opts->function_name), "Source/Sink");
```
This was patched to `"moilmeet"` and `usb_f_uac2.ko` rebuilt. Two facts were established:
1. Setting `iProduct=moilmeet` alone did **not** rename the mic — that string only names the parent device; the audio interface (MI_00) uses `function_name`.
2. **Windows caches the audio-endpoint friendly name per USB VID:PID** (MMDevices registry). After changing the string, the gadget must be loaded with a **fresh `idProduct`** or the stale cached name persists.

Final load parameters:
```bash
g_audio p_chmask=1 p_srate=48000 p_ssize=2 c_chmask=0 \
        idVendor=0x1d6b idProduct=0x4d01 \
        iManufacturer=Moil iProduct=moilmeet iSerialNumber=moilmeet-001
```

### 6.8 Verification
- `/sys/class/udc/15820000.usb/state = configured (high-speed)`.
- PC capture endpoint: **`Microphone (moilmeet)`** (confirmed via `Get-PnpDevice` and `ffmpeg -f dshow -list_devices`).
- End-to-end audio: recording `Microphone (moilmeet)` at native 48 kHz mono on the PC captured real speech (e.g. `max −24…−34 dBFS`), not silence. A fixed test tone fed to the gadget was also received cleanly, isolating the earlier silence to the clock-drift pipe (§6.6).
- Windows records dshow at its default 44.1 kHz/stereo unless told otherwise; capturing at the device's native **48000 Hz mono** avoided misleading results during bring-up.

### 6.9 Tooling
`usb-gadget-mic.sh` — `up | status | down | pc-test`. It deploys the gadget modules, loads `g_audio` in mic mode with the naming parameters, starts the `alsaloop` bridge, and (on `down`) tears everything down and frees CN2. `MIC_NAME`/`USB_PID`/… are overridable variables.

---

## 7. Results

| Capability | Status | Evidence |
|-----------|--------|----------|
| USB mic → EVK → PC (Mode A) | ✅ | `card 1: ME6S`; captured `−11.7 dBFS` peak; live `ffplay` stream |
| EVK → USB mic on PC (Mode B) | ✅ | UDC `configured`; PC shows `Microphone (moilmeet)`; real audio recorded |
| No kernel reflash | ✅ | all functionality via `insmod` of `vermagic`-matched modules |

---

## 8. Limitations

- **Not persistent across EVK reboots.** `/lib/modules` is empty, so modules must be re-inserted, and the `end1` IP re-applied, after each boot. For permanence: install the `.ko` into `/lib/modules/$(uname -r)/` + `depmod`, or fold them into the Yocto image.
- **Onboard audio (DA7213) remains dead** — the SSI clock `-110` BSP defect is out of scope.
- **Mode B is one-way** (microphone only) due to the USBHS isochronous-endpoint limit (§6.4).
- **Mic display name is baked into `usb_f_uac2.ko`** (§6.7); changing it requires editing `f_uac2.c`, rebuilding, and bumping `USB_PID` to defeat the Windows name cache.
- **gcc mismatch** (build gcc 15 vs kernel gcc 13.4) is safe only because `MODVERSIONS` is disabled; if a future image enables it, the modules must be rebuilt against that tree.

---

## 9. Reproduction & Artifacts

All under `C:\habb\projects\Audio Test RZ v2h\` (see [README.md](README.md) for the step-by-step run guide):

| Path | Contents |
|------|----------|
| `usb-audio-modules/` | Mode A modules (4× `.ko`) + `evk_kernel_config` |
| `usb-gadget-modules/` | Mode B modules (`libcomposite`, `u_audio`, `usb_f_uac2` [patched], `g_audio`) |
| `usb-mic-test.sh` / `.bat` | Mode A CLI + launcher |
| `MicEVK.ps1` / `.bat` | Mode A GUI application |
| `usb-gadget-mic.sh` | Mode B orchestration (`up`/`status`/`down`/`pc-test`) |
| `README.md` | End-user setup guide |
| `TECHNICAL_REPORT.md` | This report |

The WSL2 build tree at `/root/build/linux` can rebuild any module on demand.

### One-line summaries
- **Mode A:** Build `snd-usb-audio.ko` + 3 dependencies from `rz_linux-cip@rz-6.1-cip43` in WSL2 against the EVK's own `.config`, with `vermagic` forced to `6.1.141-cip43-yocto-standard`, then `insmod` on the EVK — enabling the USB mic as ALSA `card 1` with no reflash.
- **Mode B:** Build the UAC2 gadget (`g_audio`/`usb_f_uac2`/`u_audio`) from the same tree, patch the function name to "moilmeet", load it single-direction on the USBHS UDC via CN2, and bridge the physical mic with `alsaloop` — making the EVK a USB microphone to the PC.
