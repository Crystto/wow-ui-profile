param(
  [string]$OutputDir = ".\dist\portable",
  [string]$ExeName = "WoW-UI-Pack-Manager.exe",
  [switch]$NoInstall,
  [switch]$IncludeSidecar
)

$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
$guiScript = Join-Path $repoRoot "app\wow-ui-pack-gui.ps1"
$coreScript = Join-Path $repoRoot "app\wow-ui-pack.ps1"

if (-not (Test-Path -LiteralPath $guiScript)) {
  throw "Missing GUI script: $guiScript"
}
if (-not (Test-Path -LiteralPath $coreScript)) {
  throw "Missing core script: $coreScript"
}

$outRoot = Join-Path $repoRoot $OutputDir
$exePath = Join-Path $outRoot $ExeName

New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

$module = Get-Module -ListAvailable ps2exe | Sort-Object Version -Descending | Select-Object -First 1
if (-not $module -and -not $NoInstall) {
  Write-Host "Installing ps2exe module (CurrentUser)..."
  Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
  $module = Get-Module -ListAvailable ps2exe | Sort-Object Version -Descending | Select-Object -First 1
}

if (-not $module) {
  throw "ps2exe module not found. Install with: Install-Module ps2exe -Scope CurrentUser"
}

Import-Module ps2exe -Force

Write-Host "Preparing bundled build script..."
$guiContent = Get-Content -LiteralPath $guiScript -Raw
$coreContent = Get-Content -LiteralPath $coreScript -Raw
$coreBytes = [System.Text.Encoding]::UTF8.GetBytes($coreContent)
$coreBase64 = [Convert]::ToBase64String($coreBytes)

$tempBundledScript = Join-Path ([System.IO.Path]::GetTempPath()) ("wow-ui-pack-gui-bundled-" + [guid]::NewGuid().ToString("N") + ".ps1")
$bundledContent = @"
`$script:BundledCoreScriptBase64 = '$coreBase64'
$guiContent
"@
Set-Content -LiteralPath $tempBundledScript -Value $bundledContent -Encoding UTF8

Write-Host "Building EXE: $exePath"
try {
  Invoke-PS2EXE `
    -InputFile $tempBundledScript `
    -OutputFile $exePath `
    -Title "WoW UI Pack Manager" `
    -Description "GUI for exporting/importing WoW UI packs." `
    -Product "WoW UI Pack Manager" `
    -Version "1.0.0.0" `
    -Company "wow-ui-profile" `
    -copyright "MIT" `
    -NoConsole `
    -STA
}
finally {
  if (Test-Path -LiteralPath $tempBundledScript) {
    Remove-Item -LiteralPath $tempBundledScript -Force
  }
}

if ($IncludeSidecar) {
  $portableAppDir = Join-Path $outRoot "app"
  New-Item -ItemType Directory -Path $portableAppDir -Force | Out-Null
  Copy-Item -LiteralPath $coreScript -Destination (Join-Path $portableAppDir "wow-ui-pack.ps1") -Force
}
else {
  $portableAppDir = Join-Path $outRoot "app"
  if (Test-Path -LiteralPath $portableAppDir) {
    Remove-Item -LiteralPath $portableAppDir -Recurse -Force
  }
}

# Optional release helper.
$shareScript = Join-Path $repoRoot "Share-UI-Pack.ps1"
if (Test-Path -LiteralPath $shareScript) {
  Copy-Item -LiteralPath $shareScript -Destination (Join-Path $outRoot "Share-UI-Pack.ps1") -Force
}

Write-Host "Portable build ready:"
Write-Host " - $exePath"
if ($IncludeSidecar) {
  Write-Host " - $(Join-Path $portableAppDir 'wow-ui-pack.ps1')"
}
