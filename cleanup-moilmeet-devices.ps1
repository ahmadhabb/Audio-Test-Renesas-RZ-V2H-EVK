# Removes ALL moilmeet/MoilMeet audio devices (present + ghost) and their stale
# MMDevices endpoint registry keys, so a fresh connect enumerates without an "N-" prefix.
# Must run elevated (Administrator).
$ErrorActionPreference = 'Continue'
$log = "$env:TEMP\moilmeet_cleanup.log"
"=== moilmeet cleanup $(Get-Date) ===" | Set-Content $log

# --- 1. Remove all moilmeet PnP device nodes (USB composite, MEDIA, AudioEndpoint) ---
$devs = Get-PnpDevice | Where-Object {
  $_.FriendlyName -match 'moilmeet' -or $_.InstanceId -match 'VID_1D6B&PID_4D0'
}
foreach ($d in $devs) {
  "REMOVE-DEV [$($d.Status)] $($d.Class) '$($d.FriendlyName)'  $($d.InstanceId)" | Add-Content $log
  & pnputil /remove-device "$($d.InstanceId)" 2>&1 | Add-Content $log
}

# --- 2. Delete stale MMDevices endpoint keys (Render + Capture) for moilmeet ---
# These keys are owned by SYSTEM/TrustedInstaller; enable SeTakeOwnership + SeRestore,
# take ownership, grant admins full control, then delete.
$priv = @'
using System;
using System.Runtime.InteropServices;
public static class Priv {
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool LookupPrivilegeValue(string host, string name, out long luid);
  [StructLayout(LayoutKind.Sequential)] struct TP { public uint count; public long luid; public uint attr; }
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP newst, uint len, IntPtr prev, IntPtr rlen);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  public static void Enable(string name){
    IntPtr tok; OpenProcessToken(GetCurrentProcess(), 0x28, out tok);
    long luid; LookupPrivilegeValue(null, name, out luid);
    TP tp = new TP(); tp.count=1; tp.luid=luid; tp.attr=0x2;
    AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
  }
}
'@
try { Add-Type -TypeDefinition $priv -ErrorAction Stop } catch {}
try { [Priv]::Enable('SeTakeOwnershipPrivilege'); [Priv]::Enable('SeRestorePrivilege') } catch { "priv enable failed: $_" | Add-Content $log }

$admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
foreach ($cat in 'Render','Capture') {
  $base = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$cat"
  Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
    $sub = $_
    $props = Join-Path $sub.PSPath 'Properties'
    $p = Get-ItemProperty -Path $props -ErrorAction SilentlyContinue
    $blob = ($p.PSObject.Properties | ForEach-Object { "$($_.Value)" }) -join ' '
    if ($blob -match 'moilmeet') {
      $guid = $sub.PSChildName
      "DEL-REGKEY $cat\$guid" | Add-Content $log
      try {
        $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
          "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$cat\$guid",
          [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
          [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        $acl = $rk.GetAccessControl()
        $acl.SetOwner($admins)
        $rk.SetAccessControl($acl)
        $acl2 = $rk.GetAccessControl()
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule($admins,'FullControl','ContainerInherit','None','Allow')
        $acl2.AddAccessRule($rule); $rk.SetAccessControl($acl2); $rk.Close()
        Remove-Item -Path (Join-Path $base $guid) -Recurse -Force -ErrorAction Stop
        "  deleted OK" | Add-Content $log
      } catch { "  DEL FAILED: $_" | Add-Content $log }
    }
  }
}
"=== done ===" | Add-Content $log
Get-Content $log
