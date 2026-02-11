# Core CLI for exporting/importing WoW UI packs.
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("export", "import")]
  [string]$Command,

  [string]$WowRetailPath,
  [string]$OutputDir,
  [string]$PackName,
  [string]$Version,
  [string]$ZipPath,
  [string[]]$AddonAllowList,
  [string[]]$ExcludeAddons,
  [switch]$IncludeAccountLayout,
  [switch]$IncludeCharacterSettings,
  [string]$SourceCharacter,
  [switch]$AnonymizeAccounts,
  [switch]$NoBackup,
  [switch]$DryRun,
  [string]$TargetAccount,
  [string]$TargetRealm,
  [string]$TargetCharacter
)

$ErrorActionPreference = "Stop" # Fail fast on any error.

# Validate and resolve a path that must exist.
function Resolve-ExistingPath {
  param([string]$PathValue, [string]$Label)
  if (-not $PathValue) {
    throw "$Label is required."
  }
  if (-not (Test-Path -LiteralPath $PathValue)) {
    throw "$Label not found: $PathValue"
  }
  return (Resolve-Path -LiteralPath $PathValue).Path
}

# Prevent file changes while the game is running.
function Ensure-WowClosed {
  $procs = Get-Process -Name "Wow", "WowClassic", "WowB" -ErrorAction SilentlyContinue
  if ($procs) {
    throw "World of Warcraft appears to be running. Close it and try again."
  }
}

# Create a unique temp directory for packaging.
function New-TempDir {
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("wow-ui-pack-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $dir | Out-Null
  return $dir
}

# Write pack metadata into manifest.json.
function Write-Manifest {
  param(
    [string]$Path,
    [string]$Name,
    [string]$PackVersion,
    [string]$WowVersion,
    [string[]]$Addons,
    [bool]$HasCharacterTemplate,
    [string]$CharacterSource
  )

  $manifest = [ordered]@{
    name       = $Name
    version    = $PackVersion
    wowVersion = $WowVersion
    createdAt  = (Get-Date).ToString("yyyy-MM-dd")
    addons     = $Addons
    hasCharacterTemplate = $HasCharacterTemplate
    characterSource = $CharacterSource
    notes      = "Install while WoW is closed."
  }

  $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding ASCII
}

# Copy a folder tree only when the source exists.
function Copy-Safely {
  param([string]$Source, [string]$Destination)
  if (Test-Path -LiteralPath $Source) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
  }
}

# Apply allow/deny filters to addons.
function Should-IncludeAddon {
  param(
    [string]$Name,
    [string[]]$AllowList,
    [string[]]$BlockList
  )

  if ($AllowList -and $AllowList.Count -gt 0) {
    if (-not ($AllowList -contains $Name)) {
      return $false
    }
  }
  if ($BlockList -and $BlockList.Count -gt 0) {
    if ($BlockList -contains $Name) {
      return $false
    }
  }
  return $true
}

# Gather available character folders with settings content.
function Get-CharacterCandidates {
  param([string]$AccountRoot)

  $results = @()
  if (-not (Test-Path -LiteralPath $AccountRoot)) {
    return $results
  }

  $accounts = Get-ChildItem -LiteralPath $AccountRoot -Directory
  foreach ($acct in $accounts) {
    $realms = Get-ChildItem -LiteralPath $acct.FullName -Directory | Where-Object { $_.Name -ne "SavedVariables" }
    foreach ($realm in $realms) {
      $chars = Get-ChildItem -LiteralPath $realm.FullName -Directory
      foreach ($charDir in $chars) {
        $charSavedVars = Join-Path $charDir.FullName "SavedVariables"
        $layoutPath = Join-Path $charDir.FullName "layout-local.txt"
        if ((Test-Path -LiteralPath $charSavedVars) -or (Test-Path -LiteralPath $layoutPath)) {
          $results += [pscustomobject]@{
            Account   = $acct.Name
            Realm     = $realm.Name
            Character = $charDir.Name
            Path      = $charDir.FullName
          }
        }
      }
    }
  }

  return $results
}

# Resolve or prompt for the source character to export.
function Select-CharacterForExport {
  param(
    [string]$AccountRoot,
    [string]$Selection
  )

  $candidates = Get-CharacterCandidates -AccountRoot $AccountRoot
  if ($candidates.Count -eq 0) {
    throw "No character settings were found under: $AccountRoot"
  }

  if ($Selection) {
    $normalized = ($Selection -replace "/", "\").Trim("\")
    $parts = $normalized -split "\\"
    $matches = @()

    if ($parts.Count -eq 2) {
      $realmName = $parts[0]
      $characterName = $parts[1]
      $matches = @($candidates | Where-Object { $_.Realm -eq $realmName -and $_.Character -eq $characterName })
      if ($matches.Count -gt 1) {
        throw "SourceCharacter '$Selection' matches multiple accounts. Use Account\Realm\Character."
      }
    }
    elseif ($parts.Count -eq 3) {
      $accountName = $parts[0]
      $realmName = $parts[1]
      $characterName = $parts[2]
      $matches = @($candidates | Where-Object {
          $_.Account -eq $accountName -and $_.Realm -eq $realmName -and $_.Character -eq $characterName
        })
    }
    else {
      throw "SourceCharacter must be 'Realm\Character' or 'Account\Realm\Character'."
    }

    if ($matches.Count -eq 0) {
      throw "SourceCharacter not found: $Selection"
    }

    return $matches[0]
  }

  if ($candidates.Count -eq 1) {
    return $candidates[0]
  }

  Write-Host "Select the source character to export:"
  for ($i = 0; $i -lt $candidates.Count; $i++) {
    $c = $candidates[$i]
    Write-Host (" [{0}] {1}\{2}\{3}" -f ($i + 1), $c.Account, $c.Realm, $c.Character)
  }

  $choice = Read-Host "Enter a number from the list"
  if ($choice -as [int]) {
    $index = [int]$choice - 1
    if ($index -ge 0 -and $index -lt $candidates.Count) {
      return $candidates[$index]
    }
  }

  throw "Invalid character selection."
}

# Prompt for a value, with optional default.
function Ask-Value {
  param(
    [string]$Prompt,
    [string]$DefaultValue
  )

  if ($DefaultValue) {
    $value = Read-Host ("{0} [{1}]" -f $Prompt, $DefaultValue)
    if (-not $value) {
      return $DefaultValue
    }
    return $value
  }

  $value = Read-Host $Prompt
  if (-not $value) {
    throw "$Prompt is required."
  }
  return $value
}

# Resolve or prompt for the target account folder.
function Resolve-TargetAccountName {
  param(
    [string]$AccountRoot,
    [string]$PreferredName
  )

  if ($PreferredName) {
    $target = Join-Path $AccountRoot $PreferredName
    if (-not (Test-Path -LiteralPath $target)) {
      New-Item -ItemType Directory -Path $target | Out-Null
    }
    return $PreferredName
  }

  $existing = @()
  if (Test-Path -LiteralPath $AccountRoot) {
    $existing = Get-ChildItem -LiteralPath $AccountRoot -Directory
  }

  if ($existing.Count -eq 1) {
    return $existing[0].Name
  }

  if ($existing.Count -gt 1) {
    Write-Host "Select your WoW account folder:"
    for ($i = 0; $i -lt $existing.Count; $i++) {
      Write-Host (" [{0}] {1}" -f ($i + 1), $existing[$i].Name)
    }

    $choice = Read-Host "Enter a number from the list"
    if ($choice -as [int]) {
      $index = [int]$choice - 1
      if ($index -ge 0 -and $index -lt $existing.Count) {
        return $existing[$index].Name
      }
    }
  }

  return (Ask-Value -Prompt "Enter your WoW account folder name (from WTF\Account)")
}

# Generate the installer PowerShell script embedded in the export.
function Build-InstallerScript {
@'
param(
  [string]$WowRetailPath
)

$ErrorActionPreference = "Stop"

# Prompt the user for the WoW _retail_ path.
function Ask-Path {
  param([string]$Prompt)
  $p = Read-Host $Prompt
  if (-not (Test-Path -LiteralPath $p)) { throw "Path not found: $p" }
  return (Resolve-Path -LiteralPath $p).Path
}

# Prompt for a value with optional default.
function Ask-Value {
  param([string]$Prompt, [string]$DefaultValue)
  if ($DefaultValue) {
    $value = Read-Host ("{0} [{1}]" -f $Prompt, $DefaultValue)
    if (-not $value) { return $DefaultValue }
    return $value
  }

  $value = Read-Host $Prompt
  if (-not $value) { throw "$Prompt is required." }
  return $value
}

# Detect account folders and allow the user to pick one.
function Ask-AccountFolder {
  param([string]$AccountRoot)
  $existing = @()
  if (Test-Path -LiteralPath $AccountRoot) {
    $existing = Get-ChildItem -LiteralPath $AccountRoot -Directory
  }

  if ($existing.Count -eq 1) {
    return $existing[0].Name
  }

  if ($existing.Count -gt 1) {
    Write-Host "Select your WoW account folder:" 
    for ($i = 0; $i -lt $existing.Count; $i++) {
      Write-Host (" [{0}] {1}" -f ($i + 1), $existing[$i].Name)
    }

    $choice = Read-Host "Enter a number from the list"
    if ($choice -as [int]) {
      $index = [int]$choice - 1
      if ($index -ge 0 -and $index -lt $existing.Count) {
        return $existing[$index].Name
      }
    }

    Write-Host "Invalid selection."
  }

  $name = Read-Host "Enter your WoW account folder name (from WTF\Account)"
  if (-not $name) { throw "Account folder name is required." }

  $target = Join-Path $AccountRoot $name
  if (-not (Test-Path -LiteralPath $target)) {
    New-Item -ItemType Directory -Path $target | Out-Null
  }

  return $name
}

# Prevent file changes while the game is running.
function Ensure-WowClosed {
  $procs = Get-Process -Name "Wow", "WowClassic", "WowB" -ErrorAction SilentlyContinue
  if ($procs) {
    throw "World of Warcraft appears to be running. Close it and run again."
  }
}

# Resolve or prompt for the WoW installation path.
if (-not $WowRetailPath) {
  Write-Host "Enter your WoW _retail_ folder path."
  Write-Host "Example: C:\Program Files (x86)\World of Warcraft\_retail_"
  $WowRetailPath = Ask-Path "WoW _retail_ path"
} else {
  if (-not (Test-Path -LiteralPath $WowRetailPath)) { throw "Path not found: $WowRetailPath" }
  $WowRetailPath = (Resolve-Path -LiteralPath $WowRetailPath).Path
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# The payload folder is next to the installer.
$payloadRoot = Join-Path $scriptRoot "payload"
if (-not (Test-Path -LiteralPath $payloadRoot)) {
  throw "Missing payload folder next to installer script."
}

Ensure-WowClosed

# Create a backup before replacing Interface/WTF.
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $WowRetailPath "_UIBackup_$timestamp"
New-Item -ItemType Directory -Path $backupDir | Out-Null

$interfacePath = Join-Path $WowRetailPath "Interface"
$wtfPath = Join-Path $WowRetailPath "WTF"

if (Test-Path -LiteralPath $interfacePath) {
  Copy-Item -LiteralPath $interfacePath -Destination (Join-Path $backupDir "Interface") -Recurse -Force
}
if (Test-Path -LiteralPath $wtfPath) {
  Copy-Item -LiteralPath $wtfPath -Destination (Join-Path $backupDir "WTF") -Recurse -Force
}

Write-Host "Backup created: $backupDir"

# Install addons and UI settings.
$payloadInterface = Join-Path $payloadRoot "Interface"
if (Test-Path -LiteralPath $payloadInterface) {
  New-Item -ItemType Directory -Force -Path $interfacePath | Out-Null
  Copy-Item -Path (Join-Path $payloadInterface "*") -Destination $interfacePath -Recurse -Force
}

# Copy WTF content and map account folders.
$payloadWtf = Join-Path $payloadRoot "WTF"
if (Test-Path -LiteralPath $payloadWtf) {
  New-Item -ItemType Directory -Force -Path $wtfPath | Out-Null
  $targetAccountName = $null
  $destAccountPath = $null

  $payloadWtfItems = Get-ChildItem -LiteralPath $payloadWtf
  foreach ($item in $payloadWtfItems) {
    if (($item.Name -ne "Account") -and ($item.Name -ne "CharacterTemplate")) {
      Copy-Item -LiteralPath $item.FullName -Destination $wtfPath -Recurse -Force
    }
  }

  $payloadAccountRoot = Join-Path $payloadWtf "Account"
  if (Test-Path -LiteralPath $payloadAccountRoot) {
    $targetAccountRoot = Join-Path $wtfPath "Account"
    New-Item -ItemType Directory -Force -Path $targetAccountRoot | Out-Null
    $targetAccountName = Ask-AccountFolder -AccountRoot $targetAccountRoot
    $destAccountPath = Join-Path $targetAccountRoot $targetAccountName

    $payloadAccounts = Get-ChildItem -LiteralPath $payloadAccountRoot -Directory
    foreach ($acct in $payloadAccounts) {
      Copy-Item -Path (Join-Path $acct.FullName "*") -Destination $destAccountPath -Recurse -Force
    }
  }

  $payloadCharacterTemplate = Join-Path $payloadWtf "CharacterTemplate"
  if (Test-Path -LiteralPath $payloadCharacterTemplate) {
    $targetAccountRoot = Join-Path $wtfPath "Account"
    New-Item -ItemType Directory -Force -Path $targetAccountRoot | Out-Null
    if (-not $targetAccountName) {
      $targetAccountName = Ask-AccountFolder -AccountRoot $targetAccountRoot
      $destAccountPath = Join-Path $targetAccountRoot $targetAccountName
    }

    $defaultRealm = $null
    $defaultCharacter = $null
    $manifestPath = Join-Path $scriptRoot "manifest.json"
    if (Test-Path -LiteralPath $manifestPath) {
      try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest -and $manifest.characterSource) {
          $parts = ($manifest.characterSource -replace "/", "\").Split("\")
          if ($parts.Count -ge 3) {
            $defaultRealm = $parts[$parts.Count - 2]
            $defaultCharacter = $parts[$parts.Count - 1]
          }
        }
      } catch {
      }
    }

    $targetRealm = Ask-Value -Prompt "Enter target realm folder name" -DefaultValue $defaultRealm
    $targetCharacter = Ask-Value -Prompt "Enter target character folder name" -DefaultValue $defaultCharacter
    $targetCharacterPath = Join-Path $destAccountPath (Join-Path $targetRealm $targetCharacter)
    New-Item -ItemType Directory -Force -Path $targetCharacterPath | Out-Null

    $templateSavedVars = Join-Path $payloadCharacterTemplate "SavedVariables"
    if (Test-Path -LiteralPath $templateSavedVars) {
      $destCharSavedVars = Join-Path $targetCharacterPath "SavedVariables"
      New-Item -ItemType Directory -Force -Path $destCharSavedVars | Out-Null
      Copy-Item -Path (Join-Path $templateSavedVars "*") -Destination $destCharSavedVars -Recurse -Force
    }

    $templateLayout = Join-Path $payloadCharacterTemplate "layout-local.txt"
    if (Test-Path -LiteralPath $templateLayout) {
      Copy-Item -LiteralPath $templateLayout -Destination (Join-Path $targetCharacterPath "layout-local.txt") -Force
    }

    Write-Host ("Character settings installed to: {0}\{1}" -f $targetRealm, $targetCharacter)
  }
}

Write-Host "UI Pack installed successfully."
Write-Host "Start WoW and verify character-specific settings."
'@
}

# Generate a CMD wrapper for one-click install.
function Build-InstallerCmd {
@'
@echo off
setlocal

set "scriptDir=%~dp0"
set "ps1=%scriptDir%Install-UI-Pack.ps1"

if not exist "%ps1%" (
  echo Missing Install-UI-Pack.ps1 next to this file.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ps1%"
endlocal
'@
}

# Generate a minimal README for the exported zip.
function Build-Readme {
@'
1) Close World of Warcraft.
2) Double-click Install-UI-Pack.cmd (or right-click Install-UI-Pack.ps1 > Run with PowerShell).
3) Enter your WoW _retail_ path when asked.
4) Enter your account folder name when prompted (from WTF\Account).
5) If asked, choose the realm/character you want these settings applied to.
6) Launch WoW.
'@
}

# Extract the WoW client version from .build.info.
function Get-WowVersion {
  param([string]$WowRoot)
  $buildInfo = Join-Path $WowRoot ".build.info"
  if (-not (Test-Path -LiteralPath $buildInfo)) {
    return "unknown"
  }

  $content = Get-Content -LiteralPath $buildInfo -Raw
  if (-not $content) { return "unknown" }

  $match = [regex]::Match($content, '\b\d+\.\d+\.\d+\.\d+\b')
  if ($match.Success) {
    return $match.Value
  }

  $fallback = [regex]::Match($content, '\b\d+\.\d+\.\d+\b')
  if ($fallback.Success) {
    return $fallback.Value
  }

  return "unknown"
}

# Export addons and settings into a distributable zip.
function Export-Pack {
  param(
    [string]$WowPath,
    [string]$OutDir,
    [string]$Name,
    [string]$PackVersion,
    [bool]$IncludeLayout,
    [bool]$IncludeCharacterData,
    [string]$CharacterSelection,
    [bool]$UseAnonymizedAccounts,
    [string[]]$AllowList,
    [string[]]$BlockList
  )

  Ensure-WowClosed

  $wowRoot = Resolve-ExistingPath -PathValue $WowPath -Label "WowRetailPath"
  if (-not $OutDir) {
    $OutDir = Join-Path (Get-Location) "dist"
  }
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $outRoot = (Resolve-Path -LiteralPath $OutDir).Path

  if (-not $Name) { $Name = "MyUIPack" }
  if (-not $PackVersion) { $PackVersion = "1.0.0" }

  # Build the payload in a temp folder to avoid partial outputs.
  $temp = New-TempDir
  try {
    $payload = Join-Path $temp "payload"
    $addonsDest = Join-Path $payload "Interface\AddOns"
    $wtfDest = Join-Path $payload "WTF"

    $addonsSource = Join-Path $wowRoot "Interface\AddOns"
    $wtfSource = Join-Path $wowRoot "WTF"

    if (-not (Test-Path -LiteralPath $addonsSource)) {
      throw "AddOns folder not found under: $addonsSource"
    }

    # Filter addons using allow/block lists if provided.
    $addonDirs = Get-ChildItem -LiteralPath $addonsSource -Directory
    $selectedAddons = @()
    foreach ($dir in $addonDirs) {
      if (Should-IncludeAddon -Name $dir.Name -AllowList $AllowList -BlockList $BlockList) {
        $selectedAddons += $dir
      }
    }

    if ($selectedAddons.Count -eq 0) {
      throw "No addons selected for export after applying allow/exclude filters."
    }

    New-Item -ItemType Directory -Force -Path $addonsDest | Out-Null
    foreach ($addonDir in $selectedAddons) {
      Copy-Item -LiteralPath $addonDir.FullName -Destination $addonsDest -Recurse -Force
    }

    $config = Join-Path $wtfSource "Config.wtf"
    if (Test-Path -LiteralPath $config) {
      New-Item -ItemType Directory -Force -Path $wtfDest | Out-Null
      Copy-Item -LiteralPath $config -Destination (Join-Path $wtfDest "Config.wtf") -Force
    }

    # Copy SavedVariables and optional per-character layouts.
    $accountRoot = Join-Path $wtfSource "Account"
    $accountNameMap = @{}
    $selectedCharacter = $null
    if ($IncludeCharacterData) {
      $selectedCharacter = Select-CharacterForExport -AccountRoot $accountRoot -Selection $CharacterSelection
    }

    if (Test-Path -LiteralPath $accountRoot) {
      $accounts = Get-ChildItem -LiteralPath $accountRoot -Directory
      $accountIndex = 1
      foreach ($acct in $accounts) {
        $accountName = $acct.Name
        if ($UseAnonymizedAccounts) {
          $accountName = "ACCOUNT_{0}" -f $accountIndex
          $accountIndex++
        }
        $accountNameMap[$acct.Name] = $accountName

        $srcSv = Join-Path $acct.FullName "SavedVariables"
        if (Test-Path -LiteralPath $srcSv) {
          $dstSv = Join-Path $wtfDest ("Account\{0}\SavedVariables" -f $accountName)
          Copy-Safely -Source $srcSv -Destination $dstSv
        }

        if ($IncludeLayout) {
          $realms = Get-ChildItem -LiteralPath $acct.FullName -Directory | Where-Object { $_.Name -ne "SavedVariables" }
          foreach ($realm in $realms) {
            $chars = Get-ChildItem -LiteralPath $realm.FullName -Directory
            foreach ($charDir in $chars) {
              $layout = Join-Path $charDir.FullName "layout-local.txt"
              if (Test-Path -LiteralPath $layout) {
                $dstChar = Join-Path $wtfDest ("Account\{0}\{1}\{2}" -f $accountName, $realm.Name, $charDir.Name)
                New-Item -ItemType Directory -Force -Path $dstChar | Out-Null
                Copy-Item -LiteralPath $layout -Destination (Join-Path $dstChar "layout-local.txt") -Force
              }
            }
          }
        }
      }
    }

    $hasCharacterTemplate = $false
    $characterSource = $null
    if ($IncludeCharacterData -and $selectedCharacter) {
      $templateRoot = Join-Path $wtfDest "CharacterTemplate"
      $srcCharSavedVars = Join-Path $selectedCharacter.Path "SavedVariables"
      if (Test-Path -LiteralPath $srcCharSavedVars) {
        $dstCharSavedVars = Join-Path $templateRoot "SavedVariables"
        Copy-Safely -Source $srcCharSavedVars -Destination $dstCharSavedVars
        $hasCharacterTemplate = $true
      }

      $srcLayout = Join-Path $selectedCharacter.Path "layout-local.txt"
      if (Test-Path -LiteralPath $srcLayout) {
        New-Item -ItemType Directory -Force -Path $templateRoot | Out-Null
        Copy-Item -LiteralPath $srcLayout -Destination (Join-Path $templateRoot "layout-local.txt") -Force
        $hasCharacterTemplate = $true
      }

      if (-not $hasCharacterTemplate) {
        throw "Selected character has no SavedVariables or layout-local.txt to export."
      }

      $sourceAccount = $selectedCharacter.Account
      if ($UseAnonymizedAccounts -and $accountNameMap.ContainsKey($selectedCharacter.Account)) {
        $sourceAccount = $accountNameMap[$selectedCharacter.Account]
      }
      $characterSource = "{0}\{1}\{2}" -f $sourceAccount, $selectedCharacter.Realm, $selectedCharacter.Character
    }

    $addonNames = @()
    foreach ($dir in $selectedAddons) {
      $addonNames += $dir.Name
    }

    # Emit manifest and installer assets.
    $wowVersion = Get-WowVersion -WowRoot $wowRoot
    Write-Manifest `
      -Path (Join-Path $temp "manifest.json") `
      -Name $Name `
      -PackVersion $PackVersion `
      -WowVersion $wowVersion `
      -Addons $addonNames `
      -HasCharacterTemplate:$hasCharacterTemplate `
      -CharacterSource $characterSource
    Build-InstallerScript | Set-Content -Path (Join-Path $temp "Install-UI-Pack.ps1") -Encoding ASCII
    Build-InstallerCmd | Set-Content -Path (Join-Path $temp "Install-UI-Pack.cmd") -Encoding ASCII
    Build-Readme | Set-Content -Path (Join-Path $temp "README.txt") -Encoding ASCII

    $zipPath = Join-Path $outRoot ("{0}-v{1}.zip" -f $Name, $PackVersion)
    if (Test-Path -LiteralPath $zipPath) {
      Remove-Item -LiteralPath $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $temp "*") -DestinationPath $zipPath -Force
    Write-Host "Export complete: $zipPath"
  }
  finally {
    if (Test-Path -LiteralPath $temp) {
      Remove-Item -LiteralPath $temp -Recurse -Force
    }
  }
}

# Import a pack zip into the target WoW folder.
function Import-Pack {
  param(
    [string]$Archive,
    [string]$WowPath,
    [bool]$SkipBackup,
    [bool]$WhatIfMode,
    [string]$PreferredAccount,
    [string]$PreferredRealm,
    [string]$PreferredCharacter
  )

  Ensure-WowClosed

  $zip = Resolve-ExistingPath -PathValue $Archive -Label "ZipPath"
  $wowRoot = Resolve-ExistingPath -PathValue $WowPath -Label "WowRetailPath"

  # Extract to a temp folder before copying into WoW.
  $temp = New-TempDir
  try {
    Expand-Archive -LiteralPath $zip -DestinationPath $temp -Force
    $payload = Join-Path $temp "payload"
    if (-not (Test-Path -LiteralPath $payload)) {
      throw "Invalid pack: payload folder is missing."
    }

    $manifest = $null
    $manifestPath = Join-Path $temp "manifest.json"
    if (Test-Path -LiteralPath $manifestPath) {
      try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
      } catch {
      }
    }

    $interfacePath = Join-Path $wowRoot "Interface"
    $wtfPath = Join-Path $wowRoot "WTF"
    $payloadInterface = Join-Path $payload "Interface"
    $payloadWtf = Join-Path $payload "WTF"

    if ((-not (Test-Path -LiteralPath $payloadInterface)) -and (-not (Test-Path -LiteralPath $payloadWtf))) {
      throw "Invalid pack: payload must include Interface or WTF content."
    }

    if ($WhatIfMode) {
      Write-Host "Dry run mode: no files will be changed."
      if (Test-Path -LiteralPath $payloadInterface) {
        Write-Host ("Would copy: {0} -> {1}" -f $payloadInterface, $interfacePath)
      }
      if (Test-Path -LiteralPath $payloadWtf) {
        Write-Host ("Would copy: {0} -> {1}" -f $payloadWtf, $wtfPath)
        $payloadCharacterTemplate = Join-Path $payloadWtf "CharacterTemplate"
        if (Test-Path -LiteralPath $payloadCharacterTemplate) {
          Write-Host "Would prompt for target account/realm/character mapping for CharacterTemplate."
        }
      }
      return
    }

    if (-not $SkipBackup) {
      $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
      $backupDir = Join-Path $wowRoot "_UIBackup_$timestamp"
      New-Item -ItemType Directory -Path $backupDir | Out-Null
      if (Test-Path -LiteralPath $interfacePath) {
        Copy-Item -LiteralPath $interfacePath -Destination (Join-Path $backupDir "Interface") -Recurse -Force
      }
      if (Test-Path -LiteralPath $wtfPath) {
        Copy-Item -LiteralPath $wtfPath -Destination (Join-Path $backupDir "WTF") -Recurse -Force
      }
      Write-Host "Backup created: $backupDir"
    }

    if (Test-Path -LiteralPath $payloadInterface) {
      New-Item -ItemType Directory -Force -Path $interfacePath | Out-Null
      Copy-Item -Path (Join-Path $payloadInterface "*") -Destination $interfacePath -Recurse -Force
    }
    if (Test-Path -LiteralPath $payloadWtf) {
      New-Item -ItemType Directory -Force -Path $wtfPath | Out-Null
      $targetAccountName = $null
      $destAccountPath = $null

      $payloadWtfItems = Get-ChildItem -LiteralPath $payloadWtf
      foreach ($item in $payloadWtfItems) {
        if (($item.Name -ne "Account") -and ($item.Name -ne "CharacterTemplate")) {
          Copy-Item -LiteralPath $item.FullName -Destination $wtfPath -Recurse -Force
        }
      }

      $payloadAccountRoot = Join-Path $payloadWtf "Account"
      if (Test-Path -LiteralPath $payloadAccountRoot) {
        $targetAccountRoot = Join-Path $wtfPath "Account"
        New-Item -ItemType Directory -Force -Path $targetAccountRoot | Out-Null
        $targetAccountName = Resolve-TargetAccountName -AccountRoot $targetAccountRoot -PreferredName $PreferredAccount
        $destAccountPath = Join-Path $targetAccountRoot $targetAccountName

        $payloadAccounts = Get-ChildItem -LiteralPath $payloadAccountRoot -Directory
        foreach ($acct in $payloadAccounts) {
          Copy-Item -Path (Join-Path $acct.FullName "*") -Destination $destAccountPath -Recurse -Force
        }
      }

      $payloadCharacterTemplate = Join-Path $payloadWtf "CharacterTemplate"
      if (Test-Path -LiteralPath $payloadCharacterTemplate) {
        $targetAccountRoot = Join-Path $wtfPath "Account"
        New-Item -ItemType Directory -Force -Path $targetAccountRoot | Out-Null
        if (-not $targetAccountName) {
          $targetAccountName = Resolve-TargetAccountName -AccountRoot $targetAccountRoot -PreferredName $PreferredAccount
          $destAccountPath = Join-Path $targetAccountRoot $targetAccountName
        }

        $defaultRealm = $null
        $defaultCharacter = $null
        if ($manifest -and $manifest.characterSource) {
          $parts = ($manifest.characterSource -replace "/", "\").Split("\")
          if ($parts.Count -ge 3) {
            $defaultRealm = $parts[$parts.Count - 2]
            $defaultCharacter = $parts[$parts.Count - 1]
          }
        }

        if (-not $PreferredRealm) {
          $PreferredRealm = Ask-Value -Prompt "Enter target realm folder name" -DefaultValue $defaultRealm
        }
        if (-not $PreferredCharacter) {
          $PreferredCharacter = Ask-Value -Prompt "Enter target character folder name" -DefaultValue $defaultCharacter
        }

        $targetCharacterPath = Join-Path $destAccountPath (Join-Path $PreferredRealm $PreferredCharacter)
        New-Item -ItemType Directory -Force -Path $targetCharacterPath | Out-Null

        $templateSavedVars = Join-Path $payloadCharacterTemplate "SavedVariables"
        if (Test-Path -LiteralPath $templateSavedVars) {
          $destCharSavedVars = Join-Path $targetCharacterPath "SavedVariables"
          New-Item -ItemType Directory -Force -Path $destCharSavedVars | Out-Null
          Copy-Item -Path (Join-Path $templateSavedVars "*") -Destination $destCharSavedVars -Recurse -Force
        }

        $templateLayout = Join-Path $payloadCharacterTemplate "layout-local.txt"
        if (Test-Path -LiteralPath $templateLayout) {
          Copy-Item -LiteralPath $templateLayout -Destination (Join-Path $targetCharacterPath "layout-local.txt") -Force
        }

        Write-Host ("Character settings installed to: {0}\{1}" -f $PreferredRealm, $PreferredCharacter)
      }
    }

    Write-Host "Import complete. Launch WoW and validate settings."
  }
  finally {
    if (Test-Path -LiteralPath $temp) {
      Remove-Item -LiteralPath $temp -Recurse -Force
    }
  }
}

# Dispatch the CLI command.
switch ($Command) {
  "export" {
    Export-Pack `
      -WowPath $WowRetailPath `
      -OutDir $OutputDir `
      -Name $PackName `
      -PackVersion $Version `
      -IncludeLayout:$IncludeAccountLayout `
      -IncludeCharacterData:$IncludeCharacterSettings `
      -CharacterSelection $SourceCharacter `
      -UseAnonymizedAccounts:$AnonymizeAccounts `
      -AllowList $AddonAllowList `
      -BlockList $ExcludeAddons
  }
  "import" {
    Import-Pack `
      -Archive $ZipPath `
      -WowPath $WowRetailPath `
      -SkipBackup:$NoBackup `
      -WhatIfMode:$DryRun `
      -PreferredAccount $TargetAccount `
      -PreferredRealm $TargetRealm `
      -PreferredCharacter $TargetCharacter
  }
}
