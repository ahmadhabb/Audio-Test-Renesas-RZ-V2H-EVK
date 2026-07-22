# MoilMeet Fisheye Video-Conference on the RZ/V2H EVK
Camera Integration, Crop Fix & Remote-Controlled Audio Recording

23 July 2026 — Renesas RZ/V2H EVK

## Executive Summary

- Live USB fisheye camera (LRCP imx586) integrated into the `moilmeet-cpp` video-conference app
- 6 problems found & fixed/worked around:
    1. Camera opened at a **cropped**, low-res mode → fixed
    2. USB port topology trap (full-speed OHCI) → fixed
    3. Freeze on interactive "Start Camera" → root-caused, **workaround** only
    4. USB webcam (UVC) gadget → investigated, **shelved**
    5. App's own audio recording needed `ffmpeg` + conflicted with mic gadget → fixed
    6. Zero mouse/keyboard/touchscreen available → SSH remote-control channel added

## USB Topology Trap: the OHCI Surprise

**Symptom**: camera opens fine, every frame read fails instantly (0 fps, ~0% CPU)

**Root cause**: `dmesg` → *"not running at top speed"* — camera landed on `usb5`, an
**OHCI** controller (USB 1.1, 12 Mbps full-speed only)

| Bus | Controller | Max speed |
|---|---|---|
| usb1, usb4 | EHCI | 480 Mbps |
| usb2, usb6, usb7, usb8 | xHCI | 480 Mbps+ |
| usb3, usb5 | **OHCI** | **12 Mbps only** |

**Fix**: move the cable → re-enumerated on `usb1` (EHCI) → confirmed `speed = 480` → camera works

*Lesson: never assume a USB-A port is high-speed on this board — check `/sys/bus/usb/devices/.../speed`*

## Camera Crop Bug

**Symptom**: fisheye image looked zoomed into the center, not full ~240° FOV

**Root cause**: camera's low-res modes are a **center-cropped ROI**, not a binned-down
full-FOV image. Two code paths never requested a resolution → landed on the
camera's default (640×480, cropped)

**Fix**: request the calibration's **native resolution** (e.g. 8000×6000) before
`open()`, in both the eager `--source` path and the start-menu live preview —
FPS intentionally ignored (only 5 fps at that size)

**Camera's real capability** (full list, not truncated!):
MJPG up to 8000×6000@5fps · 4000×3000@20fps · 2592×1944@30fps · 1920×1080@30fps · 640×480@30fps

## The Start-Menu Freeze — Confirmed, Not Fixed

**Symptom**: pressing "Start Camera" from the interactive menu → permanent freeze,
right after "GPU dewarp (shader) active"

**Diagnosis** (via `/proc/pid/task/*/stack` + CPU-tick snapshots):

| Thread | Role | CPU activity |
|---|---|---|
| Main UI thread | Wayland event loop | **0 — frozen in `poll()`** |
| GStreamer capture | video capture | active, still working |
| 2× decode workers | JPEG decode | active, still working |

→ Capture + decode keep running; frames never reach the renderer

**Ruled out**: not a UVC-reopen timing race (400ms delay made no difference), not
resolution-dependent (same hang at every size tested)

**Workaround**: the CLI `--source` path never goes through this transition — freeze-free
at every resolution, including full 8000×6000

## USB Webcam (UVC) Gadget — Investigated, Shelved

Goal: expose the camera as a USB webcam to the PC (e.g. for Google Meet)

**Blockers found:**

- `CONFIG_USB_G_WEBCAM` and `CONFIG_USB_CONFIGFS` both **not set** in the kernel
- CN2's USB controller has only **~2 isochronous pipes total** —
  already **fully spent** by the existing mic+speaker audio gadget
- No second USB gadget-capable (OTG) controller found on the board

**Decision**: not pursued — would mean sacrificing audio, or a kernel rebuild
with uncertain payoff

## Audio Recording: ffmpeg + ALSA dsnoop

The app's own "Recorded Videos" feature **already** supports mic audio via `ffmpeg`
— just needed two fixes:

**Blocker 1 — no `ffmpeg` on the board** (no internet, no package repo)
→ downloaded a **static aarch64 ffmpeg build** on the PC, copied to the board

**Blocker 2 — ALSA device conflict**
→ `ffmpeg: cannot open audio device plughw:ME6S,0 (Device or resource busy)`
→ the mic-bridge (`alsaloop`, feeds the PC's USB-audio gadget) already holds it exclusively

**Fix**: ALSA **`dsnoop`** sharing layer in `/etc/asound.conf` — lets both the
PC-facing bridge AND the app's own recorder capture the mic **simultaneously**

## Verified: Real Speech Captured

| Test | Duration | Content | Mean volume | Max volume |
|---|---|---|---|---|
| 1 | 13.3 s | ambient room noise | −50.0 dB | −34.6 dB |
| 2 | 71.7 s | **speaking into the mic** | **−34.0 dB** | **−9.8 dB** |

Clear jump in level between the two tests confirms genuine speech capture,
not silence or a fixed noise floor.

## No Mouse, No Keyboard, No Touchscreen

**Constraint**: all USB ports full (camera+mic+speaker); no touchscreen either

**Dead ends checked:**
- `/dev/uinput` — not built into the kernel
- No `ydotool` / `wtype` / `xdotool` / python evdev on the board
- Mic's own HID buttons — device reports no wheel/click capability at all

**Fix implemented**: a tiny file-poll added to the app's main loop —

```
ssh weston@192.168.10.2 'sudo touch /tmp/moilmeet_record_toggle'
```

toggles Record/Stop exactly like the UI button — **zero physical input needed**

## Limitations & Follow-ups

- Start-menu freeze (§ Start-Camera bug) is **unresolved** — use the CLI
  `--source` path in production for now
- 8000×6000 native mode is only 5 fps — smaller same-ratio modes exist but
  weren't verified for the same crop-free behavior
- UVC webcam gadget remains unbuilt — would need an endpoint trade-off or a
  kernel rebuild
- `ffmpeg` install + `/etc/asound.conf` changes are outside the Yocto image —
  won't survive a board reflash
- Record-toggle file is single-purpose — not a general remote-control API yet

## Summary

Fixed the fisheye crop bug, diagnosed (but didn't fix) a start-menu freeze with
a safe workaround, shelved a USB-webcam-gadget idea on hardware grounds, and —
with a static `ffmpeg` build plus an ALSA `dsnoop` split — got the app's own
recording feature capturing **verified real speech**, fully controllable over
SSH with **no mouse, keyboard, or touchscreen at all**.
