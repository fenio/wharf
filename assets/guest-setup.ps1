# wharf guest setup -- runs once at first logon (staged to C:\OEM via \sources\$OEM$).
#   1) installs the virtio drivers wharf staged to C:\Drivers (incl. viogpudo GPU)
#   2) enables OpenSSH Server for headless / CI access (the wharf control channel)
# Best-effort and idempotent; failures are logged to C:\OEM\wharf-setup.log, never fatal.
$ErrorActionPreference = 'SilentlyContinue'
# idempotent: if a prior run already finished, do nothing (RunOnce + any
# FirstLogonCommand could both fire)
if (Test-Path C:\OEM\wharf-ready) { exit 0 }
Start-Transcript -Path C:\OEM\wharf-setup.log -Append | Out-Null
function Log($m){ Write-Output ("[{0}] {1}" -f (Get-Date -Format o), $m) }
Log "wharf guest setup starting"

# --- wait for outbound networking (slirp NIC may not be ready at first logon) --
for ($i=0; $i -lt 30; $i++) {
  if (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet) { Log "network up"; break }
  Start-Sleep 2
}

# --- 1) install staged drivers into the driver store --------------------------
if (Test-Path C:\Drivers) {
  Log "installing staged drivers from C:\Drivers"
  & pnputil.exe /add-driver C:\Drivers\*\*.inf /subdirs /install 2>&1 | Out-Null
} else { Log "C:\Drivers not present (skipping driver install)" }

# --- 2) OpenSSH Server -------------------------------------------------------
Log "installing OpenSSH Server (FoD)"
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  Log "FoD unavailable, fetching Win32-OpenSSH ARM64 from GitHub"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $u = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-ARM64.zip'
    $z = "$env:TEMP\openssh.zip"
    Invoke-WebRequest -Uri $u -OutFile $z -UseBasicParsing
    Expand-Archive -Path $z -DestinationPath 'C:\Program Files' -Force
    & 'C:\Program Files\OpenSSH-ARM64\install-sshd.ps1'
  } catch { Log "OpenSSH GitHub fallback failed: $_" }
}

# locate the OpenSSH dir (FoD or fallback)
$sshDir = @('C:\Windows\System32\OpenSSH','C:\Program Files\OpenSSH-ARM64','C:\Program Files\OpenSSH') |
  Where-Object { Test-Path (Join-Path $_ 'sshd.exe') } | Select-Object -First 1
Log "OpenSSH dir: $sshDir"

# host keys: generate, then fix ownership/ACLs (sshd's service-mode check is strict;
# files must be owned by Administrators/SYSTEM and not accessible by others, or sshd
# accepts the TCP connection then drops it / fails to start).
if ($sshDir) { & (Join-Path $sshDir 'ssh-keygen.exe') -A 2>&1 | Out-Null }
function Lock-SshFile($p){
  if (Test-Path $p) {
    icacls $p /setowner Administrators 2>&1 | Out-Null
    icacls $p /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' 2>&1 | Out-Null
  }
}
Get-ChildItem 'C:\ProgramData\ssh\ssh_host_*_key' | ForEach-Object { Lock-SshFile $_.FullName }

# install the CI public key for admin login (admins use administrators_authorized_keys,
# which MUST be owned by Administrators/SYSTEM with no other access).
if (Test-Path C:\OEM\authorized_keys) {
  Log "installing administrators_authorized_keys"
  $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
  New-Item -Path 'C:\ProgramData\ssh' -ItemType Directory -Force | Out-Null
  Copy-Item C:\OEM\authorized_keys $ak -Force
  Lock-SshFile $ak
}

# nicer default shell for CI (PowerShell instead of cmd)
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

# firewall + start
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True `
  -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# fallback: on this Win32-OpenSSH ARM64 build the SCM service crashes (error 1067)
# and `sshd.exe` in any non-interactive/session-0 context (plain daemon -> exit 1,
# SYSTEM scheduled task -> no banner) fails. The ONLY thing that works is
# `sshd.exe -D` (no-detach, multi-connection) running in the autologon user's
# ELEVATED INTERACTIVE session. So register an AtLogOn task as that user with
# LogonType=Interactive (the schtasks /it equivalent) + RunLevel=Highest. The VM
# autologons, so this brings SSH up on every boot. (Needs EnableLUA=false, which
# the answer file sets, so the interactive admin token is unfiltered.)
Start-Sleep 3
if ((Get-Service sshd).Status -ne 'Running' -and $sshDir) {
  Log "sshd service not running (1067) -- installing 'sshd -D' interactive logon task as $env:USERNAME"
  $exe = Join-Path $sshDir 'sshd.exe'
  $a = New-ScheduledTaskAction -Execute $exe -Argument '-D'
  $t = New-ScheduledTaskTrigger -AtLogOn
  $p = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
  Register-ScheduledTask -TaskName 'wharf-sshd' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
  Start-ScheduledTask -TaskName 'wharf-sshd'
}

# marker CI can poll for over SSH to confirm setup finished
Set-Content -Path C:\OEM\wharf-ready -Value (Get-Date -Format o)
Log "wharf guest setup done"
Stop-Transcript | Out-Null
