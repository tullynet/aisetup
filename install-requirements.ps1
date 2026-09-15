# This file is intended to be hosted at a trusted HTTPS URL and invoked with:
#   Invoke-WebRequest -UseBasicParsing <URL> | Invoke-Expression
# It intentionally uses only commands available in Windows PowerShell 5.1.
param(
    [switch]$Reinstall,
    [switch]$SkipReinstallPrompt
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DownloadDirectory = Join-Path $env:TEMP 'aisetup-downloads'
$InstallerUrl = 'https://raw.githubusercontent.com/tullynet/aisetup/main/install-requirements.ps1'

function Update-ProcessEnvironment {
    $userEnvironment = [Environment]::GetEnvironmentVariables('User')
    $machineEnvironment = [Environment]::GetEnvironmentVariables('Machine')

    foreach ($entry in $machineEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    foreach ($entry in $userEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$userPath;$machinePath"
}

function Set-PreferredToolPathEntries {
    $preferredEntries = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell\7'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Node.js'),
        (Join-Path $env:LOCALAPPDATA 'Programs\uv'),
        (Join-Path $env:LOCALAPPDATA 'Programs\OpenCode'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Herdr')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
        Where-Object { $_ }
    $normalizedPreferredEntries = $preferredEntries | ForEach-Object { ($_ -replace '/', '\').TrimEnd('\') }
    $remainingEntries = foreach ($entry in $userPath) {
        $normalizedEntry = ($entry -replace '/', '\').TrimEnd('\')
        if ($normalizedPreferredEntries -notcontains $normalizedEntry) {
            $entry
        }
    }
    $orderedEntries = @($preferredEntries) + @($remainingEntries)
    [Environment]::SetEnvironmentVariable('Path', ($orderedEntries -join ';'), 'User')
}

Update-ProcessEnvironment
Set-PreferredToolPathEntries
Update-ProcessEnvironment

if (-not $Reinstall -and -not $SkipReinstallPrompt) {
    $reinstallAnswer = Read-Host 'Reinstall all packages, even if already current? [y/N]'
    if ($reinstallAnswer -match '^(y|yes)$') {
        $Reinstall = $true
    }
}

$repositories = @{
    PowerShell = 'PowerShell/PowerShell'
    Terminal   = 'microsoft/terminal'
    Git        = 'git-for-windows/git'
    Node       = 'nodejs/node'
    Uv         = 'astral-sh/uv'
    OpenCode   = 'anomalyco/opencode'
    Herdr      = 'herdrdev/herdr'
}

function Get-LatestStableRelease {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $headers = @{
        Accept                 = 'application/vnd.github+json'
        'User-Agent'           = 'WindowsPowerShell-requirements-installer'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = "https://api.github.com/repos/$Repository/releases/latest"
    $release = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing

    if ($release.draft -or $release.prerelease) {
        throw "GitHub returned a non-stable release for ${Repository}: $($release.tag_name)"
    }
    return $release
}

function ConvertTo-NormalizedVersion {
    param([AllowNull()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $numbers = [regex]::Matches($Version, '\d+') | ForEach-Object { [int]$_.Value }
    if ($numbers.Count -eq 0) {
        return $null
    }

    $parts = @(0, 0, 0, 0)
    for ($index = 0; $index -lt [Math]::Min($numbers.Count, 4); $index++) {
        $parts[$index] = $numbers[$index]
    }
    return [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Get-AppxInstalledVersion {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    $package = Get-AppxPackage -Name $PackageName | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $package) {
        return $null
    }
    return $package.Version.ToString()
}

function Get-CommandInstalledVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$Arguments
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }

    $output = & $command.Source $Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return [string]$output
}

function Get-ExecutableInstalledVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Arguments
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $output = & $Path $Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return [string]$output
}

function Get-InstalledVersion {
    param([Parameter(Mandatory = $true)][string]$Name)

    switch ($Name) {
        'PowerShell' { return Get-AppxInstalledVersion -PackageName 'Microsoft.PowerShell' }
        'Windows Terminal' { return Get-AppxInstalledVersion -PackageName 'Microsoft.WindowsTerminal' }
        'Git' {
            $output = Get-CommandInstalledVersion -CommandName 'git.exe' -Arguments '--version'
            return $output -replace '^git version\s+', ''
        }
        'Node.js' {
            $output = Get-ExecutableInstalledVersion -Path (Join-Path $env:LOCALAPPDATA 'Programs\Node.js\node.exe') -Arguments '--version'
            if ($null -eq $output) { $output = Get-CommandInstalledVersion -CommandName 'node.exe' -Arguments '--version' }
            return $output -replace '^v', ''
        }
        'uv' {
            $output = Get-ExecutableInstalledVersion -Path (Join-Path $env:LOCALAPPDATA 'Programs\uv\uv.exe') -Arguments '--version'
            return $output -replace '^uv\s+', ''
        }
        'OpenCode' {
            $output = Get-ExecutableInstalledVersion -Path (Join-Path $env:LOCALAPPDATA 'Programs\OpenCode\opencode.exe') -Arguments '--version'
            if ($null -eq $output) { $output = Get-CommandInstalledVersion -CommandName 'opencode.exe' -Arguments '--version' }
            if ($null -eq $output) { return $null }
            return $output.Trim()
        }
        'Herdr' {
            $output = Get-ExecutableInstalledVersion -Path (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\herdr.exe') -Arguments '--version'
            if ($null -eq $output) { return $null }
            return $output.Trim()
        }
        'NuGet provider' {
            $provider = Get-PackageProvider -Name 'NuGet' -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
            if ($null -eq $provider) { return $null }
            return $provider.Version.ToString()
        }
        'Microsoft.PowerShell.SecretManagement' {
            $module = Get-Module -ListAvailable -Name 'Microsoft.PowerShell.SecretManagement' -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
            if ($null -eq $module) { return $null }
            return $module.Version.ToString()
        }
    }
    return $null
}

function Get-LatestPowerShellModuleRelease {
    param([Parameter(Mandatory = $true)][string]$Name)

    $pwsh = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) {
        $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { throw 'PowerShell 7 is required to query the PowerShell Gallery.' }
        $pwsh = $command.Source
    }
    $version = & $pwsh -NoProfile -NonInteractive -Command "(Find-Module -Name '$Name' -Repository PSGallery -ErrorAction Stop).Version.ToString()" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$version)) {
        throw "Could not query the PowerShell Gallery for $Name using PowerShell 7."
    }
    return [pscustomobject]@{ tag_name = ([string]$version).Trim(); draft = $false; prerelease = $false }
}

function Install-NuGetProvider {
    $provider = Get-PackageProvider -Name 'NuGet' -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $provider) {
        Install-PackageProvider -Name 'NuGet' -Scope CurrentUser -Force -Confirm:$false
    }
}

function Install-SecretManagement {
    $pwsh = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) {
        $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { throw 'PowerShell 7 is required to install Microsoft.PowerShell.SecretManagement.' }
        $pwsh = $command.Source
    }
    & $pwsh -NoProfile -NonInteractive -Command "Install-Module -Name 'Microsoft.PowerShell.SecretManagement' -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -Confirm:`$false"
    if ($LASTEXITCODE -ne 0) {
        throw "Microsoft.PowerShell.SecretManagement installation failed with exit code $LASTEXITCODE."
    }
}

function Test-PackageNeedsInstallation {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)]$Release
    )

    $installedVersion = Get-InstalledVersion -Name $Package.Name
    $latestVersion = ConvertTo-NormalizedVersion -Version $Release.tag_name
    $normalizedInstalledVersion = ConvertTo-NormalizedVersion -Version $installedVersion
    $Package.InstalledVersion = $installedVersion
    $Package.LatestVersion = $Release.tag_name

    if ($Reinstall -or $null -eq $normalizedInstalledVersion) {
        $Package.NeedsInstall = $true
        return
    }

    $Package.NeedsInstall = $normalizedInstalledVersion -lt $latestVersion
}

function Save-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$AssetPattern,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $asset = @($Release.assets | Where-Object { $_.name -like $AssetPattern }) | Select-Object -First 1
    if ($null -eq $asset) {
        throw "Could not find an asset matching '$AssetPattern' in release $($Release.tag_name)."
    }

    $target = Join-Path $Destination $asset.name
    Write-Host "Downloading $($asset.name) from $($Release.html_url)"
    $webClient = New-Object Net.WebClient
    $webClient.Headers['User-Agent'] = 'WindowsPowerShell-requirements-installer'
    try {
        $webClient.DownloadFile($asset.browser_download_url, $target)
    }
    finally {
        $webClient.Dispose()
    }

    # GitHub exposes a SHA-256 digest on newer API responses. Verify it when present.
    if ($asset.digest -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected = $Matches[1].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 verification failed for $($asset.name)."
        }
        Write-Host "Verified SHA-256 for $($asset.name)"
    }

    return $target
}

function Save-ReleaseAssetByName {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $asset = @($Release.assets | Where-Object { $_.name -ceq $AssetName }) | Select-Object -First 1
    if ($null -eq $asset) {
        throw "Could not find the asset '$AssetName' in release $($Release.tag_name)."
    }

    $target = Join-Path $Destination $asset.name
    Write-Host "Downloading $($asset.name) from $($Release.html_url)"
    $webClient = New-Object Net.WebClient
    $webClient.Headers['User-Agent'] = 'WindowsPowerShell-requirements-installer'
    try {
        $webClient.DownloadFile($asset.browser_download_url, $target)
    }
    finally {
        $webClient.Dispose()
    }

    if ($asset.digest -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected = $Matches[1].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA-256 verification failed for $($asset.name)."
        }
        Write-Host "Verified SHA-256 for $($asset.name)"
    }

    return $target
}

function Install-PowerShell {
    param([Parameter(Mandatory = $true)]$Release)

    $release = $Release
    $version = $release.tag_name -replace '^v', ''
    $bundleName = "PowerShell-$version.msixbundle"
    $bundle = Save-ReleaseAssetByName -Release $release -AssetName $bundleName -Destination $DownloadDirectory

    Write-Host "Installing PowerShell $($release.tag_name) for the current user"
    Add-AppxPackage -Path $bundle -DeferRegistrationWhenPackagesAreInUse
    Write-Host 'PowerShell 7 was installed.' -ForegroundColor Green
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Start-InstallerInPowerShell7
    }
}

function Start-InstallerInPowerShell7 {
    $pwsh = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) {
        throw 'PowerShell 7 was installed, but pwsh.exe could not be found.'
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path $env:TEMP ('aisetup-continue-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Write-Host 'Downloading a temporary copy to continue under PowerShell 7.' -ForegroundColor Cyan
        $scriptContent = (Invoke-WebRequest -UseBasicParsing $InstallerUrl).Content
        [IO.File]::WriteAllText($scriptPath, $scriptContent, [Text.Encoding]::UTF8)
    }
    if ($scriptPath) {
        $arguments += @('-File', $scriptPath)
    }
    if ($Reinstall) {
        $arguments += '-Reinstall'
    }
    else {
        $arguments += '-SkipReinstallPrompt'
    }

    Write-Host 'Restarting the installer under PowerShell 7.' -ForegroundColor Cyan
    & $pwsh @arguments
    exit $LASTEXITCODE
}

function Ensure-PowerShell7Execution {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return
    }

    Write-Host 'PowerShell 5.x detected. Installing or switching to PowerShell 7 before package management.' -ForegroundColor Yellow
    $release = Get-LatestStableRelease -Repository $repositories.PowerShell
    $installedVersion = Get-AppxInstalledVersion -PackageName 'Microsoft.PowerShell'
    $needsInstall = $Reinstall -or $null -eq (ConvertTo-NormalizedVersion -Version $installedVersion) -or
        (ConvertTo-NormalizedVersion -Version $installedVersion) -lt (ConvertTo-NormalizedVersion -Version $release.tag_name)

    if ($needsInstall) {
        Install-PowerShell -Release $release
    }
    else {
        Start-InstallerInPowerShell7
    }
}

function Install-WindowsTerminal {
    param([Parameter(Mandatory = $true)]$Release)

    $release = $Release
    $installer = Save-ReleaseAsset -Release $release -AssetPattern 'Microsoft.WindowsTerminal_*.msixbundle' -Destination $DownloadDirectory

    Write-Host "Installing Windows Terminal $($release.tag_name)"
    Add-AppxPackage -Path $installer -DeferRegistrationWhenPackagesAreInUse
}

function Install-Git {
    param([Parameter(Mandatory = $true)]$Release)

    $release = $Release
    $archive = Save-ReleaseAsset -Release $release -AssetPattern 'PortableGit-*-64-bit.7z.exe' -Destination $DownloadDirectory
    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Git'
    $gitBinDirectory = Join-Path $installDirectory 'cmd'

    Write-Host "Installing Git $($release.tag_name) for the current user"
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    $process = Start-Process -FilePath $archive -ArgumentList @("-o$installDirectory", '-y', '-bd') -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Git extraction failed with exit code $($process.ExitCode)."
    }

    $pathEntries = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ }
    if ($pathEntries -notcontains $gitBinDirectory) {
        $pathEntries += $gitBinDirectory
        [Environment]::SetEnvironmentVariable('Path', ($pathEntries -join ';'), 'User')
    }
    $env:Path = "$gitBinDirectory;$env:Path"
}

function Install-Node {
    param([Parameter(Mandatory = $true)]$Release)

    $release = $Release
    $architecture = if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        'arm64'
    }
    elseif ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -or $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
        'x64'
    }
    else {
        throw 'Node.js installation requires x64 or ARM64 Windows.'
    }
    $version = $release.tag_name -replace '^v', ''
    $archiveName = "node-v{0}-win-{1}.zip" -f $version, $architecture
    $archive = Join-Path $DownloadDirectory $archiveName
    $archiveUri = "https://nodejs.org/dist/v$version/$archiveName"

    Write-Host "Downloading $archiveName from $archiveUri"
    $webClient = New-Object Net.WebClient
    $webClient.Headers['User-Agent'] = 'WindowsPowerShell-requirements-installer'
    try {
        $webClient.DownloadFile($archiveUri, $archive)
    }
    finally {
        $webClient.Dispose()
    }

    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Node.js'
    $extractDirectory = Join-Path $DownloadDirectory "node-extract-$version"
    if (Test-Path -LiteralPath $extractDirectory) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory -Force
    $extractedRoot = Join-Path $extractDirectory ("node-v{0}-win-{1}" -f $version, $architecture)
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    Copy-Item -Path (Join-Path $extractedRoot '*') -Destination $installDirectory -Recurse -Force

    $pathEntries = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ }
    if ($pathEntries -notcontains $installDirectory) {
        $pathEntries += $installDirectory
        [Environment]::SetEnvironmentVariable('Path', ($pathEntries -join ';'), 'User')
    }
}

function Add-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$PathEntry)

    $normalizedEntry = ($PathEntry -replace '/', '\').TrimEnd('\')
    $pathEntries = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
        Where-Object {
            $candidate = ($_ -replace '/', '\').TrimEnd('\')
            $_ -and $candidate -ine $normalizedEntry
        }
    $newPathEntries = @($PathEntry) + @($pathEntries)
    [Environment]::SetEnvironmentVariable('Path', ($newPathEntries -join ';'), 'User')
    Update-ProcessEnvironment
}

function Install-Uv {
    param([Parameter(Mandatory = $true)]$Release)

    $architecture = if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        'aarch64'
    }
    elseif ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -or $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
        'x86_64'
    }
    else {
        throw 'uv installation requires x64 or ARM64 Windows.'
    }
    $archive = Save-ReleaseAsset -Release $Release -AssetPattern ("uv-{0}-pc-windows-msvc.zip" -f $architecture) -Destination $DownloadDirectory
    $extractDirectory = Join-Path $DownloadDirectory 'uv-extract'
    if (Test-Path -LiteralPath $extractDirectory) { Remove-Item -LiteralPath $extractDirectory -Recurse -Force }
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory -Force
    $binary = Get-ChildItem -LiteralPath $extractDirectory -Filter 'uv.exe' -Recurse | Select-Object -First 1
    if ($null -eq $binary) { throw 'uv.exe was not found in the downloaded archive.' }
    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\uv'
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $installDirectory 'uv.exe') -Force
    Add-UserPathEntry -PathEntry $installDirectory
}

function Install-OpenCode {
    param([Parameter(Mandatory = $true)]$Release)

    $architecture = if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $archive = Save-ReleaseAsset -Release $Release -AssetPattern ("opencode-windows-{0}.zip" -f $architecture) -Destination $DownloadDirectory
    $extractDirectory = Join-Path $DownloadDirectory 'opencode-extract'
    if (Test-Path -LiteralPath $extractDirectory) { Remove-Item -LiteralPath $extractDirectory -Recurse -Force }
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory -Force
    $binary = Get-ChildItem -LiteralPath $extractDirectory -Filter 'opencode.exe' -Recurse | Select-Object -First 1
    if ($null -eq $binary) { throw 'opencode.exe was not found in the downloaded archive.' }
    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\OpenCode'
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $installDirectory 'opencode.exe') -Force
    Add-UserPathEntry -PathEntry $installDirectory
}

function Install-Herdr {
    param([Parameter(Mandatory = $true)]$Release)

    $archive = Save-ReleaseAsset -Release $Release -AssetPattern 'herdr-windows-x86_64.zip' -Destination $DownloadDirectory
    $extractDirectory = Join-Path $DownloadDirectory 'herdr-extract'
    if (Test-Path -LiteralPath $extractDirectory) { Remove-Item -LiteralPath $extractDirectory -Recurse -Force }
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDirectory -Force
    $binary = Get-ChildItem -LiteralPath $extractDirectory -Filter 'herdr.exe' -Recurse | Select-Object -First 1
    if ($null -eq $binary) { throw 'herdr.exe was not found in the downloaded archive.' }
    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Herdr'
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $installDirectory 'herdr.exe') -Force
    Add-UserPathEntry -PathEntry $installDirectory
    Set-HerdrDefaultShell
}

function Stop-RunningHerdr {
    $herdr = Get-Command herdr.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $herdr) {
        return
    }

    Write-Host 'Stopping running Herdr processes before reinstall.' -ForegroundColor Yellow
    & $herdr.Source server stop 2>$null | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $running = @(Get-Process -Name 'herdr' -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) {
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw 'Herdr server did not stop within 10 seconds.'
}

function Set-HerdrDefaultShell {
    $configDirectory = Join-Path $env:APPDATA 'herdr'
    $configPath = Join-Path $configDirectory 'config.toml'
    $terminalConfig = @'
[terminal]
# Executable used for new interactive panes.
# Empty means $SHELL, then /bin/sh.
default_shell = "pwsh.exe"
'@

    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $configPath)) {
        Set-Content -LiteralPath $configPath -Value $terminalConfig -Encoding UTF8
        return
    }

    $config = Get-Content -LiteralPath $configPath -Raw
    if ($config -match '(?m)^\s*default_shell\s*=') {
        $config = [regex]::Replace($config, '(?m)^\s*default_shell\s*=.*$', 'default_shell = "pwsh.exe"')
    }
    elseif ($config -match '(?m)^\[terminal\]\s*$') {
        $config = [regex]::Replace(
            $config,
            '(?ms)(^\[terminal\]\s*\r?\n)(.*?)(?=^\[|\z)',
            ('$1$2' + "# Executable used for new interactive panes.`r`n# Empty means `$SHELL, then /bin/sh.`r`ndefault_shell = `"pwsh.exe`"`r`n")
        )
    }
    else {
        $config = $config.TrimEnd() + "`r`n`r`n" + $terminalConfig
    }
    Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8
}

function Invoke-PackageInstallation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Installer,
        [Parameter()][object[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][int]$Total
    )

    Write-Host "`n[$Number/$Total] $Name" -ForegroundColor Cyan
    Write-Host ('-' * ($Name.Length + 8)) -ForegroundColor DarkGray
    $timer = [Diagnostics.Stopwatch]::StartNew()

    try {
        & $Installer @ArgumentList
        $timer.Stop()
        Write-Host ('[OK]   Installed in {0:N1}s' -f $timer.Elapsed.TotalSeconds) -ForegroundColor Green
        [pscustomobject]@{
            Name    = $Name
            Status  = 'Installed'
            Details = ''
            Time    = '{0:N1}s' -f $timer.Elapsed.TotalSeconds
        }
    }
    catch {
        $timer.Stop()
        Write-Host ('[FAIL] Installation failed after {0:N1}s' -f $timer.Elapsed.TotalSeconds) -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor DarkRed
        [pscustomobject]@{
            Name    = $Name
            Status  = 'Failed'
            Details = $_.Exception.Message
            Time    = '{0:N1}s' -f $timer.Elapsed.TotalSeconds
        }
    }
}

New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
Ensure-PowerShell7Execution

try {
    Install-NuGetProvider
}
catch {
    throw "NuGet provider installation failed: $($_.Exception.Message)"
}

$packages = @(
    [pscustomobject]@{ Name = 'PowerShell'; Repository = $repositories.PowerShell; Installer = { param($release) Install-PowerShell -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Windows Terminal'; Repository = $repositories.Terminal; Installer = { param($release) Install-WindowsTerminal -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Git'; Repository = $repositories.Git; Installer = { param($release) Install-Git -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Node.js'; Repository = $repositories.Node; Installer = { param($release) Install-Node -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'uv'; Repository = $repositories.Uv; Installer = { param($release) Install-Uv -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'OpenCode'; Repository = $repositories.OpenCode; Installer = { param($release) Install-OpenCode -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Herdr'; Repository = $repositories.Herdr; Installer = { param($release) Install-Herdr -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Microsoft.PowerShell.SecretManagement'; Repository = $null; Installer = { param($release) Install-SecretManagement }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
)

$preflightFailed = @()
foreach ($package in $packages) {
    try {
        $release = if ($package.Name -eq 'Microsoft.PowerShell.SecretManagement') {
            Get-LatestPowerShellModuleRelease -Name $package.Name
        }
        else {
            Get-LatestStableRelease -Repository $package.Repository
        }
        $package.Release = $release
        Test-PackageNeedsInstallation -Package $package -Release $release
    }
    catch {
        $package.PreflightError = $_.Exception.Message
        $preflightFailed += $package
    }
}

Write-Host "`nPreflight Checks" -ForegroundColor Cyan
Write-Host '----------------' -ForegroundColor DarkGray
foreach ($package in $packages) {
    if ($package.PreflightError) {
        Write-Host "[FAIL] $($package.Name): $($package.PreflightError)" -ForegroundColor Red
    }
    elseif (-not $package.NeedsInstall) {
        Write-Host "[SKIP] $($package.Name) $($package.InstalledVersion) is already current ($($package.LatestVersion))." -ForegroundColor Green
    }
    else {
        $installed = if ($package.InstalledVersion) { $package.InstalledVersion } else { 'not installed' }
        Write-Host "[INSTALL] $($package.Name): installed=$installed, latest=$($package.LatestVersion)" -ForegroundColor Yellow
    }
}

$packagesToInstall = @($packages | Where-Object { $_.NeedsInstall -and -not $_.PreflightError })
if ($Reinstall -and @($packagesToInstall | Where-Object { $_.Name -eq 'Herdr' }).Count -gt 0) {
    Stop-RunningHerdr
}
$totalPackages = $packagesToInstall.Count
$packageNumber = 0
$results = @(
    foreach ($package in $packagesToInstall) {
    $packageNumber++
    Invoke-PackageInstallation -Name $package.Name -Installer $package.Installer -Number $packageNumber -Total $totalPackages -ArgumentList @($package.Release)
    }
)

$results += $preflightFailed | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Status = 'Failed'; Details = $_.PreflightError; Time = 'n/a' }
}

Write-Host "`nInstallation Summary" -ForegroundColor Cyan
Write-Host '--------------------' -ForegroundColor DarkGray
$results | Select-Object Name, Status, Time | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.Status -eq 'Failed' })
if ($failed.Count -eq 0) {
    Write-Host '[OK] All package installations completed.' -ForegroundColor Green
}
else {
    Write-Host "[FAIL] $($failed.Count) package installation(s) failed." -ForegroundColor Red
    Write-Host '       Failure details:' -ForegroundColor DarkRed
    $failed | ForEach-Object { Write-Host "       - $($_.Name): $($_.Details)" -ForegroundColor DarkRed }
}

Update-ProcessEnvironment
Set-PreferredToolPathEntries
Update-ProcessEnvironment
Write-Host 'Environment variables refreshed.' -ForegroundColor Green

$herdrPackage = @($packages | Where-Object { $_.Name -eq 'Herdr' -and -not $_.PreflightError -and $_.InstalledVersion })
if ($herdrPackage.Count -gt 0) {
    Set-HerdrDefaultShell
    Write-Host 'Herdr default shell configured as pwsh.exe.' -ForegroundColor Green
}
