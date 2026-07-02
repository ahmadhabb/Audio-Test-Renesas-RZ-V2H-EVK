@echo off
REM Double-click launcher for usb-mic-test.sh (runs under Git Bash).
REM Pass a subcommand as an argument, e.g.:  usb-mic-test.bat stream
REM With no argument it defaults to a live stream.
setlocal
set "BASH=C:\Program Files\Git\bin\bash.exe"
set "HERE=%~dp0"
if "%~1"=="" (set "ARGS=stream") else (set "ARGS=%*")
"%BASH%" -c "cd \"$(cygpath '%HERE%')\" && ./usb-mic-test.sh %ARGS%"
echo.
pause
