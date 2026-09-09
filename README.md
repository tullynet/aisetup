# Windows Development Requirements Installer

This repository contains a Windows PowerShell 5.1-compatible bootstrap script. It downloads stable releases directly from the official GitHub repositories and installs them for the current user where supported.

## Run

Open Windows PowerShell and run:

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/tullynet/aisetup/main/install-requirements.ps1 | Invoke-Expression
```

The command should be run from a normal, non-elevated PowerShell prompt. PowerShell 7 and Git are installed per user. Windows Terminal is installed with deferred registration when its current process is using the package, so the update takes effect the next time Terminal starts.

## Installs

- Latest stable PowerShell 7 x64 release from `PowerShell/PowerShell`
- Latest stable Windows Terminal release from `microsoft/terminal`
- Latest stable Git for Windows x64 portable release from `git-for-windows/git`

The script continues after an individual package failure and prints an installation summary at the end.
