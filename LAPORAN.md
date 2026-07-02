# Laporan: Mengaktifkan USB Microphone di RZ/V2H EVK

**Tanggal:** 2 Juli 2026
**Target board:** Renesas RZ/V2H EVK (SoC r9a09g057h44)
**Kernel:** Linux 6.1.141-cip43-yocto-standard (aarch64), distro rz-vlp Poky scarthgap 5.0.11
**Hasil akhir:** ✅ USB mic "ME6S" berfungsi sebagai ALSA `card 1`, audio nyata tertangkap & di-stream ke PC — **tanpa reflash kernel**.

---

## 1. Tujuan

Menstream audio dari sebuah USB microphone yang dicolok ke RZ/V2H EVK menuju PC (Windows), untuk keperluan testing audio.

## 2. Titik Awal & Masalah

USB mic **"ME6S"** (VID:PID `0C76:9688`, perangkat USB Audio Class dari JMTek) ter-enumerate dengan benar di EVK dan mengekspos interface USB Audio yang valid:

| Interface | Kelas | Fungsi |
|-----------|-------|--------|
| `5-1:1.0` | 01/01 | AudioControl |
| `5-1:1.1` | 01/02 | AudioStreaming (playback) |
| `5-1:1.2` | 01/02 | AudioStreaming (capture) |
| `5-1:1.3` | HID   | tombol (ter-bind ke usbhid) |

**Namun tidak ada ALSA card yang dibuat** — interface audio tidak punya driver yang nge-bind.

### Akar masalah (didiagnosis sesi sebelumnya)
Konfigurasi kernel VLP:
```
CONFIG_SND_USB=y
# CONFIG_SND_USB_AUDIO is not set   <-- driver snd-usb-audio TIDAK dikompilasi
```
Driver `snd-usb-audio` tidak ada, dan kernel monolitik (`lsmod` kosong, `/lib/modules` kosong) sehingga modprobe mustahil.

### Kenapa bukan audio onboard?
Codec onboard DA7213 **mati total**: SoC gagal mengaktifkan clock SSI/I2S —
`rcar_sound 13c00000.sound: failed to enable clk, error -110` (ETIMEDOUT). Ini bug BSP/device-tree CPG clock, bukan sesuatu yang bisa diperbaiki via mixer. Capture onboard hanya menghasilkan silence (-91 dB). **Jalur USB dipilih** karena USB audio melewati rcar_sound/SSI sepenuhnya, jadi kebal terhadap bug clock -110 ini.

## 3. Strategi Solusi

Membangun `snd-usb-audio` (+ dependensinya) sebagai **loadable kernel module out-of-tree**, lalu `insmod` di EVK. **Tanpa reflash kernel.**

Ini viable karena konfigurasi kernel EVK memungkinkan:
| Setting | Nilai | Implikasi |
|---------|-------|-----------|
| `CONFIG_MODULES` | `y` | Bisa memuat modul |
| `CONFIG_MODVERSIONS` | not set | CRC simbol tidak dicek — cukup vermagic |
| `CONFIG_MODULE_SIG` | not set | Modul tak perlu ditandatangani |
| `CONFIG_SND` / `CONFIG_SND_PCM` | `y` | Core ALSA sudah built-in |

→ **Satu-satunya syarat: string `vermagic` modul harus persis sama** dengan kernel yang berjalan.

## 4. Langkah Pelaksanaan (dari nol)

### 4.1 Menyiapkan lingkungan build (WSL2)
- Mengaktifkan fitur WSL2 di Windows (`wsl --install --no-launch`) → **butuh reboot** (sesi ini dimulai setelah reboot tsb).
- Install distro: `wsl --install -d Ubuntu` → Ubuntu (WSL2, 12 CPU, 7.7 GB RAM).
- Install toolchain cross-compile:
  ```
  apt-get install build-essential bc bison flex libssl-dev libelf-dev \
                  gcc-aarch64-linux-gnu git kmod cpio
  ```
  (aarch64 gcc 15.2 — beda dari gcc 13.4 kernel asli, tapi tidak masalah karena MODVERSIONS mati; vermagic satu-satunya gerbang.)

### 4.2 Menemukan sumber kernel yang tepat
Menelusuri layer Yocto `meta-renesas` branch `scarthgap/rz`:
`meta-rz-bsp/recipes-kernel/linux/linux-renesas_6.1.bb` →

| Variabel | Nilai |
|----------|-------|
| Repo | `github.com/renesas-rz/rz_linux-cip.git` |
| Branch | `rz-6.1-cip43` |
| SRCREV | `6717c06c72df7430323d0d48258ae4090f2d76aa` |
| LINUX_VERSION | `6.1.141-cip43` |

Clone shallow tepat pada commit tsb:
```
git init && git fetch --depth 1 origin 6717c06c... && git checkout FETCH_HEAD
```

### 4.3 Konfigurasi kernel
- Menyalin `.config` asli EVK (di-pull dari `/proc/config.gz` sesi sebelumnya).
- `./scripts/config --module SND_USB_AUDIO` → otomatis memilih `SND_HWDEP=m`, `SND_RAWMIDI=m`, `snd-usbmidi-lib`.

### 4.4 Menyamakan vermagic (bagian paling tricky)
Target: `6.1.141-cip43-yocto-standard`. Investigasi dari mana tiap bagian versi berasal:
- `EXTRAVERSION` di Makefile **kosong** → basis `6.1.141`.
- `-cip43` berasal dari file **`localversion-cip`** di dalam source tree.
- `-yocto-standard` dari `CONFIG_LOCALVERSION`.

Percobaan pertama menghasilkan versi salah: `6.1.141-cip43-cip43-yocto-standard+` (cip43 dobel + trailing `+`). Perbaikan:
```
./scripts/config --set-str LOCALVERSION '-yocto-standard'   # bukan -cip43-yocto-standard
./scripts/config --disable LOCALVERSION_AUTO                 # cegah suffix git
rm -rf .git ; printf '' > .scmversion                        # hapus trailing '+'
```
→ `include/config/kernel.release` = **`6.1.141-cip43-yocto-standard`** ✓

### 4.5 Build
```
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -j12 modules_prepare
make -j12 modules      # ~30 detik (hanya obj-m yang dibangun)
```
Verifikasi:
```
modinfo sound/usb/snd-usb-audio.ko
vermagic: 6.1.141-cip43-yocto-standard SMP preempt mod_unload aarch64   # PERSIS COCOK
```
Empat modul dihasilkan (di-strip debug), semua vermagic identik:
`snd-hwdep.ko`, `snd-rawmidi.ko`, `snd-usbmidi-lib.ko`, `snd-usb-audio.ko`.

### 4.6 Deploy ke EVK
Koneksi: Ethernet langsung, PC `192.168.10.1` ↔ EVK `192.168.10.2` (interface `end1`), SSH key sebagai user `weston`.
```
scp *.ko weston@192.168.10.2:/tmp/
# insmod URUT sesuai dependensi (insmod ada di /usr/sbin, tidak di PATH weston):
sudo /usr/sbin/insmod snd-hwdep.ko
sudo /usr/sbin/insmod snd-rawmidi.ko
sudo /usr/sbin/insmod snd-usbmidi-lib.ko
sudo /usr/sbin/insmod snd-usb-audio.ko
```
Driver otomatis nge-probe device ME6S yang sudah ter-enumerate → **card 1 langsung muncul.**

## 5. Verifikasi

```
$ cat /proc/asound/cards
 0 [rcarsound] : rcar-sound
 1 [ME6S]      : USB-Audio - ME6S c1 ME6S at usb-15810000.usb-1, full speed

$ arecord -l
card 1: ME6S [ME6S], device 0: USB Audio [USB Audio]
```

**Kapabilitas capture:** mono, S16_LE @ 48000/96000/192000 Hz (juga S24_3LE). Ada pula stream playback 48k stereo.

**Uji sinyal nyata** (rekam 3 dtk):
```
peak = 8539  (-11.7 dBFS)     rms = 1055  (-29.8 dBFS)     → SIGNAL OK
```
Bukan silence — kontras dengan onboard yang flat -91 dB. **Mic bekerja penuh.**

**Uji streaming ke PC:** pipeline `ssh 'arecord -t raw' | ffplay -f s16le` berjalan mulus (exit 0), audio terdengar di speaker PC.

## 6. Artefak yang Dihasilkan

Semua di `C:\habb\projects\Audio Test RZ v2h\`:

| File / Folder | Isi |
|---------------|-----|
| `usb-audio-modules/` | 4× `.ko` hasil build + `evk_kernel_config` |
| `usb-mic-test.sh` | Skrip test CLI: `check`, `load`, `stream`, `latency`, `record`, `level` |
| `usb-mic-test.bat` | Launcher klik-dobel untuk skrip di atas |
| `MicEVK.ps1` | Aplikasi GUI (WinForms): nyalakan/matikan mic, pilih rate, test sinyal, rekam |
| `MicEVK.bat` | Launcher klik-dobel aplikasi GUI |
| `LAPORAN.md` | Dokumen ini |

Build tree di WSL: `/root/build/linux` (bisa rebuild kapan saja).

## 7. Catatan & Batasan

- **Tidak persisten di EVK antar-reboot**: rootfs `/lib/modules` kosong. Setelah EVK reboot, modul harus di-`insmod` ulang (`./usb-mic-test.sh load`), dan IP `end1` EVK perlu di-set ulang. Untuk permanen: salin `.ko` ke `/lib/modules/$(uname -r)/` + `depmod`, atau tambahkan ke image Yocto.
- **Audio onboard (DA7213) tetap mati** — bug clock SSI -110 di BSP, di luar cakupan solusi ini.
- **gcc mismatch aman**: modul dibangun dengan gcc 15 vs kernel gcc 13.4; berhasil dimuat karena MODVERSIONS mati sehingga hanya vermagic yang divalidasi.

## 8. Ringkasan Teknis Satu Baris

> Membangun `snd-usb-audio.ko` + 3 dependensi dari source `rz_linux-cip@rz-6.1-cip43` di WSL2 dengan `.config` asli EVK dan vermagic yang dipaksa cocok (`6.1.141-cip43-yocto-standard`), lalu `insmod` di EVK — mengaktifkan USB mic sebagai ALSA card 1 tanpa reflash kernel.
