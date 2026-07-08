#!/usr/bin/env bash
# =============================================================================
# usb-gadget-duplex.sh - make the RZ/V2H EVK act as BOTH a USB microphone AND a
# USB speaker to the PC at the same time (full-duplex UAC2 gadget "moilmeet").
#
# The PC sees TWO devices:
#   - "Microphone (moilmeet)"  : EVK mic  -> PC   (source = ME6S on the EVK)
#   - "Speakers (moilmeet)"     : PC      -> EVK  (sink   = USB speaker on the EVK)
#
# Chains:
#   ME6S (mic card) --alsaloop--> UAC2 gadget playback --USB CN2--> PC   (mic)
#   PC --USB CN2--> UAC2 gadget capture --alsaloop--> USB speaker card   (speaker)
#
# WHY THIS NEEDS A PATCHED MODULE:
#   USBHS on the RZ/V2H has only ~2 iso pipes. A normal UAC2 capture is ASYNC and
#   needs an extra ISO-IN feedback endpoint, so mic(1) + speaker(1) + feedback(1)
#   = 3 endpoints -> bind fails with -19 "couldn't find an available UDC".
#   usb_f_uac2.ko here is REBUILT with UAC2_DEF_CSYNC = ADAPTIVE (u_uac2.h), which
#   drops the feedback endpoint, so mic(1) + speaker(1) = 2 endpoints -> fits.
#   (alsaloop absorbs the resulting clock drift; expect benign over/underrun logs.)
#
# PHYSICAL: connect EVK **CN2** (micro-AB, USB2.0 Ch0) -> PC with a DATA
#           micro-USB cable. (CN12 is the serial-debug port, NOT this.)
#           Plug the ME6S mic and the USB speaker into the EVK USB-A ports.
#
# Usage (run from Git Bash on the PC):
#   ./usb-gadget-duplex.sh up      # load duplex gadget + start both bridges
#   ./usb-gadget-duplex.sh status  # show UDC state, gadget card, source/sink, bridges
#   ./usb-gadget-duplex.sh down     # stop bridges + unload gadget (frees CN2)
# =============================================================================
set -uo pipefail

EVK_IP="${EVK_IP:-192.168.10.2}"; EVK_USER="${EVK_USER:-weston}"
SSH_KEY="${SSH_KEY:-/c/Users/User/.ssh/evk_rzv2h}"
MODDIR_LOCAL="${MODDIR_LOCAL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usb-gadget-modules}"
RATE="${RATE:-48000}"
# alsaloop tuning: large ring buffer + sample-shift sync kills the cross-clock
# over/underruns that otherwise make duplex audio crackle. TLAT in microseconds
# (bigger = fewer xruns, more latency). 150 ms is inaudible-latency for mic/speaker.
TLAT="${TLAT:-150000}"
SYNC_MIC="${SYNC_MIC:-2}"   # 2=captshift (adjust the ME6S capture side)
SYNC_SPK="${SYNC_SPK:-3}"   # 3=playshift (adjust the USB-speaker playback side)
# Card auto-detect keys (override with MIC_MATCH/SPK_MATCH, or force MIC_CARD/SPK_CARD).
MIC_MATCH="${MIC_MATCH:-ME6S}"                 # physical mic on the EVK (source)
SPK_MATCH="${SPK_MATCH:-USB Audio Device}"     # physical USB speaker on the EVK (sink)
MIC_CARD="${MIC_CARD:-}"                        # e.g. plughw:2,0 to force
SPK_CARD="${SPK_CARD:-}"                        # e.g. plughw:1,0 to force
# Display name baked into usb_f_uac2.ko function_name ("moilmeet"). Fresh PID so
# Windows builds fresh endpoints instead of reusing a cached friendly name.
MIC_NAME="${MIC_NAME:-MoilMeet}"
USB_VID="${USB_VID:-0x1d6b}"
USB_PID="${USB_PID:-0x4d05}"
USB_MFR="${USB_MFR:-Moil}"
USB_SERIAL="${USB_SERIAL:-MoilMeet-01}"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=6 "${EVK_USER}@${EVK_IP}")
die(){ echo "ERROR: $*" >&2; exit 1; }

cmd_up() {
  echo ">>> copying gadget modules to EVK (patched adaptive usb_f_uac2.ko)"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "$MODDIR_LOCAL/libcomposite.ko" "$MODDIR_LOCAL/u_audio.ko" \
    "$MODDIR_LOCAL/usb_f_uac2.ko" "$MODDIR_LOCAL/g_audio.ko" \
    "${EVK_USER}@${EVK_IP}:/tmp/" || die "scp failed (build modules first)"
  # NOTE: env values may contain spaces (e.g. SPK_MATCH="USB Audio Device"); ssh
  # concatenates args into one remote command string, so pass them single-quoted
  # inside a single double-quoted command (array-prefix form would word-split them).
  "${SSH[@]}" "RATE='$RATE' MIC_MATCH='$MIC_MATCH' SPK_MATCH='$SPK_MATCH' \
MIC_CARD='$MIC_CARD' SPK_CARD='$SPK_CARD' NAME='$MIC_NAME' \
TLAT='$TLAT' SYNC_MIC='$SYNC_MIC' SYNC_SPK='$SYNC_SPK' \
VID='$USB_VID' PID='$USB_PID' MFR='$USB_MFR' SERIAL='$USB_SERIAL' bash -s" <<'REMOTE'
INS=/usr/sbin/insmod; RM=/usr/sbin/rmmod
cd /tmp
# stop any previous bridges + unload old gadget, and swap in the patched module
pkill -x alsaloop 2>/dev/null || true; pkill -x arecord 2>/dev/null || true; pkill -x aplay 2>/dev/null || true
sudo $RM g_audio 2>/dev/null || true; sleep 1
sudo $RM usb_f_uac2 2>/dev/null || true; sleep 1
for m in libcomposite u_audio; do
  lsmod | grep -q "^${m}" || sudo $INS ./$m.ko
done
sudo $INS ./usb_f_uac2.ko || { echo "FATAL: usb_f_uac2.ko failed to load"; exit 1; }
# DUPLEX: p_* = mic (gadget->host, mono), c_* = speaker (host->gadget, stereo).
# adaptive capture (patched default) => no feedback ep => fits USBHS 2 iso pipes.
sudo $INS ./g_audio.ko \
  p_chmask=1 p_srate=${RATE:-48000} p_ssize=2 \
  c_chmask=3 c_srate=${RATE:-48000} c_ssize=2 \
  idVendor=${VID:-0x1d6b} idProduct=${PID:-0x4d03} \
  iManufacturer="${MFR:-Moil}" iProduct="${NAME:-moilmeet}" iSerialNumber="${SERIAL:-moilmeet-duo}" \
  || { echo "FATAL: g_audio failed (check dmesg for -19 endpoint error)"; exit 1; }
sleep 2
UDC=$(cat /sys/class/udc/15820000.usb/state 2>/dev/null)
GAD=$(awk '/UAC2Gadget/{print $1}' /proc/asound/cards | head -1)
echo "gadget = card $GAD ; UDC state = $UDC"
[ "$UDC" = "configured" ] || echo "WARN: UDC not configured (is CN2 cabled to the PC?)"
# resolve source (mic) and sink (speaker) cards by name unless forced
MIC="${MIC_CARD}"; [ -z "$MIC" ] && { n=$(awk -v k="$MIC_MATCH" '$0 ~ k {print $1}' /proc/asound/cards | head -1); [ -n "$n" ] && MIC="plughw:${n},0"; }
SPK="${SPK_CARD}"; [ -z "$SPK" ] && { n=$(awk -v k="$SPK_MATCH" '$0 ~ k {print $1}' /proc/asound/cards | head -1); [ -n "$n" ] && SPK="plughw:${n},0"; }
echo "mic source  = ${MIC:-<none>}  (match '$MIC_MATCH')"
echo "spk sink    = ${SPK:-<none>}  (match '$SPK_MATCH')"
# MIC bridge: ME6S -> gadget playback (mono). -t big buffer + -S shift = no crackle.
if [ -n "$MIC" ]; then
  setsid alsaloop -C "$MIC" -P plughw:${GAD},0 -r ${RATE:-48000} -c 1 -f S16_LE \
      -t ${TLAT:-150000} -S ${SYNC_MIC:-2} >/tmp/mic_loop.log 2>&1 </dev/null &
  sleep 1; pgrep -x alsaloop >/dev/null && echo "mic bridge running (ME6S -> gadget)" || echo "mic bridge FAILED (see /tmp/mic_loop.log)"
else echo "SKIP mic bridge: no card matched '$MIC_MATCH'"; fi
# SPEAKER bridge: gadget capture -> USB speaker (stereo).
if [ -n "$SPK" ]; then
  setsid alsaloop -C plughw:${GAD},0 -P "$SPK" -r ${RATE:-48000} -c 2 -f S16_LE \
      -t ${TLAT:-150000} -S ${SYNC_SPK:-3} >/tmp/spk_loop.log 2>&1 </dev/null &
  sleep 1; echo "spk bridge running (gadget -> USB speaker)"
else echo "SKIP speaker bridge: no card matched '$SPK_MATCH'"; fi
echo "alsaloop procs = $(pgrep -x alsaloop | wc -l) (expect 2)"
REMOTE
  echo ">>> If EVK CN2 is cabled to the PC, it now shows BOTH 'Microphone (${MIC_NAME})' and 'Speakers (${MIC_NAME})'."
}

cmd_status() {
  "${SSH[@]}" 'bash -s' <<'REMOTE'
echo "UDC state : $(cat /sys/class/udc/15820000.usb/state 2>/dev/null) ($(cat /sys/class/udc/15820000.usb/current_speed 2>/dev/null))"
echo "gadget    : $(grep UAC2Gadget /proc/asound/cards || echo 'not loaded')"
echo "cards     :"; cat /proc/asound/cards | sed 's/^/  /'
echo "bridges   : $(pgrep -x alsaloop | wc -l) alsaloop running (expect 2)"
pgrep -xa alsaloop | sed 's/^/  /'
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

case "${1:-}" in
  up)      cmd_up ;;
  status)  cmd_status ;;
  down)    cmd_down ;;
  *) grep -E '^#( |=|!)' "$0" | sed -E 's/^#!? ?//'; exit 1 ;;
esac
