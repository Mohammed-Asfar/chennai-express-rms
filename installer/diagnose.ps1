<#
.SYNOPSIS
  Reports why the billing service will not install.

.DESCRIPTION
  Run this in an Administrator PowerShell window:

    powershell -ExecutionPolicy Bypass -File installer\diagnose.ps1

  It checks each precondition in turn and, if no service is installed, runs the
  real install and reports what happened.

  **It never removes a service it did not create.** An earlier version deleted a
  running service to "start clean", then recreated it the wrong way and reported
  the resulting failure as the installer's fault — turning a working till into a
  broken one and sending the investigation in the wrong direction for an hour.

  A healthy service short-circuits everything: it reports the health response and
  exits without touching anything.

  This exists because the installer runs elevated and a normal shell is not, so
  the failure cannot otherwise be reproduced.
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
  Write-Host "  $ServiceName is installed, status $($existing.Status)"

  # Never touched. An earlier version of this script deleted a working service
  # and recreated it the wrong way, turning a healthy till into a broken one —
  # a diagnostic that breaks what it is inspecting is worse than none.
  if ($existing.Status -eq 'Running') {
    try {
      $h = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/health' -TimeoutSec 3 -UseBasicParsing
      Write-Host "  health            $($h.Content)" -ForegroundColor Green
      Write-Host ''
      Write-Host '  Nothing is wrong. The service is installed and answering.' -ForegroundColor Green
      exit 0
    } catch {
      Write-Host '  health            running, but not answering on 127.0.0.1:4000' -ForegroundColor Red
    }
  }

  Write-Host ''
  Write-Host '  Wrapper log (the service runs node as a child; its errors are here):'
  $wrapperLog = Join-Path $InstallDir 'logs\chennai-service.wrapper.log'
  $errLog = Join-Path $InstallDir 'logs\chennai-service.err.log'
  foreach ($f in @($wrapperLog, $errLog)) {
    if (Test-Path $f) {
      Write-Host "  --- $(Split-Path $f -Leaf)"
      Get-Content $f -Tail 15 | ForEach-Object { Write-Host "    $_" }
    } else {
      Write-Host "  --- $(Split-Path $f -Leaf): not present"
    }
  }

  Write-Host ''
  Write-Host '  To reinstall the service, run:'
  Write-Host "    powershell -File `"$InstallDir\service.ps1`" uninstall -Path `"$InstallDir`""
  Write-Host "    powershell -File `"$InstallDir\service.ps1`" install -Path `"$InstallDir`""
  exit 0
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

Section 'Installing the service through the wrapper'

# The same path the installer takes. node.exe does not speak the Service Control
# Manager protocol, so registering it directly with sc.exe produces error 1053 -
# an earlier version of this script did exactly that and blamed the installer.
$wrapper = Join-Path $InstallDir 'chennai-service.exe'

if (-not (Test-Path $wrapper)) {
  Write-Host '  chennai-service.exe is MISSING from the install directory.' -ForegroundColor Red
  Write-Host '  The bundle was built before the wrapper was added. Rebuild and reinstall.'
  exit 1
}

Write-Host '  writing chennai-service.xml and registering...'
& (Join-Path $InstallDir 'service.ps1') install -Path $InstallDir 2>&1 |
  ForEach-Object { Write-Host "    $_" }

Write-Host "  exit code         $LASTEXITCODE"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host "  status            $($svc.Status)"
  try {
    $h = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/health' -TimeoutSec 5 -UseBasicParsing
    Write-Host "  health            $($h.Content)" -ForegroundColor Green
    Write-Host ''
    Write-Host '  The service is installed and answering. Leaving it running.' -ForegroundColor Green
  } catch {
    Write-Host '  health            not answering' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Wrapper log:'
    $log = Join-Path $InstallDir 'logs\chennai-service.wrapper.log'
    if (Test-Path $log) {
      Get-Content $log -Tail 15 | ForEach-Object { Write-Host "    $_" }
    } else {
      Write-Host '    not present - the wrapper never ran'
    }
  }
} else {
  Write-Host '  the service was not registered' -ForegroundColor Red
}

Write-Host ''
Write-Host 'Done. Copy everything above.' -ForegroundColor Cyan
