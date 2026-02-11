$ErrorActionPreference = "Stop"

function Get-SelfPath {
  if ($PSCommandPath) { return $PSCommandPath }
  if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
  return $null
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
  $selfPath = Get-SelfPath
  if ($selfPath -and ($selfPath -like "*.ps1")) {
    $pwshPath = (Get-Process -Id $PID).Path
    $launchArgs = @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-STA",
      "-File",
      $selfPath
    )
    Start-Process -FilePath $pwshPath -ArgumentList $launchArgs | Out-Null
    exit
  }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

function Resolve-ExecutionRoot {
  $candidates = @()

  if ($PSScriptRoot) { $candidates += $PSScriptRoot }

  $selfPath = Get-SelfPath
  if ($selfPath) {
    $parent = Split-Path -Parent $selfPath
    if ($parent) { $candidates += $parent }
  }

  $baseDir = [System.AppDomain]::CurrentDomain.BaseDirectory
  if ($baseDir) { $candidates += $baseDir }

  $cwd = (Get-Location).Path
  if ($cwd) { $candidates += $cwd }

  foreach ($candidate in $candidates) {
    if ($candidate -and -not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate
    }
  }

  throw "Unable to resolve execution root path."
}

function Resolve-CoreScriptPath {
  param([string]$DefaultPath)

  if (Test-Path -LiteralPath $DefaultPath) {
    return (Resolve-Path -LiteralPath $DefaultPath).Path
  }

  if ($script:BundledCoreScriptBase64) {
    $cacheDir = Join-Path ([System.IO.Path]::GetTempPath()) "wow-ui-pack-core"
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
      [System.Text.Encoding]::UTF8.GetBytes($script:BundledCoreScriptBase64)
    )
    $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant().Substring(0, 16)
    $tempCorePath = Join-Path $cacheDir ("wow-ui-pack-{0}.ps1" -f $hash)

    if (-not (Test-Path -LiteralPath $tempCorePath)) {
      $raw = [System.Convert]::FromBase64String($script:BundledCoreScriptBase64)
      $content = [System.Text.Encoding]::UTF8.GetString($raw)
      Set-Content -LiteralPath $tempCorePath -Value $content -Encoding UTF8
    }

    return $tempCorePath
  }

  throw "Missing core CLI script: $DefaultPath"
}
$selfPath = Get-SelfPath
$isExeHost = $false
if ($selfPath -and ($selfPath -like "*.exe")) {
  $isExeHost = $true
}

$executionRoot = Resolve-ExecutionRoot
$coreScript = Resolve-CoreScriptPath -DefaultPath (Join-Path $executionRoot "wow-ui-pack.ps1")

if (Test-Path -LiteralPath (Join-Path $executionRoot "app\wow-ui-pack.ps1")) {
  $repoRoot = $executionRoot
}
elseif ((Split-Path -Leaf $executionRoot) -eq "app") {
  $repoRoot = Split-Path -Parent $executionRoot
}
else {
  $repoRoot = $executionRoot
}

$defaultDist = Join-Path $repoRoot "dist"
if ($isExeHost) {
  $defaultDist = $executionRoot
}
if (-not (Test-Path -LiteralPath $defaultDist)) {
  New-Item -ItemType Directory -Path $defaultDist -Force | Out-Null
}

function Split-List {
  param([string]$Value)
  if (-not $Value) { return @() }
  return @(
    $Value -split "[,;`n`r]" |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ }
  )
}

function Select-FolderPath {
  param([string]$CurrentPath)
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  if ($CurrentPath -and (Test-Path -LiteralPath $CurrentPath)) {
    $dialog.SelectedPath = $CurrentPath
  }
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    return $dialog.SelectedPath
  }
  return $null
}

function Select-ZipFilePath {
  param([string]$CurrentPath)
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Filter = "Zip Files (*.zip)|*.zip|All Files (*.*)|*.*"
  $dialog.Multiselect = $false
  if ($CurrentPath -and (Test-Path -LiteralPath $CurrentPath)) {
    $dialog.InitialDirectory = Split-Path -Parent $CurrentPath
    $dialog.FileName = Split-Path -Leaf $CurrentPath
  }
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    return $dialog.FileName
  }
  return $null
}

function Get-WowProfileData {
  param([string]$WowRetailPath)

  $accounts = [ordered]@{}
  $characters = @()

  if (-not $WowRetailPath) {
    return [pscustomobject]@{ Accounts = $accounts; Characters = $characters }
  }

  $accountRoot = Join-Path $WowRetailPath "WTF\Account"
  if (-not (Test-Path -LiteralPath $accountRoot)) {
    return [pscustomobject]@{ Accounts = $accounts; Characters = $characters }
  }

  $accountDirs = Get-ChildItem -LiteralPath $accountRoot -Directory | Sort-Object Name
  foreach ($accountDir in $accountDirs) {
    $realmMap = [ordered]@{}
    $realmDirs = Get-ChildItem -LiteralPath $accountDir.FullName -Directory |
      Where-Object { $_.Name -ne "SavedVariables" } |
      Sort-Object Name

    foreach ($realmDir in $realmDirs) {
      $charNames = @(
        Get-ChildItem -LiteralPath $realmDir.FullName -Directory |
          Sort-Object Name |
          ForEach-Object { $_.Name }
      )

      if ($charNames.Count -gt 0) {
        $realmMap[$realmDir.Name] = $charNames
        foreach ($charName in $charNames) {
          $characters += ("{0}\{1}\{2}" -f $accountDir.Name, $realmDir.Name, $charName)
        }
      }
    }

    $accounts[$accountDir.Name] = $realmMap
  }

  return [pscustomobject]@{
    Accounts = $accounts
    Characters = $characters
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "WoW UI Pack Manager"
$form.Width = 920
$form.Height = 760
$form.StartPosition = "CenterScreen"

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 10)
$tabs.Size = New-Object System.Drawing.Size(885, 500)

$tabExport = New-Object System.Windows.Forms.TabPage
$tabExport.Text = "Export Pack"
$tabImport = New-Object System.Windows.Forms.TabPage
$tabImport.Text = "Import Pack"

$tabs.TabPages.Add($tabExport)
$tabs.TabPages.Add($tabImport)

function New-Label {
  param(
    [System.Windows.Forms.Control]$Parent,
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$Width = 180
  )
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, 23)
  $Parent.Controls.Add($label)
}

function New-TextBox {
  param(
    [System.Windows.Forms.Control]$Parent,
    [int]$X,
    [int]$Y,
    [int]$Width = 560,
    [string]$InitialText = ""
  )
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Location = New-Object System.Drawing.Point($X, $Y)
  $tb.Size = New-Object System.Drawing.Size($Width, 23)
  $tb.Text = $InitialText
  $Parent.Controls.Add($tb)
  return $tb
}

function New-Button {
  param(
    [System.Windows.Forms.Control]$Parent,
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$Width = 90
  )
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $Text
  $btn.Location = New-Object System.Drawing.Point($X, $Y)
  $btn.Size = New-Object System.Drawing.Size($Width, 26)
  $Parent.Controls.Add($btn)
  return $btn
}

function New-ComboBox {
  param(
    [System.Windows.Forms.Control]$Parent,
    [int]$X,
    [int]$Y,
    [int]$Width = 560,
    [string]$DropDownStyle = "DropDown"
  )
  $cmb = New-Object System.Windows.Forms.ComboBox
  $cmb.Location = New-Object System.Drawing.Point($X, $Y)
  $cmb.Size = New-Object System.Drawing.Size($Width, 23)
  $cmb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::$DropDownStyle
  $Parent.Controls.Add($cmb)
  return $cmb
}

New-Label -Parent $tabExport -Text "WoW _retail_ Path" -X 20 -Y 25
$txtExportWow = New-TextBox -Parent $tabExport -X 200 -Y 22 -Width 460
$btnExportProfiles = New-Button -Parent $tabExport -Text "Refresh" -X 670 -Y 20
$btnExportWow = New-Button -Parent $tabExport -Text "Browse..." -X 770 -Y 20

New-Label -Parent $tabExport -Text "Output Folder" -X 20 -Y 60
$txtExportOut = New-TextBox -Parent $tabExport -X 200 -Y 57 -InitialText $defaultDist
$btnExportOut = New-Button -Parent $tabExport -Text "Browse..." -X 770 -Y 55

New-Label -Parent $tabExport -Text "Pack Name" -X 20 -Y 95
$txtPackName = New-TextBox -Parent $tabExport -X 200 -Y 92 -Width 280 -InitialText "MyUIPack"

New-Label -Parent $tabExport -Text "Version" -X 500 -Y 95 -Width 70
$txtVersion = New-TextBox -Parent $tabExport -X 575 -Y 92 -Width 185 -InitialText "1.0.0"

New-Label -Parent $tabExport -Text "Addon Allow List" -X 20 -Y 130
$txtAllow = New-TextBox -Parent $tabExport -X 200 -Y 127 -Width 560

New-Label -Parent $tabExport -Text "Exclude Addons" -X 20 -Y 165
$txtExclude = New-TextBox -Parent $tabExport -X 200 -Y 162 -Width 560

New-Label -Parent $tabExport -Text "Source Character" -X 20 -Y 200
$cmbSourceCharacter = New-ComboBox -Parent $tabExport -X 200 -Y 197 -Width 560 -DropDownStyle "DropDown"

$lblSourceHint = New-Object System.Windows.Forms.Label
$lblSourceHint.Text = "Optional. Pick from detected list or type Account\Realm\Character"
$lblSourceHint.Location = New-Object System.Drawing.Point(200, 222)
$lblSourceHint.Size = New-Object System.Drawing.Size(560, 20)
$tabExport.Controls.Add($lblSourceHint)

$chkLayout = New-Object System.Windows.Forms.CheckBox
$chkLayout.Text = "Include layout-local.txt"
$chkLayout.Location = New-Object System.Drawing.Point(200, 255)
$chkLayout.Size = New-Object System.Drawing.Size(250, 24)
$tabExport.Controls.Add($chkLayout)

$chkCharacterSettings = New-Object System.Windows.Forms.CheckBox
$chkCharacterSettings.Text = "Include character settings template"
$chkCharacterSettings.Location = New-Object System.Drawing.Point(200, 282)
$chkCharacterSettings.Size = New-Object System.Drawing.Size(280, 24)
$tabExport.Controls.Add($chkCharacterSettings)

$chkAnonymize = New-Object System.Windows.Forms.CheckBox
$chkAnonymize.Text = "Anonymize account folder names"
$chkAnonymize.Location = New-Object System.Drawing.Point(200, 309)
$chkAnonymize.Size = New-Object System.Drawing.Size(280, 24)
$chkAnonymize.Checked = $true
$tabExport.Controls.Add($chkAnonymize)

$btnRunExport = New-Button -Parent $tabExport -Text "Export Pack" -X 200 -Y 355 -Width 130

$lblExportNote = New-Object System.Windows.Forms.Label
$lblExportNote.Text = "Friends install by extracting zip and running Install-UI-Pack.cmd"
$lblExportNote.Location = New-Object System.Drawing.Point(200, 392)
$lblExportNote.Size = New-Object System.Drawing.Size(520, 24)
$tabExport.Controls.Add($lblExportNote)

New-Label -Parent $tabImport -Text "Pack Zip Path" -X 20 -Y 25
$txtImportZip = New-TextBox -Parent $tabImport -X 200 -Y 22
$btnImportZip = New-Button -Parent $tabImport -Text "Browse..." -X 770 -Y 20

New-Label -Parent $tabImport -Text "WoW _retail_ Path" -X 20 -Y 60
$txtImportWow = New-TextBox -Parent $tabImport -X 200 -Y 57 -Width 460
$btnImportProfiles = New-Button -Parent $tabImport -Text "Refresh" -X 670 -Y 55
$btnImportWow = New-Button -Parent $tabImport -Text "Browse..." -X 770 -Y 55

New-Label -Parent $tabImport -Text "Target Account" -X 20 -Y 95
$cmbTargetAccount = New-ComboBox -Parent $tabImport -X 200 -Y 92 -Width 560 -DropDownStyle "DropDown"

New-Label -Parent $tabImport -Text "Target Realm" -X 20 -Y 130
$cmbTargetRealm = New-ComboBox -Parent $tabImport -X 200 -Y 127 -Width 560 -DropDownStyle "DropDown"

New-Label -Parent $tabImport -Text "Target Character" -X 20 -Y 165
$cmbTargetCharacter = New-ComboBox -Parent $tabImport -X 200 -Y 162 -Width 560 -DropDownStyle "DropDown"

$lblImportHint = New-Object System.Windows.Forms.Label
$lblImportHint.Text = "Target fields are optional. Leave blank to be prompted during import."
$lblImportHint.Location = New-Object System.Drawing.Point(200, 187)
$lblImportHint.Size = New-Object System.Drawing.Size(560, 20)
$tabImport.Controls.Add($lblImportHint)

$chkNoBackup = New-Object System.Windows.Forms.CheckBox
$chkNoBackup.Text = "Skip backup"
$chkNoBackup.Location = New-Object System.Drawing.Point(200, 220)
$chkNoBackup.Size = New-Object System.Drawing.Size(130, 24)
$tabImport.Controls.Add($chkNoBackup)

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "Dry run (no file changes)"
$chkDryRun.Location = New-Object System.Drawing.Point(340, 220)
$chkDryRun.Size = New-Object System.Drawing.Size(190, 24)
$tabImport.Controls.Add($chkDryRun)

$btnRunImport = New-Button -Parent $tabImport -Text "Import Pack" -X 200 -Y 265 -Width 130

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(10, 520)
$logBox.Size = New-Object System.Drawing.Size(885, 190)
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)

$btnClearLog = New-Button -Parent $form -Text "Clear Log" -X 715 -Y 486 -Width 85
$btnOpenDist = New-Button -Parent $form -Text "Open dist" -X 810 -Y 486 -Width 85

$form.Controls.Add($tabs)
$form.Controls.Add($logBox)

function Write-Log {
  param(
    [string]$Message,
    [switch]$IsError
  )
  $logBox.SelectionStart = $logBox.TextLength
  $logBox.SelectionLength = 0
  if ($IsError) {
    $logBox.SelectionColor = [System.Drawing.Color]::DarkRed
  } else {
    $logBox.SelectionColor = [System.Drawing.Color]::Black
  }
  $stamp = Get-Date -Format "HH:mm:ss"
  $logBox.AppendText(("[{0}] {1}`r`n" -f $stamp, $Message))
  $logBox.SelectionColor = [System.Drawing.Color]::Black
  $logBox.ScrollToCaret()
}

$script:ExportProfileData = [pscustomobject]@{ Accounts = [ordered]@{}; Characters = @() }
$script:ImportProfileData = [pscustomobject]@{ Accounts = [ordered]@{}; Characters = @() }

function Set-ComboItems {
  param(
    [System.Windows.Forms.ComboBox]$Combo,
    [string[]]$Items,
    [string]$KeepText,
    [switch]$AutoSelectFirst
  )

  $Combo.BeginUpdate()
  $Combo.Items.Clear()
  foreach ($item in $Items) {
    [void]$Combo.Items.Add($item)
  }
  $Combo.EndUpdate()

  if ($KeepText -and ($Items -contains $KeepText)) {
    $Combo.Text = $KeepText
    return
  }

  if ($KeepText -and -not ($Items -contains $KeepText)) {
    $Combo.Text = $KeepText
    return
  }

  if ($AutoSelectFirst -and $Combo.Items.Count -gt 0) {
    $Combo.SelectedIndex = 0
    return
  }

  if ($Combo.Items.Count -eq 0) {
    $Combo.Text = ""
  }
}

function Refresh-ExportProfiles {
  $path = $txtExportWow.Text
  $previous = $cmbSourceCharacter.Text
  $script:ExportProfileData = Get-WowProfileData -WowRetailPath $path
  $chars = @($script:ExportProfileData.Characters | Sort-Object)
  Set-ComboItems -Combo $cmbSourceCharacter -Items $chars -KeepText $previous
  Write-Log ("Detected {0} source character path(s) for export." -f $chars.Count)
}

function Update-ImportRealmList {
  $selectedAccount = $cmbTargetAccount.Text
  $previousRealm = $cmbTargetRealm.Text
  $realms = @()

  if ($selectedAccount -and $script:ImportProfileData.Accounts.Contains($selectedAccount)) {
    $realms = @($script:ImportProfileData.Accounts[$selectedAccount].Keys | Sort-Object)
  }

  Set-ComboItems -Combo $cmbTargetRealm -Items $realms -KeepText $previousRealm -AutoSelectFirst
  Update-ImportCharacterList
}

function Update-ImportCharacterList {
  $selectedAccount = $cmbTargetAccount.Text
  $selectedRealm = $cmbTargetRealm.Text
  $previousCharacter = $cmbTargetCharacter.Text
  $characters = @()

  if ($selectedAccount -and $selectedRealm -and $script:ImportProfileData.Accounts.Contains($selectedAccount)) {
    $realmMap = $script:ImportProfileData.Accounts[$selectedAccount]
    if ($realmMap.Contains($selectedRealm)) {
      $characters = @($realmMap[$selectedRealm] | Sort-Object)
    }
  }

  Set-ComboItems -Combo $cmbTargetCharacter -Items $characters -KeepText $previousCharacter -AutoSelectFirst
}

function Refresh-ImportProfiles {
  $path = $txtImportWow.Text
  $previousAccount = $cmbTargetAccount.Text
  $script:ImportProfileData = Get-WowProfileData -WowRetailPath $path
  $accounts = @($script:ImportProfileData.Accounts.Keys | Sort-Object)
  Set-ComboItems -Combo $cmbTargetAccount -Items $accounts -KeepText $previousAccount -AutoSelectFirst
  Update-ImportRealmList
  Write-Log ("Detected {0} account folder(s) for import target." -f $accounts.Count)
}

function Invoke-Core {
  param(
    [ValidateSet("export", "import")]
    [string]$CoreCommand,
    [hashtable]$NamedArgs
  )

  $form.UseWaitCursor = $true
  try {
    $logParts = @("-Command", $CoreCommand)
    if ($NamedArgs) {
      foreach ($k in $NamedArgs.Keys) {
        $v = $NamedArgs[$k]
        if ($v -is [System.Array]) {
          $logParts += ("-{0} {1}" -f $k, ($v -join ","))
        }
        else {
          $logParts += ("-{0} {1}" -f $k, $v)
        }
      }
    }

    Write-Log ("wow-ui-pack.ps1 {0}" -f ($logParts -join " "))
    $result = & $coreScript -Command $CoreCommand @NamedArgs 2>&1
    foreach ($line in $result) {
      if ($line) {
        Write-Log ([string]$line)
      }
    }
    Write-Log "Command completed."
  }
  catch {
    Write-Log $_.Exception.Message -IsError
    [System.Windows.Forms.MessageBox]::Show(
      $_.Exception.Message,
      "WoW UI Pack Manager",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  }
  finally {
    $form.UseWaitCursor = $false
  }
}

$btnExportWow.Add_Click({
    $picked = Select-FolderPath -CurrentPath $txtExportWow.Text
    if ($picked) {
      $txtExportWow.Text = $picked
      Refresh-ExportProfiles
    }
  })

$btnExportOut.Add_Click({
    $picked = Select-FolderPath -CurrentPath $txtExportOut.Text
    if ($picked) { $txtExportOut.Text = $picked }
  })

$btnImportZip.Add_Click({
    $picked = Select-ZipFilePath -CurrentPath $txtImportZip.Text
    if ($picked) { $txtImportZip.Text = $picked }
  })

$btnImportWow.Add_Click({
    $picked = Select-FolderPath -CurrentPath $txtImportWow.Text
    if ($picked) {
      $txtImportWow.Text = $picked
      Refresh-ImportProfiles
    }
  })

$btnExportProfiles.Add_Click({
    Refresh-ExportProfiles
  })

$btnImportProfiles.Add_Click({
    Refresh-ImportProfiles
  })

$cmbTargetAccount.Add_SelectedIndexChanged({
    Update-ImportRealmList
  })

$cmbTargetRealm.Add_SelectedIndexChanged({
    Update-ImportCharacterList
  })

$btnRunExport.Add_Click({
    if (-not $txtExportWow.Text) {
      [System.Windows.Forms.MessageBox]::Show("WoW _retail_ path is required for export.") | Out-Null
      return
    }
    if (-not $txtExportOut.Text) {
      [System.Windows.Forms.MessageBox]::Show("Output folder is required for export.") | Out-Null
      return
    }

    $commandArgs = [ordered]@{
      WowRetailPath = $txtExportWow.Text
      OutputDir = $txtExportOut.Text
      PackName = $txtPackName.Text
      Version = $txtVersion.Text
    }

    $allow = Split-List -Value $txtAllow.Text
    if ($allow.Count -gt 0) {
      $commandArgs["AddonAllowList"] = $allow
    }

    $exclude = Split-List -Value $txtExclude.Text
    if ($exclude.Count -gt 0) {
      $commandArgs["ExcludeAddons"] = $exclude
    }

    if ($chkLayout.Checked) {
      $commandArgs["IncludeAccountLayout"] = $true
    }

    if ($chkCharacterSettings.Checked) {
      $commandArgs["IncludeCharacterSettings"] = $true
      if ($cmbSourceCharacter.Text) {
        $commandArgs["SourceCharacter"] = $cmbSourceCharacter.Text
      }
    }

    if ($chkAnonymize.Checked) {
      $commandArgs["AnonymizeAccounts"] = $true
    }

    Invoke-Core -CoreCommand "export" -NamedArgs $commandArgs
  })

$btnRunImport.Add_Click({
    if (-not $txtImportZip.Text) {
      [System.Windows.Forms.MessageBox]::Show("Pack zip path is required for import.") | Out-Null
      return
    }
    if (-not $txtImportWow.Text) {
      [System.Windows.Forms.MessageBox]::Show("WoW _retail_ path is required for import.") | Out-Null
      return
    }

    $commandArgs = [ordered]@{
      ZipPath = $txtImportZip.Text
      WowRetailPath = $txtImportWow.Text
    }

    if ($cmbTargetAccount.Text) {
      $commandArgs["TargetAccount"] = $cmbTargetAccount.Text
    }
    if ($cmbTargetRealm.Text) {
      $commandArgs["TargetRealm"] = $cmbTargetRealm.Text
    }
    if ($cmbTargetCharacter.Text) {
      $commandArgs["TargetCharacter"] = $cmbTargetCharacter.Text
    }
    if ($chkNoBackup.Checked) {
      $commandArgs["NoBackup"] = $true
    }
    if ($chkDryRun.Checked) {
      $commandArgs["DryRun"] = $true
    }

    Invoke-Core -CoreCommand "import" -NamedArgs $commandArgs
  })

$btnClearLog.Add_Click({
    $logBox.Clear()
  })

$btnOpenDist.Add_Click({
    if (-not (Test-Path -LiteralPath $defaultDist)) {
      New-Item -ItemType Directory -Path $defaultDist -Force | Out-Null
    }
    Invoke-Item -LiteralPath $defaultDist
  })

$defaultWowPath = "C:\Program Files (x86)\World of Warcraft\_retail_"
if (Test-Path -LiteralPath $defaultWowPath) {
  $txtExportWow.Text = $defaultWowPath
  $txtImportWow.Text = $defaultWowPath
  Refresh-ExportProfiles
  Refresh-ImportProfiles
}

Write-Log "Ready. Close WoW before export/import."
Write-Log "Tip: Friends can install from zip by running Install-UI-Pack.cmd."

[void]$form.ShowDialog()
