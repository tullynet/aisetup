# Windows Development Requirements Installer

This repository contains a Windows PowerShell 5.1-compatible bootstrap script. It downloads stable releases directly from the official GitHub repositories and installs them for the current user.

## Run

Open Windows PowerShell and run:

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/tullynet/aisetup/main/install-requirements.ps1 | Invoke-Expression
```

Use `-Reinstall` to run every installer regardless of the installed version:

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/tullynet/aisetup/main/install-requirements.ps1).Content)) -Reinstall
```

When started from `install-requirements.ps1` under Windows PowerShell 5.1, the script installs a current-user PowerShell 7 ZIP and continues in that process. File-based execution is required for this handoff; fileless `Invoke-WebRequest | Invoke-Expression` execution cannot be restarted automatically.

The command should be run from a normal, non-elevated PowerShell prompt. The script asks whether all packages should be reinstalled, then refreshes the current process environment from the User and Machine environment stores before checking versions, so recently installed commands and PATH entries are available without opening a new terminal. It checks each package's installed version against the latest stable GitHub or PowerShell Gallery release before downloading anything, and skips packages that are already current unless reinstall was selected. Windows Terminal is installed with deferred registration when its current process is using the package, so the update takes effect the next time Terminal starts.

## Installs

- Latest stable PowerShell 7 Windows ZIP from `PowerShell/PowerShell`, extracted to `%LOCALAPPDATA%\Programs\PowerShell\7`
- Latest stable Windows Terminal release from `microsoft/terminal`
- Latest stable Git for Windows x64 portable release from `git-for-windows/git`
- Latest stable Node.js Windows ZIP release from `nodejs/node`
- Latest stable uv Windows release from `astral-sh/uv`
- Latest stable OpenCode Windows release from `anomalyco/opencode`
- Latest stable Herdr Windows x64 release from `herdrdev/herdr`
- `Microsoft.PowerShell.SecretManagement` and `Microsoft.PowerShell.SecretStore` from the PowerShell Gallery nupkg API, extracted to `%LOCALAPPDATA%\PowerShell\Modules`

SecretStore is configured for the current user with no password and no prompts. The installer does not use `Install-Module`, `Install-PackageProvider`, or the NuGet package provider.

When Herdr is installed, the script creates or updates `%APPDATA%\herdr\config.toml` so new interactive panes use the full path of a real `pwsh.exe` (not the WindowsApps execution alias).

The script continues after an individual package failure and prints an installation summary at the end.
