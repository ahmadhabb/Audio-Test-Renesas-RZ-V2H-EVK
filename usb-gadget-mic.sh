#!/usr/bin/env bash
# =============================================================================
# usb-gadget-mic.sh - make the RZ/V2H EVK act as a USB MICROPHONE to the PC.
#
# Chain:  ME6S (card1) --alsaloop--> UAC2 gadget (card2) --USB CN2--> PC
# The PC then sees a capture device "Microphone (Source/Sink)".
#
# PHYSICAL: connect EVK **CN2** (micro-AB, USB2.0 Ch0) -> PC with a DATA
#           micro-USB cable. (CN12 is the serial-debug port, NOT this.)
#
# Usage (run from Git Bash on the PC):
#   ./usb-gadget-mic.sh up      # load gadget (mic mode) + start ME6S->gadget bridge
#   ./usb-gadget-mic.sh status  # show UDC state + gadget card + bridge procs
#   ./usb-gadget-mic.sh down     # stop bridge + unload gadget (frees CN2)
#   ./usb-gadget-mic.sh pc-test  # record 5s from the gadget mic ON THIS PC + level
# =============================================================================
set -uo pipefail

EVK_IP="${EVK_IP:-192.168.10.2}"; EVK_USER="${EVK_USER:-weston}"
SSH_KEY="${SSH_KEY:-/c/Users/User/.ssh/evk_rzv2h}"
MODDIR_LOCAL="${MODDIR_LOCAL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usb-gadget-modules}"
SRC_CARD="${SRC_CARD:-plughw:1,0}"     # ME6S physical mic on the EVK
RATE="${RATE:-48000}"
# Name shown on the PC as "Microphone (<MIC_NAME>)". NOTE: the display name is
# actually baked into usb_f_uac2.ko (its function_name string, patched to
# "moilmeet"); to change it you must edit drivers/usb/gadget/function/f_uac2.c
# and rebuild. iProduct/PID below keep the parent-device name consistent and
# force Windows to build a fresh endpoint (it caches the name per USB PID).
MIC_NAME="${MIC_NAME:-moilmeet}"
USB_VID="${USB_VID:-0x1d6b}"
USB_PID="${USB_PID:-0x4d01}"
USB_MFR="${USB_MFR:-Moil}"
USB_SERIAL="${USB_SERIAL:-moilmeet-001}"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=6 "${EVK_USER}@${EVK_IP}")
die(){ echo "ERROR: $*" >&2; exit 1; }

cmd_up() {
  echo ">>> copying gadget modules to EVK"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "$MODDIR_LOCAL/libcomposite.ko" "$MODDIR_LOCAL/u_audio.ko" \
    "$MODDIR_LOCAL/usb_f_uac2.ko" "$MODDIR_LOCAL/g_audio.ko" \
    "${EVK_USER}@${EVK_IP}:/tmp/" || die "scp failed (build modules first)"
  "${SSH[@]}" RATE="$RATE" SRC="$SRC_CARD" NAME="$MIC_NAME" VID="$USB_VID" PID="$USB_PID" MFR="$USB_MFR" SERIAL="$USB_SERIAL" 'bash -s' <<'REMOTE'
INS=/usr/sbin/insmod
cd /tmp
# stop any previous bridge, unload old gadget (|| true: pkill returns 1 when nothing matches)
pkill -x alsaloop 2>/dev/null || true; pkill -x arecord 2>/dev/null || true; pkill -x aplay 2>/dev/null || true
/usr/sbin/rmmod g_audio 2>/dev/null || true
sleep 1
for m in libcomposite u_audio usb_f_uac2; do
  lsmod | grep -q "^${m//-/_}" || sudo $INS ./$m.ko
done
# MIC mode: p_* = gadget->host = microphone; disable c_* (speaker) to fit the 2 iso pipes
# named "moilmeet" (via patched usb_f_uac2.ko + iProduct); unique PID => fresh Windows endpoint
# (already-loaded is fine; run 'down' first if you want to change params)
lsmod | grep -q '^g_audio' || sudo $INS ./g_audio.ko p_chmask=1 p_srate=${RATE:-48000} p_ssize=2 c_chmask=0 \
    idVendor=${VID:-0x1d6b} idProduct=${PID:-0x4d01} \
    iManufacturer="${MFR:-Moil}" iProduct="${NAME:-moilmeet}" iSerialNumber="${SERIAL:-moilmeet-001}"
sleep 1
GADGET_CARD=$(awk '/UAC2Gadget/{print $1}' /proc/asound/cards | head -1)
echo "gadget = card $GADGET_CARD ; UDC state = $(cat /sys/class/udc/15820000.usb/state)"
# bridge real mic -> gadget with clock-drift adaptation (NOT a raw pipe!)
setsid alsaloop -C ${SRC:-plughw:1,0} -P plughw:${GADGET_CARD},0 -r ${RATE:-48000} -c 1 -f S16_LE \
    >/tmp/alsaloop.log 2>&1 < /dev/null &
sleep 2
pgrep -x alsaloop >/dev/null && echo "bridge running (alsaloop)" || { echo "bridge FAILED"; tail /tmp/alsaloop.log; }
REMOTE
  echo ">>> If EVK CN2 is cabled to the PC, it now appears as mic 'Microphone (${MIC_NAME})'."
}

cmd_status() {
  "${SSH[@]}" 'bash -s' <<'REMOTE'
echo "UDC state : $(cat /sys/class/udc/15820000.usb/state 2>/dev/null) ($(cat /sys/class/udc/15820000.usb/current_speed 2>/dev/null))"
echo "gadget    : $(grep UAC2Gadget /proc/asound/cards || echo 'not loaded')"
echo "bridge    : $(pgrep -x alsaloop >/dev/null && echo 'alsaloop running' || echo 'stopped')"
REMOTE
}

cmd_down() {
  "${SSH[@]}" 'bash -s' <<'REMOTE'
pkill -x alsaloop 2>/dev/null || true; pkill -x arecord 2>/dev/null || true; pkill -x aplay 2>/dev/null || true
sleep 2
if ! lsmod | grep -q '^g_audio'; then echo "g_audio not loaded"; exit 0; fi
for i in 1 2 3 4 5; do
  sudo /usr/sbin/rmmod g_audio 2>/dev/null && { echo "gadget unloaded (CN2 freed)"; break; }
  sleep 1
done
lsmod | grep -q '^g_audio' && echo "WARN: g_audio still busy/loaded"
REMOTE
}

cmd_pctest() {
  local ff; ff="$(command -v ffmpeg || echo /c/Users/User/AppData/Local/Microsoft/WinGet/Links/ffmpeg.exe)"
  local out; out="$(dirname "${BASH_SOURCE[0]}")/gadget-mic-test.wav"
  echo ">>> recording 5s from 'Microphone (${MIC_NAME})' on THIS PC (speak into ME6S)"
  "$ff" -hide_banner -loglevel error -f dshow -sample_rate "$RATE" -channels 1 \
     -i "audio=Microphone (${MIC_NAME})" -t 5 -y "$out" || die "record failed (is CN2 connected?)"
  echo ">>> level:"; "$ff" -hide_banner -i "$out" -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume'
  echo ">>> saved: $out"
}

case "${1:-}" in
  up)      cmd_up ;;
  status)  cmd_status ;;
  down)    cmd_down ;;
  pc-test) cmd_pctest ;;
  *) grep -E '^#( |=|!)' "$0" | sed -E 's/^#!? ?//'; exit 1 ;;
esac
