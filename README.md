# wow-ui-profile

Windows tool for creating and installing WoW UI packs.

## Quick Start (GUI)

1. Run `pwsh -File .\Start-UI-Pack-GUI.ps1`.
2. Use **Export Pack** tab to build a zip in `.\dist`.
3. Share that zip with a friend.
4. Your friend extracts the zip and runs `Install-UI-Pack.cmd`.

No app installation is required for your friend.

## What Gets Exported

- `Interface\AddOns`
- `WTF\Config.wtf`
- `WTF\Account\*\SavedVariables`
- Optional character template (`SavedVariables` + `layout-local.txt`) from one selected source character

## Character Mapping Flow

- GUI can auto-detect account/realm/character folders from the selected WoW path (use **Refresh**).
- On export, enable **Include character settings template** and optionally set `SourceCharacter`.
- On install/import, target account/realm/character can be selected or prefilled.
- This lets you export from your character and map to your friend's character.

## Advanced CLI (Optional)

Export:
- `pwsh -File .\app\wow-ui-pack.ps1 export -WowRetailPath "C:\Program Files (x86)\World of Warcraft\_retail_" -OutputDir .\dist -PackName "MyUIPack" -Version "1.0.1" -IncludeCharacterSettings -SourceCharacter "MyRealm\MyCharacter" -AnonymizeAccounts`

Import:
- `pwsh -File .\app\wow-ui-pack.ps1 import -ZipPath .\dist\MyUIPack-v1.0.1.zip -WowRetailPath "C:\Program Files (x86)\World of Warcraft\_retail_" -TargetRealm "FriendRealm" -TargetCharacter "FriendCharacter"`

Share release (GitHub CLI):
- `pwsh -File .\Share-UI-Pack.ps1 -ZipPath .\dist\MyUIPack-v1.0.1.zip -Repo "owner/repo"`

## Build EXE (Windows)

Build a portable GUI executable:
- `pwsh -File .\Build-UI-Pack-Exe.ps1`

Output:
- `dist\portable\WoW-UI-Pack-Manager.exe`

Notes:
- First build installs `ps2exe` in CurrentUser scope (unless `-NoInstall` is used).
- Default output is a single-file EXE with embedded core logic.
- Optional sidecar mode: `pwsh -File .\Build-UI-Pack-Exe.ps1 -IncludeSidecar`

## Notes

- Close WoW before export/import.
- Import creates `_UIBackup_yyyyMMdd-HHmmss` under `_retail_` unless `-NoBackup` is used.
- Optional tools for ongoing addon updates: CurseForge app, Wago companion.

## License

MIT. See `LICENSE`.
