#!/bin/bash
# =============================================================================
# board-usb-gadget-up.sh — BOARD-SIDE bring-up of the full-duplex USB-audio
# gadget (EVK becomes a USB mic + speaker to the host PC). Runs LOCALLY on the
# RZ/V2H EVK at boot via systemd (usb-audio-gadget.service). No SSH.
#
# Derived from the PC-side usb-gadget-duplex.sh REMOTE block. Modules live in
# $MODDIR (copied here by install-boot-autostart.sh so they survive reboot).
#   p_* = mic  (gadget->host, mono)  ; c_* = speaker (host->gadget, stereo)
#   patched usb_f_uac2.ko => ADAPTIVE capture => no feedback ep => fits USBHS 2 pipes
# =============================================================================
set -uo pipefail
MODDIR="${MODDIR:-/home/weston/usb-gadget/modules}"
INS=/usr/sbin/insmod; RM=/usr/sbin/rmmod
RATE=48000
MIC_MATCH="${MIC_MATCH:-ME6S}"                 # physical mic on the EVK (source)
SPK_MATCH="${SPK_MATCH:-USB Audio Device}"     # physical USB speaker on the EVK (sink)
VID=0x1d6b; PID=0x4d03; MFR=Moil; NAME=MoilMeet; SERIAL=MoilMeet-01

log(){ echo "[usb-gadget] $*"; }

# 0b) load HOST-side USB-audio driver so a plugged USB mic/speaker become ALSA
# cards (this board's kernel has no built-in CONFIG_SND_USB_AUDIO — out-of-tree
# modules live alongside the gadget ones in $MODDIR). Without this the ME6S mic
# and GeneralPlus USB speaker never appear in /proc/asound/cards.
for m in snd-hwdep snd-rawmidi snd-usbmidi-lib snd-usb-audio; do
  lsmod | grep -q "${m//-/_}" || $INS "$MODDIR/$m.ko" 2>/dev/null && log "loaded $m" || true
done
sleep 1

# 1) wait for the USB device controller to appear
for i in $(seq 1 30); do [ -e /sys/class/udc/15820000.usb ] && break; sleep 1; done

# 2) clean slate + load modules (order: libcomposite -> u_audio -> usb_f_uac2 -> g_audio)
pkill -x alsaloop 2>/dev/null || true
$RM g_audio     2>/dev/null || true; sleep 1
$RM usb_f_uac2  2>/dev/null || true; sleep 1
for m in libcomposite u_audio; do lsmod | grep -q "^${m}" || $INS "$MODDIR/$m.ko"; done
$INS "$MODDIR/usb_f_uac2.ko" || { log "FATAL: usb_f_uac2.ko load failed"; exit 1; }
$INS "$MODDIR/g_audio.ko" \
  p_chmask=1 p_srate=$RATE p_ssize=2 \
  c_chmask=3 c_srate=$RATE c_ssize=2 \
  idVendor=$VID idProduct=$PID \
  iManufacturer="$MFR" iProduct="$NAME" iSerialNumber="$SERIAL" \
  || { log "FATAL: g_audio.ko load failed (dmesg: -19 = endpoint limit)"; exit 1; }
sleep 2

GAD=$(awk '/UAC2Gadget/{print $1}' /proc/asound/cards | head -1)
UDC=$(cat /sys/class/udc/15820000.usb/state 2>/dev/null)
log "gadget = card ${GAD:-?} ; UDC = ${UDC:-?} (needs CN2 cabled to PC to be 'configured')"

# 3) resolve physical mic + speaker cards (they may enumerate a few s after boot)
MICn=""; SPKn=""
for i in $(seq 1 20); do
  MICn=$(awk -v k="$MIC_MATCH" '$0 ~ k {print $1}' /proc/asound/cards | head -1)
  SPKn=$(awk -v k="$SPK_MATCH" '$0 ~ k {print $1}' /proc/asound/cards | head -1)
  [ -n "$MICn" ] && [ -n "$SPKn" ] && break; sleep 1
done

# 4) bridges (alsaloop absorbs cross-clock drift; benign xrun logs expected)
if [ -n "$GAD" ] && [ -n "$MICn" ]; then
  setsid alsaloop -C plughw:${MICn},0 -P plughw:${GAD},0 -r $RATE -c 1 -f S16_LE \
    -t 100000 -S 2 >/tmp/mic_loop.log 2>&1 </dev/null &
  log "mic bridge: card$MICn (ME6S) -> gadget card$GAD"
else log "SKIP mic bridge (gadget=$GAD mic=$MICn)"; fi
if [ -n "$GAD" ] && [ -n "$SPKn" ]; then
  setsid alsaloop -C plughw:${GAD},0 -P plughw:${SPKn},0 -r $RATE -c 2 -f S16_LE \
    -t 100000 -S 3 >/tmp/spk_loop.log 2>&1 </dev/null &
  log "spk bridge: gadget card$GAD -> card$SPKn (USB speaker)"
else log "SKIP speaker bridge (gadget=$GAD spk=$SPKn)"; fi

sleep 1
log "up: gadget=card${GAD:-none} mic=card${MICn:-none} spk=card${SPKn:-none} alsaloop=$(pgrep -xc alsaloop) (expect 2)"
# keep the service's cgroup alive so systemd tracks the bridges
wait
