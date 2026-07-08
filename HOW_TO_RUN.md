# How to Run Mode A & Mode B (from boot to working audio)

Step-by-step guide to run the two RZ/V2H EVK audio modes, starting from powering
on the PC, booting the EVK, fixing SSH, until audio actually flows.

- **Mode A** — a USB mic (ME6S) is plugged into the EVK and its audio is *streamed* to the PC. The EVK acts as a "USB-mic receiver".
- **Mode B** — the EVK itself appears as a **USB microphone "moilmeet"** on the PC. The EVK acts as a "USB mic device".

All PC commands are run from **Git Bash** (except setting the PC IP, which uses an **Administrator** PowerShell). All EVK commands run as user `weston` (has passwordless `sudo` = root).

> ⚠️ Nothing persists on the EVK. Every time the EVK reboots, repeat **Sections 2–4**.

---

## 0. Prerequisites (hardware & cables)

| Requirement | Notes |
|---|---|
| Ethernet cable | PC ⟷ EVK **`end1`** (not `end0`). Direct, no router. |
| Serial-debug cable | PC ⟷ EVK **CN12** (USB-UART) — for console login when setting the IP. |
| ME6S USB mic | Plugged into an EVK USB-A port. **Required for both Mode A & B** (it is the audio source). |
| Micro-USB **data** cable | PC ⟷ EVK **CN2** (micro-AB, USB2.0 Ch0). **Mode B only.** Not CN12, not a charge-only cable. |
| Repo on PC | `C:\habb\projects\Audio Test RZ v2h` |
| SSH key | `C:\Users\User\.ssh\evk_rzv2h` (user `weston`) |
| PC tools | Git Bash, ffmpeg/ffplay (winget `Gyan.FFmpeg`) |

IP addresses used: **PC = `192.168.10.1`**, **EVK = `192.168.10.2`** (subnet /24).

---

## 1. Boot the PC & set the PC static IP

1. Power on the PC. Connect the Ethernet cable to the EVK (`end1`) and the serial cable to CN12.
2. Open **PowerShell as Administrator** (right-click → Run as administrator) and run:

   ```powershell
   New-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress 192.168.10.1 -PrefixLength 24
   ```

   > If you get an "already exists" error, the IP is already set — ignore it.
   > `"Ethernet 2"` is the adapter connected to the EVK; adjust if it differs
   > (`Get-NetAdapter` lists them).

3. Verify:

   ```powershell
   Get-NetIPAddress -InterfaceAlias "Ethernet 2" -AddressFamily IPv4 | Select IPAddress,PrefixLength
   ```

---

## 2. Boot the EVK & set the IP on `end1` (via serial console)

1. Power on the EVK and wait for boot to finish.
2. Open a serial terminal to **CN12** (e.g. PuTTY/Tera Term, 115200 8N1) and log in.
3. Become root & set the IP on `end1`:

   ```sh
   sudo ip addr add 192.168.10.2/24 dev end1
   sudo ip link set end1 up
   ```

4. From the PC, confirm the EVK responds to ping (Git Bash or PowerShell):

   ```bash
   ping 192.168.10.2
   ```

   If **ping succeeds**, continue to Section 3. If not, check the Ethernet cable is on `end1` (not `end0`).

---

## 3. Fix SSH port 22 (REQUIRED after every boot) 🔑

> **Why is this needed?** SSH on this EVK uses **dropbear via systemd socket-activation**
> (`dropbear.socket`), which listens on `[::]:22` (IPv6). That socket does **not accept
> IPv4** connections, so **ping succeeds but SSH to port 22 hangs/times out**. This is
> not a firewall (the EVK has no active iptables). The fix: stop the built-in socket and
> run a standalone dropbear bound to IPv4.

Because IPv4 SSH isn't working yet, run this **over the serial console (CN12)** — continuing from the Section 2 session:

```sh
# 1. stop the built-in (IPv6-only) socket-activated dropbear
sudo systemctl stop dropbear.socket

# 2. start standalone dropbear, bound to all IPv4 on port 22
sudo /usr/sbin/dropbear -p 0.0.0.0:22 -r /etc/dropbear/dropbear_rsa_host_key

# 3. verify: it must show 0.0.0.0:22 (IPv4), not :::22
netstat -tln | grep ':22 '
```

Once line 3 shows `0.0.0.0:22 ... LISTEN`, IPv4 SSH is ready.

**Verify from the PC (Git Bash):**

```bash
ssh -i /c/Users/User/.ssh/evk_rzv2h weston@192.168.10.2 'echo OK; uname -r'
```

If it replies `OK` + the kernel version → SSH is good, proceed to the desired mode.

<details>
<summary>If port 22 is still stuck / you have no serial access</summary>

Start a standalone dropbear on another port with an **explicit IPv4 address** (important — a bare `-p 2222` also lands on IPv6-only `:::2222`):

```sh
sudo /usr/sbin/dropbear -p 192.168.10.2:2222 -r /etc/dropbear/dropbear_rsa_host_key
```

Then SSH over that port and run the port-22 fix above from inside:

```bash
ssh -i /c/Users/User/.ssh/evk_rzv2h -p 2222 weston@192.168.10.2
```
</details>

---

## 4. Run **Mode A** — ME6S USB mic → PC

**Source:** ME6S mic on the EVK. **Destination:** PC speakers.

1. Make sure the ME6S mic is plugged into an EVK USB-A port.
2. From Git Bash on the PC:

   ```bash
   cd "/c/habb/projects/Audio Test RZ v2h"

   # load the snd_usb_audio module on the EVK (ME6S becomes ALSA card 1)
   ./usb-mic-test.sh load
   ```

   A successful run shows `card 1: ME6S USB-Audio`.

3. Start the live stream from the EVK mic to the PC speakers (runs until Ctrl+C):

   ```bash
   ./usb-mic-test.sh stream
   ```

**Other `usb-mic-test.sh` subcommands:**

| Command | Purpose |
|---|---|
| `check` | Check connectivity & card status |
| `load` | Load the USB-audio module (ME6S → card 1) |
| `stream` | Live-stream EVK mic → PC speakers |
| `latency` | Measure latency |
| `record [secs] [file]` | Record to a file (default 5 s) |
| `level [secs]` | Show level/VU meter (default 3 s) |
| `stopdev` | Unload the module / stop the device |

> GUI alternative: double-click **`MicEVK.bat`** (or `usb-mic-test.bat`).

---

## 5. Run **Mode B** — EVK as a USB mic "moilmeet" on the PC

**Source:** ME6S mic on the EVK. **Destination:** PC sees the EVK as a USB mic. Great for Zoom/OBS/Audacity.

1. Plug the **micro-USB data cable** from the EVK **CN2** into a PC USB port.
   ⚠️ Not CN12 (that's serial), and use a **data** cable (charge-only won't enumerate).
2. From Git Bash on the PC:

   ```bash
   cd "/c/habb/projects/Audio Test RZ v2h"

   # load the UAC2 gadget + start the ME6S→gadget bridge (alsaloop)
   ./usb-gadget-mic.sh up
   ```

   Successful output: `UDC state = configured`, `gadget = card 2`, `bridge running (alsaloop)`.

3. Verify the PC sees the mic:

   ```bash
   ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | grep moilmeet
   # → "Microphone (moilmeet)" (audio)
   ```

4. (Optional) record 5 s & measure the level while speaking into the ME6S mic:

   ```bash
   ffmpeg -hide_banner -y -f dshow -sample_rate 48000 -channels 1 \
     -i "audio=Microphone (moilmeet)" -t 5 "$TEMP/test.wav"
   ffmpeg -hide_banner -i "$TEMP/test.wav" -af volumedetect -f null NUL 2>&1 | grep volume
   ```

   With sound present, `mean_volume` is around -30 dBFS. If it reads **-91 dB**, that's
   silence (quiet room / mic picking up nothing) — **not** a signal-path error.

5. On the PC, select **"Microphone (moilmeet)"** as the input in any app.

**When done with Mode B — release the gadget:**

```bash
./usb-gadget-mic.sh down
```

**`usb-gadget-mic.sh` subcommands:** `up` | `status` | `down` | `pc-test`.

> ⚠️ Record on the PC at **48000 Hz / mono** (native). ffmpeg's default 44100/stereo can muddy the result.

---

## 5b. Run **Mode B (duplex)** — EVK as BOTH a USB mic AND a USB speaker "MoilMeet"

The PC sees **two** devices at once: **"Microphone (MoilMeet)"** (EVK mic → PC) and
**"Speakers (MoilMeet)"** (PC → EVK's USB speaker).

**Why a special build:** USBHS on the RZ/V2H has only ~2 iso pipes. A normal UAC2
capture is *async* and needs an extra feedback endpoint, so mic + speaker + feedback
= 3 endpoints → the gadget fails to bind (`-19 couldn't find an available UDC`). The
project's `usb-gadget-modules/usb_f_uac2.ko` is **rebuilt** with the capture default set
to *adaptive* (`UAC2_DEF_CSYNC = USB_ENDPOINT_SYNC_ADAPTIVE` in `u_uac2.h`), which drops
the feedback endpoint → mic + speaker = 2 endpoints → both fit.

1. Plug into the **EVK USB-A ports**: the **ME6S mic** *and* your **USB speaker**.
2. Plug the **micro-USB data cable** from EVK **CN2** into a PC USB port (as in Mode B).
3. From Git Bash on the PC:

   ```bash
   cd "/c/habb/projects/Audio Test RZ v2h"
   ./usb-gadget-duplex.sh up
   ```

   Successful output shows `UDC state = configured`, an auto-detected `mic source`
   and `spk sink`, and `alsaloop procs = 2 (expect 2)`.

4. Verify both endpoints are active on the PC (PowerShell):

   ```powershell
   Get-PnpDevice -Class AudioEndpoint | Where-Object { $_.FriendlyName -match 'MoilMeet' -and $_.Status -eq 'OK' } | Select Status,FriendlyName
   # → Speakers (MoilMeet)  +  Microphone (MoilMeet)
   ```

5. In any app, pick **"Microphone (MoilMeet)"** for input and **"Speakers (MoilMeet)"**
   for output. (To test the speaker: set it as the default playback device and play any
   audio — it comes out of the USB speaker attached to the EVK.)

**When done:** `./usb-gadget-duplex.sh down`

**`usb-gadget-duplex.sh` subcommands:** `up` | `status` | `down`.
Card auto-detect can be overridden with env vars, e.g.
`MIC_CARD=plughw:2,0 SPK_CARD=plughw:1,0 ./usb-gadget-duplex.sh up`.

### 5b-1. Audio quality (avoiding crackle)
Duplex runs **two** `alsaloop` bridges that each cross an independent USB clock domain;
with tiny default buffers they produce constant over/underruns → audible crackle. The
script sets a **150 ms ring buffer** + **sample-shift sync** (`-t 150000 -S 2/3`), which
takes steady-state xruns from thousands/sec to ≈0. If you still hear artifacts, raise the
buffer (more latency, fewer xruns):
```bash
TLAT=300000 ./usb-gadget-duplex.sh up      # 300 ms
```

### 5b-2. Clean device name (removing the "N-" prefix)
Windows shows a numeric prefix (e.g. "Speakers (3- MoilMeet)") when several **stale/ghost**
MoilMeet device instances remain (one per past USB PID). To get a clean **"MoilMeet"** with
no prefix, remove the ghosts, then reconnect:
```powershell
# run as Administrator (right-click → Run as administrator):
powershell -ExecutionPolicy Bypass -File cleanup-moilmeet-devices.ps1
```
Then `./usb-gadget-duplex.sh down && ./usb-gadget-duplex.sh up`. The script `pnputil
/remove-device`s every present+ghost MoilMeet node; the fresh gadget then enumerates as
instance #1 → "Microphone (MoilMeet)" / "Speakers (MoilMeet)" with no prefix. (The script
also tries to delete stale MMDevices registry keys; that step may report "access not
allowed" and is safe to ignore — removing the devices is what matters.)

---

## 6. Quick sequence summary

```text
PC on ──▶ [Admin PS] set PC IP 192.168.10.1
EVK on ─▶ [serial CN12] set end1 IP 192.168.10.2
       ─▶ [serial CN12] fix SSH: stop dropbear.socket + dropbear -p 0.0.0.0:22
PC ─▶ [Git Bash] ssh ... 'echo OK'          (confirm SSH works)

Mode A:  ./usb-mic-test.sh load  ➜  ./usb-mic-test.sh stream
Mode B:  (plug CN2 data)  ➜  ./usb-gadget-mic.sh up  ➜  pick "Microphone (moilmeet)" on the PC
         when done:  ./usb-gadget-mic.sh down
Mode B duplex (mic+speaker):  (plug CN2 data + ME6S + USB speaker)
         ➜  ./usb-gadget-duplex.sh up  ➜  pick "Microphone (MoilMeet)" + "Speakers (MoilMeet)"
         when done:  ./usb-gadget-duplex.sh down
```

---

## 7. Quick troubleshooting

| Symptom | Cause / fix |
|---|---|
| Ping works, SSH port 22 times out | dropbear.socket is IPv6-only → run **Section 3** (fix port 22). |
| `EVK not reachable` on `load`/`up` | PC IP / end1 IP not set, or Ethernet on the wrong port. Repeat Sections 1–2. |
| Mode B: PC can't see "moilmeet" | CN2 not plugged / charge-only cable / plugged into CN12. Check `./usb-gadget-mic.sh status` → `UDC state`. |
| Mode B: records but -91 dB (silence) | Quiet room — speak into the ME6S mic; test the gadget path with a tone: `speaker-test -D plughw:2,0 -c 1 -r 48000 -t sine -f 440`. |
| Mode B: `up` fails / UDC error -19 | USBHS has only ~2 iso pipes. Mic-only (`usb-gadget-mic.sh`) uses 1 direction. For mic+speaker together use `usb-gadget-duplex.sh` (its patched adaptive `usb_f_uac2.ko` drops the feedback endpoint so both fit). |
| Duplex: `alsaloop procs` < 2, or one side silent | A source card wasn't detected. Check `./usb-gadget-duplex.sh status` (cards list), then force it, e.g. `SPK_CARD=plughw:1,0 MIC_CARD=plughw:2,0 ./usb-gadget-duplex.sh up`. |
| Duplex: card numbers shift after replug/reboot | ME6S / USB-speaker / gadget cards are auto-detected by name each run, so numbers can move freely; only override with `MIC_CARD`/`SPK_CARD` if detection misses. |
| Duplex: audio crackles / choppy | Cross-clock xruns. Script already uses `-t 150000 -S 2/3`; raise the buffer: `TLAT=300000 ./usb-gadget-duplex.sh up` (§5b-1). |
| Windows name shows "3- MoilMeet" prefix | Stale/ghost device instances. Run `cleanup-moilmeet-devices.ps1` as Admin, then `down`+`up` (§5b-2). |
| Everything gone after an EVK reboot | Normal — nothing persists. Repeat Sections 2–4. |

---

*Full references: `README.md` (end-user guide) and `TECHNICAL_REPORT.md` (technical report).*
