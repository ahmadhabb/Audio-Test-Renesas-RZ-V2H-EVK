#!/usr/bin/env bash
# =============================================================================
# usb-mic-test.sh — test the RZ/V2H EVK USB microphone (ME6S) from this PC
#
# The EVK exposes the USB mic as ALSA "card 1: ME6S [USB-Audio]" once the
# out-of-tree snd-usb-audio modules are loaded (see usb-audio-modules/).
# This script drives capture over SSH and plays / records it here.
#
# Usage:
#   ./usb-mic-test.sh check           # ping EVK + list sound cards / capture devs
#   ./usb-mic-test.sh load            # (re)load the USB-audio driver stack on EVK
#   ./usb-mic-test.sh stream          # live stream mic -> PC speakers (Ctrl+C / q to stop)
#   ./usb-mic-test.sh stream 6        # bounded 6-second stream then exit
#   ./usb-mic-test.sh latency         # low-latency live stream (small ALSA buffers)
#   ./usb-mic-test.sh record 5 out.wav# record 5s to out.wav on this PC
#   ./usb-mic-test.sh level 3         # record 3s + print peak/RMS dBFS (signal sanity)
#   ./usb-mic-test.sh stopdev         # kill any lingering arecord on the EVK (free the device)
# =============================================================================
set -uo pipefail

# ---- config (override via env) ----------------------------------------------
EVK_IP="${EVK_IP:-192.168.10.2}"
EVK_USER="${EVK_USER:-weston}"
SSH_KEY="${SSH_KEY:-/c/Users/User/.ssh/evk_rzv2h}"
CARD="${CARD:-hw:1,0}"      # USB mic capture device on the EVK
RATE="${RATE:-48000}"        # 48000 | 96000 | 192000
FMT="${FMT:-S16_LE}"         # arecord format; matching ffplay fmt derived below
MOD_DIR="${MOD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usb-audio-modules}"

SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${EVK_USER}@${EVK_IP}")

# locate ffplay/ffmpeg (winget install path or PATH)
find_tool() {
  local name="$1" p
  for p in \
    "/c/Users/User/AppData/Local/Microsoft/WinGet/Links/$name.exe" \
    "$(command -v "$name" 2>/dev/null)" \
    "$(command -v "$name.exe" 2>/dev/null)"; do
    [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
FFPLAY="$(find_tool ffplay || true)"
FFMPEG="$(find_tool ffmpeg || true)"

# ffplay raw-audio input flags (this ffmpeg build wants -ch_layout, not -ac)
ff_fmt() { case "$FMT" in S16_LE) echo s16le;; S24_3LE) echo s24le;; *) echo s16le;; esac; }

die() { echo "ERROR: $*" >&2; exit 1; }
need_ffplay() { [ -n "$FFPLAY" ] || die "ffplay not found (winget install Gyan.FFmpeg)"; }

# ---- subcommands ------------------------------------------------------------
cmd_check() {
  echo ">>> ping $EVK_IP"
  ping -n 1 -w 2000 "$EVK_IP" >/dev/null 2>&1 && echo "  reachable" || die "EVK not reachable — check cable / PC IP 192.168.10.1 / EVK IP on end1"
  echo ">>> sound cards on EVK"
  "${SSH[@]}" 'cat /proc/asound/cards; echo "--- capture devices ---"; arecord -l'
}

cmd_load() {
  [ -d "$MOD_DIR" ] || die "module dir not found: $MOD_DIR"
  echo ">>> copying modules to EVK:/tmp"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
      "$MOD_DIR/snd-hwdep.ko" "$MOD_DIR/snd-rawmidi.ko" \
      "$MOD_DIR/snd-usbmidi-lib.ko" "$MOD_DIR/snd-usb-audio.ko" \
      "${EVK_USER}@${EVK_IP}:/tmp/" || die "scp failed"
  echo ">>> insmod in dependency order"
  "${SSH[@]}" 'cd /tmp; for m in snd-hwdep snd-rawmidi snd-usbmidi-lib snd-usb-audio; do
      lsmod | grep -q "^${m//-/_}" || sudo /usr/sbin/insmod "./$m.ko"; done
    echo "--- cards ---"; cat /proc/asound/cards'
}

cmd_stream() {
  need_ffplay
  local dur="${1:-}" darg=()
  [ -n "$dur" ] && darg=(-d "$dur")
  echo ">>> live: $CARD @ ${RATE}Hz ${FMT} mono  (Ctrl+C or q to stop)"
  "${SSH[@]}" "arecord -D $CARD -f $FMT -r $RATE -c 1 -t raw -q ${darg[*]}" \
    | "$FFPLAY" -hide_banner -loglevel warning \
        -f "$(ff_fmt)" -ar "$RATE" -ch_layout mono -autoexit -nodisp -i -
}

cmd_latency() {
  need_ffplay
  echo ">>> low-latency live: $CARD @ ${RATE}Hz  (Ctrl+C or q to stop)"
  "${SSH[@]}" "arecord -D $CARD -f $FMT -r $RATE -c 1 -t raw -q --period-size=512 --buffer-size=2048" \
    | "$FFPLAY" -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -probesize 32 \
        -f "$(ff_fmt)" -ar "$RATE" -ch_layout mono -autoexit -nodisp -i -
}

cmd_record() {
  local dur="${1:-5}" out="${2:-usbmic_$(date +%Y%m%d_%H%M%S 2>/dev/null || echo rec).wav}"
  echo ">>> recording ${dur}s from $CARD to $out"
  "${SSH[@]}" "arecord -D $CARD -f $FMT -r $RATE -c 1 -t wav -q -d $dur" > "$out" \
    && echo "  saved: $out ($(wc -c < "$out") bytes)" || die "record failed"
}

cmd_level() {
  local dur="${1:-3}"
  echo ">>> capturing ${dur}s and measuring level on EVK (speak/tap the mic)"
  "${SSH[@]}" "cd /tmp; arecord -D $CARD -f S16_LE -r $RATE -c 1 -t wav -q -d $dur /tmp/_lvl.wav
    python3 - <<'PY'
import wave,audioop,math
w=wave.open('/tmp/_lvl.wav','rb'); d=w.readframes(w.getnframes())
pk=audioop.max(d,2); rms=audioop.rms(d,2)
db=lambda x:20*math.log10(x/32768.0) if x>0 else -999
print(f'peak={pk} ({db(pk):.1f} dBFS)  rms={rms} ({db(rms):.1f} dBFS)')
print('SIGNAL OK' if pk>200 else 'WARNING: near silence — check mic/gain')
PY"
}

cmd_stopdev() {
  echo ">>> stopping lingering arecord on EVK"
  "${SSH[@]}" 'pkill -x arecord 2>/dev/null; echo "device freed"'
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-}" in
  check)   cmd_check ;;
  load)    cmd_load ;;
  stream)  shift; cmd_stream "${1:-}" ;;
  latency) cmd_latency ;;
  record)  shift; cmd_record "${1:-5}" "${2:-}" ;;
  level)   shift; cmd_level "${1:-3}" ;;
  stopdev) cmd_stopdev ;;
  *) grep -E '^#( |=)' "$0" | sed -E 's/^# ?//'; exit 1 ;;
esac
