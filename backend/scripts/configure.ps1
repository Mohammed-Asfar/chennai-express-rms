<#
.SYNOPSIS
  Writes the encrypted configuration for an installed service.

.DESCRIPTION
  Run by the installer, after the files are copied and before the service starts.

  The equivalent TypeScript tool needs the source tree and tsx; an installed till
  has neither, so this does the same job with what Windows already provides.

  Generates a JWT secret unique to this installation. A token forged on one
  restaurant's PC is then meaningless on another.

  The cloud connection string is baked in at build time by build.ps1. It is not
  a secret from the vendor — it is a secret from the restaurant, which is why it
  ends up DPAPI-encrypted and behind an ACL rather than in a text file.
#>

[CmdletBinding()]
param(
  # The directory holding server.mjs.
  [Parameter(Mandatory)][string]$Path,

  # Neon connection string. Empty means the till runs offline-only: billing
  # works, cloud backup and updates do not.
  [string]$CloudDatabaseUrl = '',

  [ValidateSet('stable', 'beta')]
  [string]$UpdateChannel = 'stable'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $Path 'server.mjs'))) {
  throw "Not an install directory - server.mjs is not in $Path"
}

# Baked in by build.ps1 when the installer was compiled. Left as the literal
# placeholder for a source build, which then configures an offline-only till.
$bakedUrl = '@CLOUD_DATABASE_URL@'
if ($CloudDatabaseUrl -eq '' -and $bakedUrl -notmatch '^@.*@$') {
  $CloudDatabaseUrl = $bakedUrl
}

# 48 bytes of CSPRNG, base64url so it survives a text config with no escaping.
$bytes = New-Object byte[] 48
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$jwtSecret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

$lines = @(
  '# Written by the installer. Encrypted to this machine - copying it elsewhere',
  '# will not work. Regenerate by reinstalling.',
  "JWT_SECRET=$jwtSecret",
  "UPDATE_CHANNEL=$UpdateChannel",
  'NODE_ENV=production'
)

if ($CloudDatabaseUrl -ne '') {
  $lines += "CLOUD_DATABASE_URL=$CloudDatabaseUrl"
}

$plaintext = $lines -join "`n"

# LocalMachine scope: the service runs as LocalSystem while this runs as the
# installing administrator, and CurrentUser scope would leave the service unable
# to read what was just written.
Add-Type -AssemblyName System.Security
$plainBytes = [Text.Encoding]::UTF8.GetBytes($plaintext)
$encrypted = [Security.Cryptography.ProtectedData]::Protect($plainBytes, $null, 'LocalMachine')
$encoded = [Convert]::ToBase64String($encrypted)

$target = Join-Path $Path 'config.dat'
[IO.File]::WriteAllText($target, $encoded)

# Verify rather than assume. A config that cannot be read back means a service
# that will not start, and finding that out now beats finding out from a
# restaurant that cannot open.
$check = [Convert]::FromBase64String([IO.File]::ReadAllText($target))
$decrypted = [Text.Encoding]::UTF8.GetString(
  [Security.Cryptography.ProtectedData]::Unprotect($check, $null, 'LocalMachine'))

if ($decrypted -ne $plaintext) {
  Remove-Item $target -Force -ErrorAction SilentlyContinue
  throw 'The configuration could not be read back after writing. Nothing was left behind.'
}

Write-Host "Wrote $target"
if ($CloudDatabaseUrl -eq '') {
  Write-Host 'No cloud configured - this till bills offline, without backup or updates.'
} else {
  Write-Host 'Cloud backup and updates are configured.'
}
