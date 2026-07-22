#!/usr/bin/env bash
# =============================================================================
# install-boot-autostart.sh — run from Git Bash on the PC, ONCE the EVK SSH is
# reachable again. Installs BOTH boot services on the RZ/V2H EVK:
#   1) moilmeet-cpp.service    -> auto-start the C++/LVGL video app on the display
#   2) usb-audio-gadget.service-> EVK becomes a USB mic + speaker to the host PC
# Idempotent. After this, every power-on: app shows on screen + USB audio works.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
EVK_IP="${EVK_IP:-192.168.10.2}"; EVK_USER="${EVK_USER:-weston}"
KEY="${SSH_KEY:-/c/Users/User/.ssh/evk_rzv2h}"
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=8 ${EVK_USER}@${EVK_IP}"
SCP="scp -i $KEY -o StrictHostKeyChecking=no"
B="${EVK_USER}@${EVK_IP}"

echo ">>> 0. sanity: reachable?"
$SSH 'echo ok; id' || { echo "EVK not reachable — power-cycle / fix SSH first"; exit 1; }

echo ">>> 1. gadget modules -> /home/weston/usb-gadget/modules (persistent)"
$SSH 'mkdir -p ~/usb-gadget/modules'
$SCP "$ROOT/usb-gadget-modules/libcomposite.ko" "$ROOT/usb-gadget-modules/u_audio.ko" \
     "$ROOT/usb-gadget-modules/usb_f_uac2.ko"    "$ROOT/usb-gadget-modules/g_audio.ko" \
     "$B:~/usb-gadget/modules/"
$SCP "$HERE/board-usb-gadget-up.sh" "$B:~/usb-gadget/"
$SSH 'chmod +x ~/usb-gadget/board-usb-gadget-up.sh'

echo ">>> 2. ensure the app + assets are present (build-side already deployed them)"
$SSH 'ls ~/moilmeet-cpp/moilmeet_app >/dev/null 2>&1 && echo "app present" || echo "WARN: app missing — redeploy from WSL"'

echo ">>> 3. install systemd units (needs root; weston has sudo-nopass)"
$SCP "$HERE/moilmeet-cpp.service" "$HERE/usb-audio-gadget.service" "$B:/tmp/"
$SSH 'sudo cp /tmp/moilmeet-cpp.service /tmp/usb-audio-gadget.service /etc/systemd/system/ \
      && sudo systemctl daemon-reload \
      && sudo systemctl enable --now usb-audio-gadget.service moilmeet-cpp.service'

echo ">>> 4. status"
$SSH 'echo "--- app ---";    systemctl --no-pager status moilmeet-cpp.service   | head -6
      echo "--- gadget ---"; systemctl --no-pager status usb-audio-gadget.service | head -6'
echo ">>> DONE. Reboot the EVK to confirm both auto-start. Cable CN2->PC for USB audio."
