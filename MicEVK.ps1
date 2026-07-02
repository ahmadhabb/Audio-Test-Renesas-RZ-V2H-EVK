# =============================================================================
#  MicEVK - simple app to turn the RZ/V2H EVK USB microphone on/off from this PC.
#  WinForms GUI wrapping the tested pipeline:  ssh arecord | ffplay.
#  Launch via MicEVK.bat (double-click) or: powershell -File MicEVK.ps1
#
#  Robust start/stop: the live stream is detected and killed by PROCESS SIGNATURE
#  (ffplay reading raw audio from stdin, ssh running "arecord -t raw"), not by the
#  Git-Bash launcher PID -- because bin\bash.exe is a stub that exits immediately.
# =============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- paths & tooling --------------------------------------------------------
$proj = $PSScriptRoot
$drive = $proj.Substring(0,1).ToLower()
$bashProj = "/$drive" + ($proj.Substring(2) -replace '\\','/')   # C:\a\b -> /c/a/b
# use the REAL bash (usr\bin) which waits for the pipeline; bin\bash.exe is a stub
$bash = @("C:\Program Files\Git\usr\bin\bash.exe",
          "C:\Program Files\Git\bin\bash.exe",
          "C:\Program Files (x86)\Git\usr\bin\bash.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { [void][Windows.Forms.MessageBox]::Show("Git Bash not found. Install Git for Windows.","MicEVK"); exit 1 }

$script:jobs     = @()      # queue of one-shot actions (check/level/record)
$script:starting = $false   # true between "Turn On" click and stream appearing
$script:startAt  = $null
$script:uiOn     = $false   # last UI state, to avoid redundant redraws

# ---- colors / style ---------------------------------------------------------
$cBg    = [Drawing.Color]::FromArgb(30,32,38)
$cCard  = [Drawing.Color]::FromArgb(42,45,54)
$cTxt   = [Drawing.Color]::FromArgb(228,230,236)
$cGreen = [Drawing.Color]::FromArgb(56,178,116)
$cRed   = [Drawing.Color]::FromArgb(214,84,84)
$cGray  = [Drawing.Color]::FromArgb(120,124,134)
$cGold  = [Drawing.Color]::FromArgb(214,170,74)
$fBase  = New-Object Drawing.Font("Segoe UI",10)

# ---- form -------------------------------------------------------------------
$form = New-Object Windows.Forms.Form
$form.Text = "MicEVK - USB Mic RZ/V2H"
$form.Size = New-Object Drawing.Size(470,430)
$form.StartPosition = "CenterScreen"
$form.BackColor = $cBg
$form.Font = $fBase
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Text = "USB Microphone  -  RZ/V2H EVK"
$title.ForeColor = $cTxt
$title.Font = New-Object Drawing.Font("Segoe UI",13,[Drawing.FontStyle]::Bold)
$title.Location = '20,15'; $title.Size = '420,28'
$form.Controls.Add($title)

$dot = New-Object Windows.Forms.Label
$dot.Text = [char]0x25CF
$dot.Font = New-Object Drawing.Font("Segoe UI",16)
$dot.ForeColor = $cGray
$dot.Location = '20,50'; $dot.Size = '26,28'
$form.Controls.Add($dot)

$status = New-Object Windows.Forms.Label
$status.Text = "Mic is off"
$status.ForeColor = $cTxt
$status.Location = '46,54'; $status.Size = '390,24'
$form.Controls.Add($status)

$lblRate = New-Object Windows.Forms.Label
$lblRate.Text = "Sample rate:"; $lblRate.ForeColor = $cTxt
$lblRate.Location = '20,92'; $lblRate.Size = '82,24'
$form.Controls.Add($lblRate)

$cbRate = New-Object Windows.Forms.ComboBox
$cbRate.DropDownStyle = "DropDownList"
[void]$cbRate.Items.AddRange(@("48000 Hz","96000 Hz","192000 Hz"))
$cbRate.SelectedIndex = 0
$cbRate.Location = '104,89'; $cbRate.Size = '110,26'
$form.Controls.Add($cbRate)

$chkLat = New-Object Windows.Forms.CheckBox
$chkLat.Text = "Low latency"; $chkLat.ForeColor = $cTxt
$chkLat.Location = '232,90'; $chkLat.Size = '180,24'
$form.Controls.Add($chkLat)

$btnOn = New-Object Windows.Forms.Button
$btnOn.Text = "Turn On Mic"; $btnOn.ForeColor = [Drawing.Color]::White
$btnOn.BackColor = $cGreen; $btnOn.FlatStyle = "Flat"; $btnOn.FlatAppearance.BorderSize = 0
$btnOn.Font = New-Object Drawing.Font("Segoe UI",12,[Drawing.FontStyle]::Bold)
$btnOn.Location = '20,128'; $btnOn.Size = '205,54'
$form.Controls.Add($btnOn)

$btnOff = New-Object Windows.Forms.Button
$btnOff.Text = "Turn Off"; $btnOff.ForeColor = [Drawing.Color]::White
$btnOff.BackColor = $cRed; $btnOff.FlatStyle = "Flat"; $btnOff.FlatAppearance.BorderSize = 0
$btnOff.Font = New-Object Drawing.Font("Segoe UI",12,[Drawing.FontStyle]::Bold)
$btnOff.Location = '235,128'; $btnOff.Size = '205,54'; $btnOff.Enabled = $false
$form.Controls.Add($btnOff)

$btnCheck = New-Object Windows.Forms.Button
$btnCheck.Text = "Check Connection"; $btnCheck.ForeColor = $cTxt; $btnCheck.BackColor = $cCard
$btnCheck.FlatStyle = "Flat"; $btnCheck.FlatAppearance.BorderSize = 0
$btnCheck.Location = '20,194'; $btnCheck.Size = '132,34'
$form.Controls.Add($btnCheck)

$btnLevel = New-Object Windows.Forms.Button
$btnLevel.Text = "Test Signal"; $btnLevel.ForeColor = $cTxt; $btnLevel.BackColor = $cCard
$btnLevel.FlatStyle = "Flat"; $btnLevel.FlatAppearance.BorderSize = 0
$btnLevel.Location = '162,194'; $btnLevel.Size = '132,34'
$form.Controls.Add($btnLevel)

$btnRec = New-Object Windows.Forms.Button
$btnRec.Text = "Record 5s"; $btnRec.ForeColor = $cTxt; $btnRec.BackColor = $cCard
$btnRec.FlatStyle = "Flat"; $btnRec.FlatAppearance.BorderSize = 0
$btnRec.Location = '304,194'; $btnRec.Size = '136,34'
$form.Controls.Add($btnRec)

$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = "Vertical"
$log.BackColor = [Drawing.Color]::FromArgb(22,23,28); $log.ForeColor = $cGray
$log.Font = New-Object Drawing.Font("Consolas",9)
$log.Location = '20,240'; $log.Size = '420,140'
$form.Controls.Add($log)

# ---- helpers ----------------------------------------------------------------
function Log($m){ $log.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format HH:mm:ss), $m)) }
function Rate(){ ($cbRate.SelectedItem -split ' ')[0] }

function SetUi($state){
  switch($state){
    "on"      { $dot.ForeColor=$cGreen; $status.Text="Mic is ON - listening"; $btnOn.Enabled=$false; $btnOff.Enabled=$true }
    "off"     { $dot.ForeColor=$cGray;  $status.Text="Mic is off";            $btnOn.Enabled=$true;  $btnOff.Enabled=$false }
    "connect" { $dot.ForeColor=$cGold;  $status.Text="Connecting...";         $btnOn.Enabled=$false; $btnOff.Enabled=$true }
  }
}

# --- detect the live stream by process signature (immune to bash stub) -------
function Get-LiveFfplay { Get-CimInstance Win32_Process -Filter "Name='ffplay.exe'" -EA SilentlyContinue |
                          Where-Object { $_.CommandLine -like '*ch_layout*' } }
# kill ONLY the local worker processes (ffplay + streaming ssh). Safe to call
# right before starting a new stream -- does NOT touch the EVK-side arecord.
function Kill-LocalMic {
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffplay.exe'" -EA SilentlyContinue | Where-Object { $_.CommandLine -like '*ch_layout*' })
  $procs += @(Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -EA SilentlyContinue | Where-Object { $_.CommandLine -like '*-t raw*' })
  foreach($p in $procs){ if($p){ & taskkill /F /T /PID $p.ProcessId *> $null } }
}
# full stop: kill local workers AND free the ALSA device on the EVK.
# NOTE: only call this on Turn Off / close -- never right before a start, or the
# async "pkill arecord" can race and kill the just-started capture.
function Stop-LiveMic {
  Kill-LocalMic
  Start-Process -FilePath $bash -ArgumentList ('-lc "cd '+"'$bashProj'"+' && ./usb-mic-test.sh stopdev"') -WindowStyle Hidden | Out-Null
}

# --- one-shot actions via background jobs (reliable output capture) ----------
function Run-Action($name, $shcmd, $cb){
  Log "$name..."
  $job = Start-Job -ScriptBlock { param($b,$c) & $b -lc $c 2>&1 } -ArgumentList $bash, $shcmd
  $script:jobs += ,@{ Job=$job; Cb=$cb; Name=$name }
}

# ---- actions ----------------------------------------------------------------
$btnOn.Add_Click({
  if (Get-LiveFfplay) { return }               # already running
  $mode = if ($chkLat.Checked) { "latency" } else { "stream" }
  $cmd  = "cd '$bashProj' && RATE=$(Rate) ./usb-mic-test.sh $mode"
  Kill-LocalMic                                 # clear local stragglers only (no remote pkill race)
  $script:starting = $true; $script:startAt = Get-Date
  Start-Process -FilePath $bash -ArgumentList ('-lc "'+$cmd+'"') -WindowStyle Hidden | Out-Null
  SetUi "connect"
  Log ("Turning on mic @ {0} Hz{1}" -f (Rate), $(if($chkLat.Checked){" (low latency)"}else{""}))
})

$btnOff.Add_Click({
  Stop-LiveMic
  $script:starting = $false
  SetUi "off"; $script:uiOn = $false
  Log "Mic turned off."
})

$btnCheck.Add_Click({
  Run-Action "Checking connection" "cd '$bashProj' && ./usb-mic-test.sh check" {
    param($o)
    if ("$o" -match "ME6S") { Log "OK - card 1 ME6S detected." }
    else { Log "Mic NOT detected. Load the driver first (usb-mic-test.sh load)." }
  }
})

$btnLevel.Add_Click({
  Run-Action "Testing signal (3s, speak into the mic)" "cd '$bashProj' && ./usb-mic-test.sh level 3" {
    param($o)
    $line = ("$o" -split "`n" | Where-Object { $_ -match "peak=" } | Select-Object -First 1)
    if ($line) { Log ("Signal: " + $line.Trim()) } else { Log "No level result (check connection)." }
  }
})

$btnRec.Add_Click({
  $file = "recording_$(Get-Date -Format yyyyMMdd_HHmmss).wav"
  Run-Action "Recording 5s -> $file" "cd '$bashProj' && ./usb-mic-test.sh record 5 '$file'" ({
    param($o)
    Log "Saved: $file"
  }).GetNewClosure()
})

# ---- timer: reflect real state & collect finished jobs ----------------------
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
  # 1) live-stream state from actual processes
  $live = [bool](Get-LiveFfplay)
  if ($live) {
    $script:starting = $false
    if (-not $script:uiOn) { SetUi "on"; $script:uiOn = $true; Log "Mic is now streaming." }
  } else {
    if ($script:starting) {
      if (((Get-Date) - $script:startAt).TotalSeconds -gt 8) {
        $script:starting = $false; SetUi "off"; $script:uiOn = $false
        Log "Failed to start - check connection / driver."
      }
    } elseif ($script:uiOn) {
      SetUi "off"; $script:uiOn = $false; Log "Stream stopped."
    }
  }
  # 2) finished one-shot jobs
  if ($script:jobs.Count -gt 0) {
    $done = @()
    foreach ($j in $script:jobs) {
      if ($j.Job.State -ne 'Running') {
        $out = ""
        try { $out = (Receive-Job $j.Job -EA SilentlyContinue | Out-String) } catch {}
        Remove-Job $j.Job -Force -EA SilentlyContinue
        & $j.Cb $out
        $done += $j
      }
    }
    if ($done.Count) { $script:jobs = @($script:jobs | Where-Object { $done -notcontains $_ }) }
  }
})
$timer.Start()

$form.Add_FormClosing({ Stop-LiveMic })

Log "Ready. Click 'Check Connection', then 'Turn On Mic'."
[void]$form.ShowDialog()
