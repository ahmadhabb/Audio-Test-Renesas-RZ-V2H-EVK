@echo off
REM Klik-dobel untuk membuka aplikasi MicEVK (tanpa jendela konsol).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MicEVK.ps1"
