param()

$ErrorActionPreference = "Stop"

$guiScript = Join-Path $PSScriptRoot "app\wow-ui-pack-gui.ps1"
if (-not (Test-Path -LiteralPath $guiScript)) {
  throw "Missing app\wow-ui-pack-gui.ps1"
}

& $guiScript
