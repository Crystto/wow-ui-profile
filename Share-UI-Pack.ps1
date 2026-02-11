# Publish a UI pack zip to GitHub Releases via gh.
param(
  [Parameter(Mandatory = $true)]
  [string]$ZipPath,
  [Parameter(Mandatory = $true)]
  [string]$Repo,
  [string]$Tag,
  [string]$ReleaseName,
  [string]$Notes,
  [switch]$IncludeReadme = $true,
  [switch]$Draft,
  [switch]$Prerelease
)

$ErrorActionPreference = "Stop" # Fail fast on any error.

if (-not (Test-Path -LiteralPath $ZipPath)) {
  throw "ZipPath not found: $ZipPath"
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI (gh) is required. Install from https://cli.github.com and run 'gh auth login'."
}

$zipFullPath = (Resolve-Path -LiteralPath $ZipPath).Path

# Create a unique temp directory for extraction.
function New-TempDir {
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("wow-ui-pack-share-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $dir | Out-Null
  return $dir
}

# Extract manifest.json and README.txt from the zip, if present.
function Read-ManifestFromZip {
  param([string]$ZipPath)

  $temp = New-TempDir
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $temp -Force
    $manifestPath = Join-Path $temp "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
      return @{ Temp = $temp; Manifest = $null; ReadmePath = $null }
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    $readmePath = Join-Path $temp "README.txt"
    if (-not (Test-Path -LiteralPath $readmePath)) {
      $readmePath = $null
    }

    return @{ Temp = $temp; Manifest = $manifest; ReadmePath = $readmePath }
  }
  catch {
    if (Test-Path -LiteralPath $temp) {
      Remove-Item -LiteralPath $temp -Recurse -Force
    }
    throw
  }
}

$zipInfo = Read-ManifestFromZip -ZipPath $zipFullPath
$manifest = $zipInfo.Manifest

# Default tag and release metadata from manifest when possible.
if (-not $Tag) {
  if ($manifest -and $manifest.version) {
    $Tag = "v{0}" -f $manifest.version
  } else {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($zipFullPath)
    $Tag = "v$base"
  }
}

if (-not $ReleaseName) {
  if ($manifest -and $manifest.name -and $manifest.version) {
    $ReleaseName = "{0} v{1}" -f $manifest.name, $manifest.version
  } else {
    $ReleaseName = $Tag
  }
}

# Build release notes from the manifest and a short install hint.
if (-not $Notes) {
  $lines = @()
  if ($manifest) {
    if ($manifest.name -and $manifest.version) {
      $lines += ("{0} v{1}" -f $manifest.name, $manifest.version)
    }
    if ($manifest.wowVersion) {
      $lines += ("WoW version: {0}" -f $manifest.wowVersion)
    }
    if ($manifest.addons) {
      $addonCount = $manifest.addons.Count
      $lines += ("Addons: {0}" -f $addonCount)

      $maxList = 25
      $list = @($manifest.addons)
      if ($list.Count -gt $maxList) {
        $list = $list[0..($maxList - 1)] + "..."
      }
      if ($list.Count -gt 0) {
        $lines += ("Included: {0}" -f ($list -join ", "))
      }
    }
    $lines += ""
  }
  $lines += "Install: download and extract, then run Install-UI-Pack.cmd (or Install-UI-Pack.ps1)."
  $Notes = ($lines -join "`n")
}

$assets = @($zipFullPath)
if ($IncludeReadme -and $zipInfo.ReadmePath) {
  $assets += $zipInfo.ReadmePath
}

try {
  # Create the release and upload assets.
  $ghArgs = @("release", "create", $Tag) + $assets + @(
    "--repo", $Repo,
    "--title", $ReleaseName,
    "--notes", $Notes
  )

  if ($Draft) { $ghArgs += "--draft" }
  if ($Prerelease) { $ghArgs += "--prerelease" }

  & gh @ghArgs
}
finally {
  # Always clean up the temp extraction folder.
  if ($zipInfo.Temp -and (Test-Path -LiteralPath $zipInfo.Temp)) {
    Remove-Item -LiteralPath $zipInfo.Temp -Recurse -Force
  }
}
