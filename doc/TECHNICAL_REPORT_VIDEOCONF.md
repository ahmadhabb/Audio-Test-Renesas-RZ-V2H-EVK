# Technical Report — MoilMeet Fisheye Video-Conference: Camera Integration, Crop Fix, and Remote-Controlled Audio Recording on the RZ/V2H EVK

| | |
|---|---|
| **Date** | 23 July 2026 |
| **Target** | Renesas RZ/V2H EVK (SoC r9a09g057h44) |
| **Kernel** | Linux `6.1.141-cip43-yocto-standard` (aarch64), Poky/rz-vlp 5.0.11 (scarthgap) |
| **App** | `moilmeet-cpp` (LVGL/Wayland fisheye video-conference), deployed at `/home/root/moilmeet-cpp` |
| **Camera** | USB UVC "LRCP imx586" (`1c45:6200`), up to MJPG 8000×6000@5fps |
| **Outcome** | ✅ Live camera integrated with correct (uncropped) FOV; ✅ app's own recording feature captures real mic audio simultaneously with the existing USB-audio gadget; ✅ fully controllable over SSH with **zero** physical input devices; ⚠️ one **unresolved** freeze bug documented (§6) with a working workaround. |

> Builds on [TECHNICAL_REPORT.md](TECHNICAL_REPORT.md) (USB mic gadget) and
> [TECHNICAL_REPORT_SPEAKER.md](TECHNICAL_REPORT_SPEAKER.md) (full-duplex mic+speaker gadget).
> This report covers the **camera / video-conference app** side of the same EVK.

---

## 1. Executive Summary

Goal: bring the `moilmeet-cpp` fisheye video-conference app up on the EVK with a **live USB camera**
(not a demo file), verify it renders the correct field of view, and confirm the mic (already bridged
to the PC as a USB-audio gadget) is also usable by the app's **own** recording feature — all while
the board had **no free USB port for a mouse or keyboard** and no touchscreen.

Six independent problems were found and fixed or worked around:

1. **Camera silently opened at a cropped low-res mode** instead of the full fisheye FOV → fixed by
   requesting the calibration's native resolution before `open()` (§5).
2. **USB host-controller topology trap**: the camera (and later the mic, when moved) landed on a
   full-speed-only OHCI controller and lost most of its usable bandwidth/functionality → fixed by
   moving the physical cable to an EHCI/xHCI port (§3).
3. **A real, reproducible freeze** when starting the camera from the interactive start-menu (not from
   the CLI) — confirmed via thread-stack inspection, root-caused to the general vicinity of the
   GPU-dewarp/Wayland frame path, **not fixed**, but fully avoidable (§6).
4. **USB webcam gadget (UVC) investigated and shelved** — the endpoint budget that's already fully
   spent on the mic+speaker gadget almost certainly can't also fit video (§7).
5. **The app's audio-recording feature needed `ffmpeg`, absent from the board image**, and once
   present, **collided with the existing mic-bridge** for exclusive ALSA access — fixed with a static
   `ffmpeg` binary + an ALSA `dsnoop` split (§8).
6. **No mouse/keyboard/touchscreen available at all** (ports full) — solved with a trivial
   SSH-triggerable file-poll that toggles recording exactly like the UI button (§9).

---

## 2. Background / Prior State

Per [TECHNICAL_REPORT_SPEAKER.md](TECHNICAL_REPORT_SPEAKER.md), the EVK already runs as a full-duplex
USB audio gadget ("MoilMeet") on connector **CN2**, bridging a USB mic (**ME6S**) and a USB speaker
(GeneralPlus "USB Audio Device") to the PC over the same 2-iso-pipe UDC (`15820000.usb`). Separately,
`moilmeet-cpp` (an LVGL/Wayland C++ rewrite of a Python fisheye video-conference app) was already
cross-compiled and auto-starting on the board via `moilmeet-cpp.service`, previously demoed against a
static video file (`hindia.mp4`), not a live camera. This session's job was to connect the two: get
the app showing **live** camera video with correct geometry, while the existing audio setup kept
working.

---

## 3. Physical USB Topology — the Full-Speed (OHCI) Trap

### 3.1 Symptom
With the camera physically connected and `end0`/gadget networking freshly re-established after a
reboot, the app opened `/dev/video0` successfully but every frame read failed instantly:
```
CompositorPipeline: source exhausted / read failed
```
`video` FPS in the app's perf counter stayed at exactly **0.0** indefinitely, at **~0% CPU** (not a
busy retry loop — the pipeline gave up rather than spinning).

### 3.2 Root cause
```
dmesg:
usb 5-1.3: not running at top speed; connect to a high speed hub
usb 5-1.3: Found UVC 1.00 device LRCP imx586 (1c45:6200)
```
The board exposes **multiple USB host controllers** with different speed ceilings:

| Bus | Controller | Max speed |
|-----|-----------|-----------|
| `usb1`, `usb4` | EHCI | 480 Mbps (high-speed) |
| `usb2`, `usb6`, `usb7`, `usb8` | xHCI | 480 Mbps+ (high/super-speed) |
| `usb3`, `usb5` | **OHCI** | **12 Mbps (full-speed only, USB 1.1)** |

The camera had enumerated on `usb5` (OHCI). Its only high-resolution mode is **MJPG**, and even the
*smallest* usable modes exceed what full-speed isochronous bandwidth can sustain reliably at motion
video rates — the device opens (V4L2 negotiation succeeds) but every isochronous frame transfer fails.
`cat /sys/bus/usb/devices/5-1.3/speed` read **`12`**, confirming full-speed.

### 3.3 Fix
Physically moved the camera's USB cable to a different port. It re-enumerated on `usb1` (EHCI):
```
dmesg: usb 1-1: Found UVC 1.00 device LRCP imx586 (1c45:6200)   # no "not running at top speed" warning
/sys/bus/usb/devices/1-1/speed → 480
```
Immediately after, `video` FPS ramped normally and the SSH connection itself (a separate, unrelated
symptom caught along the way — see §Appendix) also stabilized.

### 3.4 The same trap recurred for the mic
Later, the user moved the **ME6S mic** to a different physical port to free up space. This time the
port itself wasn't the problem (audio bandwidth is tiny — full-speed is fine for 48 kHz mono/stereo
PCM) — but the act of unplugging killed the **existing** `alsaloop` mic-bridge process (its ALSA device
disappeared mid-run), and nothing auto-restarted it. Fixed by re-running
`./usb-gadget-duplex.sh up`, which re-detects ME6S by name (`MIC_MATCH="ME6S"`) regardless of which
bus/port it lands on and restarts the bridge.

**Lesson**: on this board, *never assume* a given USB-A port is high-speed-capable. Always check
`cat /sys/bus/usb/devices/<bus-port>/speed` (want `480` or `5000`, not `12`) after moving any
high-bandwidth device (camera), and re-run the gadget bridge setup after moving any audio device.

---

## 4. Deployment Pipeline Notes

`moilmeet-cpp` is cross-compiled for aarch64 in a WSL2 `Ubuntu-22.04` distro (gcc 11 toolchain +
board sysroot, no Yocto SDK needed — see prior session memory), then deployed to the board. Two
pipeline issues surfaced this session:

- **New CMake dependency**: `CMakeLists.txt` now reads `../version.txt` (repo root, one level above
  `cpp/`). The WSL build tree only mirrors `cpp/`'s contents flattened into `/root/moilmeet-cpp`, so
  the repo's `version.txt` had to be copied to `/root/version.txt` (one level "above" the tree) for
  `cmake` to configure.
- **`rsync` preserves source mtimes** → after editing a file on the Windows side and re-syncing,
  `ninja` can see the copied file as *older* than its already-built `.o` (from a prior build), print
  `ninja: no work to do`, and silently skip rebuilding it. Fix: `touch` the changed file(s) after
  `rsync`, before invoking `cmake --build`.
- **The systemd unit's base `ExecStart=` is NOT what's actually running.** `moilmeet-cpp.service`
  points at `/home/weston/moilmeet-cpp/...`, but a drop-in
  `/etc/systemd/system/moilmeet-cpp.service.d/perf.conf` overrides `ExecStart=` to
  `/home/root/moilmeet-cpp/board-run.sh ...` (with `MOILMEET_PERF`/`MOILMEET_MAPS_SCALE`/etc. env
  vars). **Always check for `.service.d/` drop-ins** (`cat /etc/systemd/system/<unit>.service.d/*.conf`)
  before assuming the base unit file describes what's live — `/home/weston/moilmeet-cpp/` still exists
  but is a stale, unused copy.
- The **active** binary must be stopped (`systemctl stop`) before it can be overwritten — a running
  UVC/MJPG-decoding process holds its own executable file open; `cp` over it fails with
  `Text file busy`.

---

## 5. Camera Calibration & the Crop Bug

### 5.1 Symptom
With the camera live, the picture (both the start-menu's live preview thumbnail and, initially, the
main session) looked **zoomed into the center** of the fisheye image rather than showing the full
~240° field of view.

### 5.2 Root cause
The camera's UVC descriptor exposes far more resolution modes than a shallow query shows (a truncated
`v4l2-ctl --list-formats-ext | head -10` hid all but the smallest ones — always request the **full**
list):

| Format | Resolutions available |
|--------|------------------------|
| MJPG | 8000×6000@5, 6000×4500@5, 6000×3360@5, 5000×3750@5, 5000×2800@5, 4000×3000@20, 3000×4000@5, 2250×3000@20, 3840×2160@30/5, 2592×1944@30, 2048×1536@30, **1920×1080@30**, 1280×720@30, **640×480@30** |
| YUYV | 1920×1080@5, 1280×720@8, 640×480@30 |

The app's camera-source classes (`OpenCvCameraSource`, and `TurboJpegSource` — which actually backs
capture via a GStreamer `v4l2src` pipeline internally, not plain OpenCV V4L2, despite what
`opencv_camera_source.cpp`'s comments imply) only request a specific resolution when explicitly told
to via `setRequestedResolution()`. Two code paths never did this:

- The **eager `--source N` path** (`main.cpp`, the non-menu CLI flow) — opened the camera with no
  requested size at all, landing on whatever the UVC driver's **default** mode is (observed: 640×480).
- The **start-menu live preview** (`previewStart` lambda) — same gap; only the interactive
  "Start Camera" session path (`startSession`) already called `chooseOptimalMode()`.

Critically, this camera's **low-resolution modes are a center-cropped ROI of the sensor, not a
binned-down full-FOV image** — a common behavior for multi-mode UVC sensors. Leaving the resolution
unspecified therefore doesn't just lose detail, it **loses field of view**.

### 5.3 Fix
Two matching one-directional fixes in `main.cpp`:

1. **Eager path**: before `cv_src->open()`, if `--camera-params <name>` was given, a lightweight
   *early* `CameraParametersStore` load looks up that parameter's native `image_width/height` and calls
   `cv_src->setRequestedResolution(cal_w, cal_h)` — requesting the calibration's exact native size
   (e.g. **8000×6000**) and deliberately **ignoring FPS** (per explicit user direction — "abaikan fps
   dulu"; the only mode at that size is 5 fps).
2. **`previewStart`**: mirrored `startSession`'s existing logic —
   `chooseOptimalMode(modes, cal_w, cal_h, target_fps)` then `setRequestedResolution`/`setRequestedFps`
   — so the live preview thumbnail shows the same uncropped FOV the real session would use.

`--target-fps N` (a pre-existing CLI flag) tunes `chooseOptimalMode`'s selection: **raising** it
*excludes* slow/large modes and picks something smaller-but-faster; it does not, by itself, force a
larger picture — for that, the eager path's direct "ignore FPS, request the exact calibration size"
approach was used instead.

### 5.4 Calibration parameter selection
`camera_parameters.json` ships **12** distinct calibrations specific to this camera model (per-unit
lens variance), all declaring the same native `8000×6000`:
`lrcp_imx586_0`…`_7`, `lrcp_imx586_240_16/17/18`, `lrcp_imx586_3_8000X6000` — each with different
intrinsic distortion coefficients (`iCx/iCy`, `parameter0-5`, `cameraFov` 230–240°). The user selected
**`lrcp_imx586_3`** by inspection/preference; there's no automatic per-unit detection.

---

## 6. The Start-Menu "Start Camera" Freeze — Confirmed, Root-Caused, Not Fixed

### 6.1 Symptom
Pressing **"Start Camera"** from the interactive start-menu (as opposed to launching with `--source`
from the CLI) reliably froze the app **permanently**, always immediately after the log line:
```
ShaderRenderer: GPU dewarp (shader) active (Mali-G31)
```
The `[perf]` log line (printed once per second by the main loop) simply **stopped appearing** —
not slower, gone.

### 6.2 Diagnosis
Per-thread inspection via `/proc/<pid>/task/*/stack` and repeated `/proc/<pid>/task/*/stat`
CPU-tick snapshots (3 s apart) showed:

| Thread | Role (inferred) | Stack | CPU delta over 3 s |
|--------|------------------|-------|---------------------|
| main (tid 2691) | LVGL/Wayland event loop | `do_sys_poll` (blocked, no timeout progress) | **0 / 0** — fully idle |
| `v4l2src1:src` | GStreamer capture (used internally by `TurboJpegSource`) | — | +15 / +7 |
| tid 2699 | decode worker | — | **+129 / +4** |
| tid 2700 | decode worker | — | **+242 / +41** |

I.e. capture and decode were **actively working the entire time** — frames were being read and
decoded continuously — but nothing ever reached the compositor/renderer, and the main thread never
woke from `poll()` again. This rules out a hung camera or a dead decode pipeline; it points at the
hand-off into rendering (GPU dewarp / EGL / Wayland surface commit / frame-callback), which lives
inside the vendored `third_party/lvgl` Wayland driver (no `wl_surface_commit`/frame-callback code
exists in the app's own `src/` tree).

### 6.3 What was ruled out
- **Not a UVC reopen-too-fast race**: a 400 ms settle delay was added in `startSession`, right before
  the camera is reopened (the `previewStop()` → new `CameraSource` sequence closes then immediately
  reopens the same physical device). Rebuilt and retested — **identical hang, identical stack**, at
  multiple resolutions (2592×1944 down to the 640×480 default). If it were a hardware/driver settle-time
  issue, the delay should have changed something; it didn't.
- **Not resolution-size-dependent**: the same hang occurred regardless of how large a frame was
  requested, so it isn't a CPU-overload symptom (a genuinely CPU-starved app would show the perf
  counter *degrade*, not stop dead with an idle main thread).

### 6.4 Workaround
The **eager `--source N` path never exhibits this hang** at any resolution tested (including the full
8000×6000) — it never goes through the preview-then-reopen transition that the menu flow does. **Use
`--source`/`--camera-params` from the CLI (systemd drop-in `ExecStart=`) instead of the interactive
"Start Camera" button** until the underlying render/frame-callback issue is properly diagnosed (would
need EGL error checking, Weston-side logs, or a debugger attached to the hung process — out of scope
for this session).

---

## 7. USB Webcam (UVC) Gadget — Investigated, Not Pursued

Requested: expose the camera as a USB webcam **to the PC** (e.g. for Google Meet), the same idea as
the existing audio gadget. Findings:

- `zcat /proc/config.gz` → `CONFIG_USB_G_WEBCAM` **not set**, `CONFIG_USB_CONFIGFS` **not set**. A
  UVC gadget function would need an out-of-tree module build (same technique as `usb_f_uac2.ko` in
  [TECHNICAL_REPORT_SPEAKER.md](TECHNICAL_REPORT_SPEAKER.md)), not currently built.
- **The bigger blocker**: CN2's UDC (`15820000.usb`) has only **~2 isochronous pipes total**, already
  **fully consumed** by the mic+speaker duplex gadget (that scarcity is exactly why the adaptive-sync
  patch in the speaker report was necessary just for audio alone). Video needs its own high-bandwidth
  ISO/bulk endpoint on top of that — very unlikely to fit. No second OTG-capable (dual-role) USB
  controller was found on this board; every other controller enumerated is host-only (EHCI/xHCI/OHCI).

**Decision**: not pursued this session. If revisited, the realistic options are (a) sacrifice
mic-or-speaker to make endpoint room for video, or (b) a kernel rebuild enabling `CONFIG_USB_CONFIGFS`
to explore whether a differently-composed gadget (e.g. bulk-only UVC) fits — both non-trivial.

---

## 8. Audio Recording Inside the App: `ffmpeg` + ALSA `dsnoop`

### 8.1 Discovery
`core/io/recorder.cpp` (a component of the app's "Recorded Videos" feature) already spawns `ffmpeg`
to mux a `rawvideo` pipe (the composited canvas) with a **live mic capture** (`-f alsa -i <dev>`) into
an AAC+MJPG `.mkv`. `Recorder::audio_` defaults to **true**. This directly answered the user's
question ("can mic+speaker be verified via the record feature?") — the capability already existed in
the app, contrary to an earlier (2 weeks prior) assessment that the app had no audio path at all.

### 8.2 Blocker 1 — no `ffmpeg` on the board
This Yocto image ships no `ffmpeg`, and has no usable package feed (`dnf repolist` → none configured;
the board has **no internet route** — `ping 8.8.8.8` → 100% loss, it only has the direct private link
to the PC). Fix: downloaded a **static aarch64 build** (`ffmpeg-7.0.2-arm64-static`,
`johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz`) on the PC (which has
internet), `scp`'d it to the board at `/usr/local/bin/ffmpeg` (had to `mkdir -p /usr/local/bin` first
— `/usr/local` didn't exist at all), then symlinked `/usr/bin/ffmpeg → /usr/local/bin/ffmpeg` for
belt-and-braces `PATH` coverage. Confirmed via `cat /proc/<pid>/environ` that the systemd service's
actual `PATH` (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin`, set automatically because the unit
specifies `User=root`) covers both locations.

### 8.3 Blocker 2 — ALSA device exclusivity
Once `ffmpeg` was in place, recording failed:
```
[alsa @ ...] cannot open audio device plughw:ME6S,0 (Device or resource busy)
```
The USB-audio-gadget's `alsaloop` mic-bridge (§ background, [TECHNICAL_REPORT_SPEAKER.md](TECHNICAL_REPORT_SPEAKER.md))
already holds ME6S's capture device **exclusively**. Fixed with an ALSA **`dsnoop`** share, added to
`/etc/asound.conf`:
```
pcm.me6s_dsnoop {
    type dsnoop
    ipc_key 1027
    ipc_perm 0666
    slave { pcm "hw:ME6S,0"; channels 1; rate 48000 }
}
pcm.me6s_shared {
    type plug
    slave.pcm "me6s_dsnoop"
}
```
- The **`alsaloop`** mic-bridge was repointed at `me6s_dsnoop` directly (`usb-gadget-duplex.sh up` with
  `MIC_CARD=me6s_dsnoop` — matches the dsnoop's fixed mono/48 kHz slave exactly, no conversion needed).
- **`ffmpeg`/the app** uses **`me6s_shared`** (the `plug`-wrapped version), set via
  `Environment=MOILMEET_AUDIO_DEV=me6s_shared` + `Environment=MOILMEET_AUDIO_FMT=alsa` in the systemd
  drop-in. The raw `dsnoop` alone wasn't enough for `ffmpeg`: its ALSA input defaults to requesting
  **stereo**, and the fixed-mono dsnoop slave rejected that (`cannot set channel count to 2`) — the
  `plug` layer auto-converts.

Both consumers (the PC-facing gadget bridge and the app's own recorder) now capture from ME6S
**simultaneously** with no device-busy errors.

### 8.4 Verification
| Test | Duration | Content | `mean_volume` | `max_volume` |
|------|----------|---------|----------------|---------------|
| 1 (silent room) | 13.34 s | ambient only | −50.0 dB | −34.6 dB |
| 2 (speaking into ME6S) | 71.67 s | real speech | **−34.0 dB** | **−9.8 dB** |

Measured with `ffmpeg -i video.mkv -af volumedetect -f null -`. The clear jump in both mean and max
level between the two tests (louder, more dynamic) confirms genuine speech capture, not silence or a
fixed noise floor. Both recordings' video track: MJPG, 1920×1080, 30 fps container-side (compositor
canvas resolution — independent of the camera's own capture resolution/FPS).

**Gotcha**: right after Stop, the output file can sit at **0 bytes** (or still named `seg_0.mkv`
rather than the finalized `video.mkv`) for up to ~10–15 seconds — `finalizeSegments()`'s
concat/rename step isn't instantaneous. Don't conclude failure from an early check. Also: sessions
shorter than ~10 s risk near-empty output simply from too few frames/audio samples being queued,
especially while the camera itself is only delivering ~1–5 fps (§5.3's ignore-FPS 8000×6000 mode).

---

## 9. No Mouse / Keyboard / Touchscreen — an SSH-Triggerable Control Channel

### 9.1 Constraint
All available USB ports were occupied (camera + mic + speaker), leaving none for a mouse or keyboard,
and the board has no touchscreen (`no evdev pointer or touch device found` in the app's own startup
log). The user needed a way to trigger the "Record" button with **zero physical input devices**.

### 9.2 Dead ends investigated
- **`/dev/uinput`** (a generic virtual-input-device mechanism) doesn't exist —
  `CONFIG_INPUT_UINPUT is not set` in the running kernel. Would require an out-of-tree kernel module
  build (not attempted this session).
- No `python3-evdev`, `ydotool`, `wtype`, or `xdotool` available on the board image.
- The app already has a custom fallback input reader, `board_input_evdev.cpp`, that watches ANY evdev
  node for `REL_WHEEL` + `BTN_RIGHT` (clearly designed for some external clicker/remote). It happened
  to attach to the ME6S mic's HID interface (`/dev/input/event1`) — but `/proc/bus/input/devices`
  shows ME6S's `EV` capability bitmask has **no `EV_REL` at all**, and a 20-second raw capture while
  physically pressing the mic's controls produced **zero events**. This specific input device cannot
  serve as a wheel/click substitute.

### 9.3 Fix: a polled trigger file
Added a minimal check to the app's main render loop (`main.cpp`, once per iteration): if
`/tmp/moilmeet_record_toggle` exists, call a new one-line public wrapper,
`RecordedVideosPresenter::toggleRecord()` (exposes the previously-private `onBtnRecord()`), and delete
the trigger file. From the PC:
```bash
ssh weston@192.168.10.2 'sudo touch /tmp/moilmeet_record_toggle'   # starts OR stops, like the UI button
```
This is a general pattern (a polled sentinel file mapped to a UI action) that can be extended to other
buttons if more remote control is needed without physical input hardware.

---

## 10. Verification Summary

| Check | Method | Result |
|-------|--------|--------|
| Camera on a high-speed port | `cat /sys/bus/usb/devices/<bus>/speed` | `480` (was `12` on OHCI) |
| Camera FOV not cropped | visual + `MM_LOG` "requesting calibration ... native resolution 8000x6000" | full FOV requested & opened |
| App survives a full-res (8000×6000) open | perf monitor stays alive, `video` fps stabilizes (~1 fps, expected at 5 fps sensor mode) | ✅ no freeze on the eager path |
| Menu-driven "Start Camera" | thread-stack + CPU-tick inspection | ❌ reproducible permanent freeze (§6), root-caused, not fixed |
| UVC webcam gadget feasibility | kernel config + endpoint budget check | not built, endpoint budget already spent — shelved |
| `ffmpeg` present & reachable | `command -v ffmpeg` inside the service's actual PATH | ✅ found at both `/usr/local/bin` and `/usr/bin` |
| Mic shared between gadget-bridge and app recorder | simultaneous `alsaloop` + `ffmpeg -f alsa -i me6s_shared` | ✅ no `Device or resource busy` |
| Recorded audio is real speech | `ffmpeg ... -af volumedetect` | ambient: −50/−34.6 dB → speaking: **−34.0/−9.8 dB** |
| Record control with zero input devices | `ssh ... touch /tmp/moilmeet_record_toggle` | ✅ starts/stops recording reliably |

---

## 11. Reproduction

```bash
# 0. Physical: camera + ME6S mic + USB speaker connected to EVK; verify each port is high-speed
#    for the camera specifically: cat /sys/bus/usb/devices/<bus-port>/speed   (want 480, not 12)

# 1. Board-side ALSA sharing (one-time, survives until the board is reflashed):
sudo tee /etc/asound.conf <<'EOF'
pcm.me6s_dsnoop { type dsnoop; ipc_key 1027; ipc_perm 0666; slave { pcm "hw:ME6S,0"; channels 1; rate 48000 } }
pcm.me6s_shared { type plug; slave.pcm "me6s_dsnoop" }
EOF

# 2. Board-side ffmpeg (one-time, /usr/local/bin doesn't persist a Yocto rebuild — redo after reflash):
#    scp a static aarch64 ffmpeg build to /usr/local/bin/ffmpeg, symlink into /usr/bin.

# 3. Audio gadget bridge, mic routed through the shared dsnoop:
cd "/c/habb/projects/Audio Test RZ v2h"
MIC_CARD=me6s_dsnoop ./usb-gadget-duplex.sh up

# 4. moilmeet-cpp systemd drop-in (/etc/systemd/system/moilmeet-cpp.service.d/perf.conf):
#      Environment=MOILMEET_AUDIO_FMT=alsa
#      Environment=MOILMEET_AUDIO_DEV=me6s_shared
#      ExecStart=/home/root/moilmeet-cpp/board-run.sh --source 0 --camera-params lrcp_imx586_3 --target-fps 30
sudo systemctl daemon-reload && sudo systemctl restart moilmeet-cpp

# 5. Remote record control (no mouse/keyboard needed):
ssh weston@192.168.10.2 'sudo touch /tmp/moilmeet_record_toggle'   # start
#   ... speak into ME6S ...
ssh weston@192.168.10.2 'sudo touch /tmp/moilmeet_record_toggle'   # stop
sleep 15   # let finalizeSegments() concat/rename complete
```

---

## 12. Limitations / Follow-ups

- **§6's freeze bug is unresolved.** The interactive start-menu "Start Camera" flow must not be used
  in production until the GPU-dewarp/Wayland frame-callback hand-off is properly debugged (EGL error
  checking, Weston logs, or gdb on the hung process). The eager `--source` path is the only
  confirmed-safe way to start a live camera session today.
- **8000×6000 native resolution is only 5 fps** at the sensor — accepted per explicit user
  direction ("abaikan fps"), but a genuinely smooth, uncropped feed would need either a smaller
  same-aspect-ratio mode (this camera happens to have several: 4000×3000@20, 2592×1944@30, etc. — all
  4:3, all a strict subset FOV of the full sensor unless the sensor bins rather than crops at those
  sizes too, which was **not verified**) or GPU-side cropping/scaling tuning.
- **UVC webcam gadget remains unbuilt.** If revisited, expect to trade off audio bandwidth or attempt
  a `CONFIG_USB_CONFIGFS` kernel rebuild — both are non-trivial next steps, not started.
- **`/usr/local/bin/ffmpeg` and `/etc/asound.conf` are filesystem changes outside the Yocto image** —
  they will NOT survive a full board reflash and must be redone (steps 1–2 in §11) after one.
- **The trigger-file record control is a single-purpose hack**, not a general remote-control API — it
  only toggles Record/Stop. Extending it to other UI actions (e.g. switching camera params, adjusting
  view mode) would need one sentinel file (or a small command-file protocol) per action.
- The board's system clock is drifted (shows dates in 2025, not the real date) — cosmetic, but log
  timestamps referenced in this report and in `journalctl` output don't match real-world wall-clock
  dates.

---

## 13. Artifacts

| Path | Contents |
|------|----------|
| `video-conference-using-fisheye/cpp/src/app/main.cpp` | eager-path native-resolution request (§5.3), record-toggle file poll (§9.3), 400 ms settle delay (§6.3, kept but confirmed ineffective) |
| `video-conference-using-fisheye/cpp/src/presenter/recorded_videos_presenter.hpp/.cpp` | `toggleRecord()` public wrapper (§9.3) |
| `/etc/asound.conf` (board) | `me6s_dsnoop` / `me6s_shared` ALSA sharing definitions (§8.3) |
| `/usr/local/bin/ffmpeg` + `/usr/bin/ffmpeg` (symlink, board) | static aarch64 ffmpeg 7.0.2 (§8.2) |
| `/etc/systemd/system/moilmeet-cpp.service.d/perf.conf` (board) | active `ExecStart=`, `MOILMEET_*` env vars incl. `MOILMEET_AUDIO_DEV=me6s_shared` |
| `usb-gadget-duplex.sh` | `MIC_CARD` override used to point the mic bridge at `me6s_dsnoop` |
| `recordings/*.mkv`, `recordings/*_thumbnail.png` | copies of the two verification recordings (§8.4) |

### One-line summary
Fixed a center-crop bug by requesting the fisheye camera's native calibration resolution before
opening it (ignoring FPS), diagnosed-but-did-not-fix a start-menu-only freeze (workaround: use the
CLI `--source` path), shelved a USB-webcam-gadget idea on endpoint-budget grounds, and — with a static
`ffmpeg` build plus an ALSA `dsnoop` split to resolve a mic-device conflict with the existing
USB-audio gadget — got the app's own recording feature capturing verified real speech, fully
controllable over SSH with no mouse, keyboard, or touchscreen at all.
