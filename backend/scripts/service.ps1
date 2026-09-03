<#
.SYNOPSIS
  Installs, removes, or inspects the Chennai Express billing service.

.DESCRIPTION
  Run by the installer, and by hand when diagnosing a till.

    .\service.ps1 install -Path "C:\Program Files\Chennai Express\backend"
    .\service.ps1 uninstall
    .\service.ps1 status
    .\service.ps1 restart

  Uses sc.exe, which is part of Windows. A third-party service wrapper would be
  one more binary to trust, keep patched, and download at build time; the only
  thing it offers over this is a supervisor process, and Windows already restarts
  a failed service on its own.

  Must run elevated. Installing a service and setting ACLs both require it.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('install', 'uninstall', 'status', 'restart', 'harden')]
  [string]$Action = 'status',

  # The directory holding server.mjs, node\node.exe and db\.
  [string]$Path,

  # Windows account the service runs as.
  #
  # LocalSystem, deliberately. The service binds only to 127.0.0.1 and touches
  # nothing outside its own directory and the printer spooler, but it must start
  # before anyone logs in and must survive the cashier signing out — a per-user
  # account cannot do either. A service account with fewer rights would be
  # tidier; it would also fail to reach a printer installed for another user,
  # which is the first thing a restaurant does.
  [string]$Account = 'LocalSystem'
)

$ServiceName = 'ChennaiExpressRMS'
$DisplayName = 'Chennai Express Billing Service'
$ErrorActionPreference = 'Stop'

function Assert-Elevated {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This must be run as Administrator.'
  }
}

function Get-Service-Safe {
  try { Get-Service -Name $ServiceName -ErrorAction Stop } catch { $null }
}

function Install-BillingService {
  Assert-Elevated

  if (-not $Path) { throw 'Specify -Path, the directory holding server.mjs.' }
  $resolved = (Resolve-Path $Path).Path

  foreach ($required in @('server.mjs', 'node\node.exe', 'db')) {
    if (-not (Test-Path (Join-Path $resolved $required))) {
      throw "Not a valid install directory - $required is missing from $resolved"
    }
  }

  if (Get-Service-Safe) {
    Write-Host 'Service already installed; removing it first.'
    Uninstall-BillingService
  }

  $wrapper = Join-Path $resolved 'chennai-service.exe'
  if (-not (Test-Path $wrapper)) {
    throw "The service wrapper is missing from $resolved. Rebuild the bundle."
  }

  Write-ServiceConfig -Directory $resolved

  # The wrapper registers the service, not sc.exe.
  #
  # node.exe never calls StartServiceCtrlDispatcher, so a service pointing
  # straight at it is killed after 90 seconds with error 1053 - the SCM waits
  # for a handshake that never comes. The binary is fine; it does not speak the
  # protocol. WinSW does, and runs node as a child.
  #
  # Invoked with the call operator rather than through cmd. Wrapping the path in
  # cmd's own quoting produced ""C:\Program Files\... - a doubled leading quote
  # cmd cannot parse - and the install failed before the wrapper ever ran.
  & $wrapper install 2>&1 | ForEach-Object { Write-Host "  $_" }

  # 1073 is ERROR_SERVICE_EXISTS. Reinstalling over an existing service is a
  # normal upgrade, not a failure.
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1073) {
    throw "The service could not be registered (exit code $LASTEXITCODE)."
  }

  Write-Host "Installed $ServiceName."

  Protect-InstallDirectory -Directory $resolved

  & $wrapper start 2>&1 | ForEach-Object { Write-Host "  $_" }
  if ($LASTEXITCODE -ne 0) {
    throw "The service was registered but did not start (exit code $LASTEXITCODE). Check $resolved\logs."
  }

  Wait-ForHealth
}

<#
.SYNOPSIS
  Writes the wrapper's configuration.

.DESCRIPTION
  WinSW reads chennai-service.xml from beside its own executable. Everything the
  service needs to know lives here rather than in the service registration, so
  changing it is a file edit and a restart.
#>
function Write-ServiceConfig {
  param([Parameter(Mandatory)][string]$Directory)

  $node = Join-Path $Directory 'node\node.exe'
  $server = Join-Path $Directory 'server.mjs'
  $logs = Join-Path $Directory 'logs'

  $xml = @"
<service>
  <id>$ServiceName</id>
  <name>$DisplayName</name>
  <description>Local billing, printing and cloud backup for Chennai Express. Stopping this service stops billing.</description>
  <executable>$node</executable>
  <arguments>"$server"</arguments>
  <workingdirectory>$Directory</workingdirectory>
  <startmode>Automatic</startmode>
  <logpath>$logs</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
  <!-- A till that crashes mid-service must come back on its own. -->
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
</service>
"@

  $target = Join-Path $Directory 'chennai-service.xml'
  [IO.File]::WriteAllText($target, $xml)
  Write-Host "Wrote $target"
}

function Uninstall-BillingService {
  Assert-Elevated

  if (-not (Get-Service-Safe)) {
    Write-Host 'Service is not installed.'
    return
  }

  # Through the wrapper when it is there, so it can clean up its own state.
  $wrapper = if ($Path) { Join-Path (Resolve-Path $Path).Path 'chennai-service.exe' } else { $null }

  if ($wrapper -and (Test-Path $wrapper)) {
    & $wrapper stop 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $wrapper uninstall 2>&1 | Out-Null
  } else {
    # The wrapper is already gone - an uninstall that removed files first.
    & sc.exe stop $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe delete $ServiceName | Out-Null
  }

  # Deletion is asynchronous, and a reinstall started too soon fails with
  # "marked for deletion".
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Service-Safe)) { break }
    Start-Sleep -Milliseconds 500
  }

  Write-Host "Removed $ServiceName."
}

<#
.SYNOPSIS
  Locks the install directory so only administrators and the service can read it.

.DESCRIPTION
  This is what makes the licence check and the encrypted config mean anything.
  Without it a cashier can open config.dat, replace server.mjs, or point the
  backend at their own database - and every protection above it is decoration.

  Inheritance is disabled first. Program Files already grants Users read access,
  and an inherited allow rule cannot be removed, only overridden.
#>
function Protect-InstallDirectory {
  param([Parameter(Mandatory)][string]$Directory)

  Assert-Elevated

  $acl = Get-Acl $Directory

  # $true copies the inherited rules in so they can then be pruned; without the
  # copy, disabling inheritance would strip Administrators too and lock everyone
  # out of a directory nobody can then fix.
  $acl.SetAccessRuleProtection($true, $true)
  Set-Acl -Path $Directory -AclObject $acl

  $acl = Get-Acl $Directory
  foreach ($rule in @($acl.Access)) {
    $name = $rule.IdentityReference.Value
    if ($name -match 'BUILTIN\\Users|Everyone|Authenticated Users|INTERACTIVE') {
      [void]$acl.RemoveAccessRule($rule)
    }
  }

  $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $none = [Security.AccessControl.PropagationFlags]::None
  $allow = [Security.AccessControl.AccessControlType]::Allow

  foreach ($account in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
      $account, 'FullControl', $inherit, $none, $allow)
    $acl.AddAccessRule($rule)
  }

  Set-Acl -Path $Directory -AclObject $acl

  Write-Host "Locked $Directory to Administrators and SYSTEM."
  Write-Host 'A standard user can no longer read config.dat or replace server.mjs.'
}

<#
.SYNOPSIS
  Waits for the service to answer, so a broken install fails at install time.
#>
function Wait-ForHealth {
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/health' -TimeoutSec 2 -UseBasicParsing
      if ($response.StatusCode -eq 200) {
        Write-Host 'Service is up and answering.'
        return
      }
    } catch {
      # Not listening yet.
    }
    Start-Sleep -Milliseconds 700
  }

  # Not thrown: the service may still be applying migrations on a slow PC, and
  # failing the install would be worse than a warning the installer can show.
  Write-Warning 'The service did not answer within 30 seconds. Check the Windows event log.'
}

function Show-Status {
  $service = Get-Service-Safe
  if (-not $service) {
    Write-Host 'Not installed.'
    return
  }

  Write-Host ("{0} is {1} (startup: {2})" -f $service.Name, $service.Status, $service.StartType)

  try {
    $health = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/health' -TimeoutSec 3 -UseBasicParsing
    Write-Host "Health: $($health.Content)"
  } catch {
    Write-Host 'Health: not answering on 127.0.0.1:4000'
  }
}

try {
  switch ($Action) {
    'install'   { Install-BillingService }
    'uninstall' { Uninstall-BillingService }
    'restart'   { Assert-Elevated; Restart-Service -Name $ServiceName -Force; Show-Status }
    'harden'    { if (-not $Path) { throw 'Specify -Path.' }; Protect-InstallDirectory -Directory (Resolve-Path $Path).Path }
    default     { Show-Status }
  }
}
catch {
  # One readable line, then a non-zero exit. The installer shows this verbatim,
  # and a PowerShell exception dump tells whoever is standing at the till
  # nothing they can act on.
  Write-Host "FAILED: $($_.Exception.Message)"
  if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
    Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber)"
  }
  exit 1
}
