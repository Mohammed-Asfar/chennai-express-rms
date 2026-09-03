<#
.SYNOPSIS
  Reports why the billing service will not install.

.DESCRIPTION
  Run this in an Administrator PowerShell window:

    powershell -ExecutionPolicy Bypass -File installer\diagnose.ps1

  It checks each precondition in turn and tries the service creation itself,
  printing the real exit code and message. Nothing is left behind — a service it
  manages to create is removed again before it finishes.

  This exists because the installer runs elevated and this shell usually is not,
  so the failure cannot be reproduced from a normal terminal.
#>

$ErrorActionPreference = 'Continue'
$InstallDir = 'C:\Program Files\Chennai Express\backend'
$ServiceName = 'ChennaiExpressRMS'

function Section($text) {
  Write-Host ''
  Write-Host "--- $text" -ForegroundColor Cyan
}

Section 'Elevation'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "  running as        $($id.Name)"
Write-Host "  elevated          $elevated"
if (-not $elevated) {
  Write-Host ''
  Write-Host '  STOP - reopen PowerShell with "Run as administrator" and try again.' -ForegroundColor Red
  exit 1
}

Section 'Files'
foreach ($f in @('server.mjs', 'node\node.exe', 'db', 'config.dat', 'service.ps1')) {
  $path = Join-Path $InstallDir $f
  Write-Host ("  {0,-18} {1}" -f $f, $(if (Test-Path $path) { 'present' } else { 'MISSING' }))
}

Section 'Existing service'
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Host "  $ServiceName is already installed, status $($existing.Status)"
  Write-Host '  Removing it so the test below starts clean.'
  cmd /c "sc.exe stop $ServiceName" | Out-Null
  Start-Sleep -Seconds 2
  cmd /c "sc.exe delete $ServiceName" | Out-Null
  Start-Sleep -Seconds 2
} else {
  Write-Host '  not installed'
}

Section 'Can the bundled server start at all?'
# If this fails, the service would install and then refuse to run, which looks
# like the same problem from the outside.
$probe = Join-Path $env:TEMP 'ce-probe'
Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $probe -Force | Out-Null

$node = Join-Path $InstallDir 'node\node.exe'
$server = Join-Path $InstallDir 'server.mjs'

if ((Test-Path $node) -and (Test-Path $server)) {
  $log = Join-Path $probe 'probe.log'
  $env:PORT = '45123'
  $env:DB_PATH = (Join-Path $probe 'probe.db')
  $env:JWT_SECRET = 'diagnostic-only-secret-that-is-long-enough-here'

  $p = Start-Process -FilePath $node -ArgumentList "`"$server`"" `
    -WorkingDirectory $InstallDir -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err"

  Start-Sleep -Seconds 10

  try {
    $health = Invoke-WebRequest -Uri 'http://127.0.0.1:45123/health' -TimeoutSec 3 -UseBasicParsing
    Write-Host "  the server runs: $($health.Content)" -ForegroundColor Green
  } catch {
    Write-Host '  the server did NOT answer' -ForegroundColor Red
    foreach ($f in @($log, "$log.err")) {
      if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) {
        Write-Host "  --- $(Split-Path $f -Leaf)"
        Get-Content $f -TotalCount 20 | ForEach-Object { Write-Host "    $_" }
      }
    }
  }

  if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:PORT, Env:DB_PATH, Env:JWT_SECRET -ErrorAction SilentlyContinue
  Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Write-Host '  skipped - node.exe or server.mjs is missing'
}

Section 'Creating the service'
$binPath = '\"{0}\" \"{1}\"' -f $node, $server
$create = 'sc.exe create {0} binPath= "{1}" start= auto obj= "LocalSystem" DisplayName= "Chennai Express Billing Service"' -f `
  $ServiceName, $binPath

Write-Host '  command:'
Write-Host "    $create"
Write-Host ''
Write-Host '  output:'
cmd /c $create 2>&1 | ForEach-Object { Write-Host "    $_" }
Write-Host "  exit code         $LASTEXITCODE"

if ($LASTEXITCODE -eq 0) {
  Write-Host ''
  Write-Host '  Created. Checking what Windows recorded:'
  $wmi = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
  Write-Host "    PathName        $($wmi.PathName)"
  Write-Host "    StartName       $($wmi.StartName)"

  Write-Host ''
  Write-Host '  Starting it:'
  cmd /c "sc.exe start $ServiceName" 2>&1 | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" }
  Start-Sleep -Seconds 8

  $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  Write-Host "    status          $($svc.Status)"

  try {
    $h = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/health' -TimeoutSec 3 -UseBasicParsing
    Write-Host "    health          $($h.Content)" -ForegroundColor Green
  } catch {
    Write-Host '    health          not answering' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Most recent service errors from the event log:'
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddMinutes(-5) } `
      -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -like "*$ServiceName*" -or $_.Message -like '*Chennai*' } |
      Select-Object -First 3 |
      ForEach-Object { Write-Host "    $($_.TimeCreated): $($_.Message)" }
  }

  Write-Host ''
  Write-Host '  Cleaning up the test service.'
  cmd /c "sc.exe stop $ServiceName" | Out-Null
  Start-Sleep -Seconds 2
  cmd /c "sc.exe delete $ServiceName" | Out-Null
}

Write-Host ''
Write-Host 'Done. Copy everything above.' -ForegroundColor Cyan
