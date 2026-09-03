<#
.SYNOPSIS
  Builds the installer.

.DESCRIPTION
    .\installer\build.ps1
    .\installer\build.ps1 -SkipFlutter     # reuse the existing Flutter build

  Runs the backend bundle (which verifies itself), checks the Flutter release
  build exists, bakes the cloud connection string into the configure script,
  compiles the installer, and prints the SHA-256 that publish:release needs.

  The connection string is read from backend\.env and written into a copy of
  configure.ps1 inside the staged backend. It never touches the repository - the
  staging directory is gitignored and the original script keeps its placeholder.
#>

[CmdletBinding()]
param(
  [switch]$SkipFlutter,
  [switch]$SkipBundle,

  # Overrides backend\.env. Pass '' to build an offline-only installer.
  [string]$CloudDatabaseUrl
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root 'backend'
$desktop = Join-Path $root 'desktop'
$dist = Join-Path $root 'dist'
$staging = Join-Path $root 'installer\staging'

function Find-InnoSetup {
  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    'D:\Software\Inno Setup 6\ISCC.exe'
  )

  foreach ($path in $candidates) {
    if (Test-Path $path) { return $path }
  }

  $onPath = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }

  throw 'Inno Setup 6 was not found. Install it from https://jrsoftware.org/isdl.php'
}

function Get-AppVersion {
  $versionFile = Join-Path $backend 'src\lib\version.ts'
  $content = Get-Content -Raw $versionFile

  if ($content -notmatch "APP_VERSION\s*=\s*'([^']+)'") {
    throw "Could not read APP_VERSION from $versionFile"
  }
  $version = $Matches[1]

  if ($content -notmatch 'APP_BUILD_NUMBER\s*=\s*(\d+)') {
    throw "Could not read APP_BUILD_NUMBER from $versionFile"
  }

  [PSCustomObject]@{ Version = $version; Build = [int]$Matches[1] }
}

function Get-CloudUrl {
  if ($PSBoundParameters.ContainsKey('CloudDatabaseUrl')) { return $CloudDatabaseUrl }

  $envFile = Join-Path $backend '.env'
  if (-not (Test-Path $envFile)) { return '' }

  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*CLOUD_DATABASE_URL\s*=\s*(.+)\s*$') {
      return $Matches[1].Trim().Trim('"').Trim("'")
    }
  }

  return ''
}

# --- checks ---

$iscc = Find-InnoSetup
$app = Get-AppVersion

Write-Host ''
Write-Host "Building Chennai Express $($app.Version) (build $($app.Build))"
Write-Host ''

# --- backend ---

if (-not $SkipBundle) {
  Write-Host '  Bundling the backend...'
  Push-Location $backend
  try {
    # The bundle script smoke-tests itself and exits non-zero if the result does
    # not start, so a broken backend cannot reach an installer.
    #
    # Run through node directly: npm writes warnings to stderr, and PowerShell
    # turns a native command's stderr into a terminating error under
    # $ErrorActionPreference = 'Stop'. The exit code is the real signal.
    & node 'scripts\bundle.mjs' 2>&1 |
      Where-Object { $_ -match 'smoke test|Bundled|failed' } |
      ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw 'The backend bundle failed.' }
  } finally {
    Pop-Location
  }
}

$bundleDir = Join-Path $backend 'dist-bundle'
if (-not (Test-Path (Join-Path $bundleDir 'server.mjs'))) {
  throw "No backend bundle at $bundleDir. Run without -SkipBundle."
}

# --- desktop ---

if (-not $SkipFlutter) {
  Write-Host '  Building the Flutter app (this takes a few minutes)...'
  Push-Location $desktop
  try {
    & flutter build windows --release 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw 'The Flutter build failed.' }
  } finally {
    Pop-Location
  }
}

$desktopDir = Join-Path $desktop 'build\windows\x64\runner\Release'
$desktopExe = Join-Path $desktopDir 'chennai_express_pos.exe'
if (-not (Test-Path $desktopExe)) {
  throw "No Flutter build at $desktopDir. Run without -SkipFlutter."
}

# Refuse a build older than the source it was built from.
#
# Only meaningful when the build was skipped — a build that just ran is current
# by definition, and checking it anyway would reject the very command that fixes
# the problem.
#
# -SkipFlutter packaged a day-old build for several attempts, and the installed
# app failed with "could not resolve the kernel binary" — an error that says
# nothing about staleness and sent the investigation into the installer instead.
if ($SkipFlutter) {
  $newestSource = Get-ChildItem (Join-Path $desktop 'lib') -Recurse -Filter '*.dart' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($newestSource -and $newestSource.LastWriteTime -gt (Get-Item $desktopExe).LastWriteTime) {
    throw ("The Flutter build is older than the source.`n" +
           "  built:   $((Get-Item $desktopExe).LastWriteTime)`n" +
           "  newest:  $($newestSource.LastWriteTime)  ($($newestSource.Name))`n" +
           "Run without -SkipFlutter.")
  }
}

# --- stage, with the connection string baked in ---

Write-Host '  Staging...'

if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$stagedBackend = Join-Path $staging 'backend'
Copy-Item $bundleDir $stagedBackend -Recurse -Force

$cloudUrl = Get-CloudUrl

# Written into the staged copy only. The script in the repository keeps its
# placeholder, so a connection string is never committed.
$configureSource = Join-Path $backend 'scripts\configure.ps1'
$configureStaged = Join-Path $stagedBackend 'configure.ps1'
(Get-Content -Raw $configureSource).Replace('@CLOUD_DATABASE_URL@', $cloudUrl) |
  Set-Content -Path $configureStaged -NoNewline

if ($cloudUrl -eq '') {
  Write-Warning '  No CLOUD_DATABASE_URL - this installer produces an offline-only till.'
} else {
  Write-Host '    Cloud backup and updates configured.'
}

# --- compile ---

Write-Host '  Compiling the installer...'

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }

$iss = Join-Path $PSScriptRoot 'chennai-express.iss'
& $iscc `
  "/DAppVersion=$($app.Version)" `
  "/DDesktopDir=$desktopDir" `
  "/DBackendDir=$stagedBackend" `
  $iss | Where-Object { $_ -match 'Successful|Error|error' } | ForEach-Object { Write-Host "    $_" }

if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }

# --- report ---

$installer = Join-Path $dist "chennai-express-setup-$($app.Version).exe"
if (-not (Test-Path $installer)) { throw "Expected $installer but it was not produced." }

$hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLower()
$size = [Math]::Round((Get-Item $installer).Length / 1MB, 1)

Write-Host ''
Write-Host "  $installer"
Write-Host "  $size MB"
Write-Host "  sha256  $hash"
Write-Host ''
Write-Host '  Publish it with:'
Write-Host "    cd backend"
Write-Host "    npm run publish:release -- --file `"$installer`" --notes `"...`""
Write-Host ''
