# This file is intended to be hosted at a trusted HTTPS URL and invoked with:
#   Invoke-WebRequest -UseBasicParsing <URL> | Invoke-Expression
# It intentionally uses only commands available in Windows PowerShell 5.1.
param(
    [switch]$Reinstall,
    [switch]$SkipReinstallPrompt,
    [switch]$WaitForExit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DownloadDirectory = Join-Path $env:TEMP 'aisetup-downloads'
$InstallerUrl = 'https://raw.githubusercontent.com/tullynet/aisetup/main/install-requirements.ps1'
$PortablePowerShellRoot = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell'
$UserModuleRoot = Join-Path $env:LOCALAPPDATA 'PowerShell\Modules'

function Wait-ForInstallerExit {
    if ($WaitForExit) {
        Read-Host 'Press Enter to close this window' | Out-Null
    }
}

trap {
    Write-Error $_
    Wait-ForInstallerExit
    break
}

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
        (Get-PortablePowerShellInstallDirectory),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Node.js'),
        (Join-Path $env:LOCALAPPDATA 'Programs\uv'),
        (Join-Path $env:LOCALAPPDATA 'Programs\OpenCode'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Herdr')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

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

function Test-RealExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if ($Path -match '(?i)\\WindowsApps\\') {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    return ($null -ne $item -and -not $item.PSIsContainer -and $item.Length -gt 0)
}

function Get-PortablePowerShellInstallDirectory {
    if (-not (Test-Path -LiteralPath $PortablePowerShellRoot)) {
        return $null
    }

    $versionDirectories = @(Get-ChildItem -LiteralPath $PortablePowerShellRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^\d+\.\d+' -and
            (Test-RealExecutable -Path (Join-Path $_.FullName 'pwsh.exe'))
        })
    $latestDirectory = $versionDirectories |
        Sort-Object { ConvertTo-NormalizedVersion -Version $_.Name } -Descending |
        Select-Object -First 1
    if ($latestDirectory) {
        return $latestDirectory.FullName
    }

    $legacyDirectory = Join-Path $PortablePowerShellRoot '7'
    if (Test-RealExecutable -Path (Join-Path $legacyDirectory 'pwsh.exe')) {
        return $legacyDirectory
    }
    return $null
}

function Get-PwshExecutable {
    $portableDirectory = Get-PortablePowerShellInstallDirectory
    $candidates = @()
    if ($portableDirectory) {
        $candidates += (Join-Path $portableDirectory 'pwsh.exe')
    }
    $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSHOME) {
        $candidates += (Join-Path $PSHOME 'pwsh.exe')
    }
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) {
        $candidates += $command.Source
    }

    foreach ($candidate in $candidates) {
        if (Test-RealExecutable -Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $destinationDirectory = Split-Path -Parent $Destination
    if ($destinationDirectory -and -not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    $lastError = $null
    foreach ($attempt in 1..3) {
        $webClient = $null
        try {
            $webClient = New-Object Net.WebClient
            $webClient.Headers['User-Agent'] = 'WindowsPowerShell-requirements-installer'
            $webClient.DownloadFile($Uri, $Destination)
            if (Test-Path -LiteralPath $Destination) {
                Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
                return
            }
            throw "Download produced no file: $Uri"
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
        finally {
            if ($null -ne $webClient) {
                $webClient.Dispose()
            }
        }
    }
    throw "Failed to download $Uri : $($lastError.Exception.Message)"
}

function Expand-ZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $extractDirectory = Join-Path $DownloadDirectory ('extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $Archive -DestinationPath $extractDirectory -Force
        $items = @(Get-ChildItem -LiteralPath $extractDirectory)
        $source = $extractDirectory
        if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
            $source = $items[0].FullName
        }
        if (Test-Path -LiteralPath $Destination) {
            try {
                Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction Stop
            }
            catch {
                Copy-Item -Path (Join-Path $source '*') -Destination $Destination -Recurse -Force
                return
            }
        }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $Destination -Recurse -Force
    }
    finally {
        if (Test-Path -LiteralPath $extractDirectory) {
            Remove-Item -LiteralPath $extractDirectory -Recurse -Force
        }
    }
}

Update-ProcessEnvironment
Set-PreferredToolPathEntries
Update-ProcessEnvironment
$env:PSModulePath = "$UserModuleRoot;$env:PSModulePath"

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

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue |
        Where-Object { Test-RealExecutable -Path $_.Source } |
        Select-Object -First 1
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

    if (-not (Test-RealExecutable -Path $Path)) {
        return $null
    }
    $output = & $Path $Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return [string]$output
}

function Get-WindowsArchitecture {
    if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        return 'arm64'
    }
    if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -or $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
        return 'x64'
    }
    throw 'This installer requires x64 or ARM64 Windows.'
}

function Get-InstalledVersion {
    param([Parameter(Mandatory = $true)][string]$Name)

    switch ($Name) {
        'PowerShell' { return Get-PortablePowerShellVersion }
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
        'Microsoft.PowerShell.SecretManagement' {
            return Get-PowerShellModuleInstalledVersion -Name 'Microsoft.PowerShell.SecretManagement'
        }
        'Microsoft.PowerShell.SecretStore' {
            return Get-PowerShellModuleInstalledVersion -Name 'Microsoft.PowerShell.SecretStore'
        }
    }
    return $null
}

function Get-PortablePowerShellVersion {
    $portableDirectory = Get-PortablePowerShellInstallDirectory
    if (-not $portableDirectory) {
        return $null
    }
    $pwsh = Join-Path $portableDirectory 'pwsh.exe'
    if (-not (Test-RealExecutable -Path $pwsh)) {
        return $null
    }

    $versionInfo = (Get-Item -LiteralPath $pwsh).VersionInfo
    foreach ($candidate in @($versionInfo.ProductVersion, $versionInfo.FileVersion)) {
        if ($candidate -match '^\d+\.\d+\.\d+') {
            return $Matches[0]
        }
    }
    return $null
}

function Get-PowerShellModuleInstalledVersion {
    param([Parameter(Mandatory = $true)][string]$Name)

    $moduleDirectory = Join-Path $UserModuleRoot $Name
    if (-not (Test-Path -LiteralPath $moduleDirectory)) {
        return $null
    }

    $manifests = @(Get-ChildItem -LiteralPath $moduleDirectory -Filter "$Name.psd1" -Recurse -ErrorAction SilentlyContinue)
    foreach ($manifest in ($manifests | Sort-Object FullName -Descending)) {
        $data = Import-PowerShellDataFile -Path $manifest.FullName
        if ($data.ModuleVersion) {
            return [string]$data.ModuleVersion
        }
    }
    return $null
}

function Get-LatestPowerShellModuleRelease {
    param([Parameter(Mandatory = $true)][string]$Name)

    $uri = "https://www.powershellgallery.com/api/v2/Packages?`$filter=Id eq '$Name' and IsLatestVersion eq true"
    $feed = Invoke-RestMethod -Uri $uri -UseBasicParsing
    $entry = $null
    if ($feed.entry) {
        $entry = @($feed.entry)[0]
    }
    elseif ($feed.properties) {
        $entry = $feed
    }
    else {
        $entry = @($feed)[0]
    }
    $version = $null
    if ($entry.properties.NormalizedVersion) {
        $version = [string]$entry.properties.NormalizedVersion
    }
    elseif ($entry.properties.Version) {
        $version = [string]$entry.properties.Version
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Could not find $Name in the PowerShell Gallery."
    }
    return [pscustomobject]@{ tag_name = $version; draft = $false; prerelease = $false }
}

function Install-PowerShellModulePackage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $moduleDirectory = Join-Path $UserModuleRoot $Name
    $versionDirectory = Join-Path $moduleDirectory $Version
    $packagePath = Join-Path $DownloadDirectory "$Name.$Version.zip"
    $packageUri = "https://www.powershellgallery.com/api/v2/package/$Name/$Version"
    Save-RemoteFile -Uri $packageUri -Destination $packagePath

    $extractDirectory = Join-Path $DownloadDirectory ('module-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $packagePath -DestinationPath $extractDirectory -Force
        $manifest = Get-ChildItem -LiteralPath $extractDirectory -Filter "$Name.psd1" -Recurse |
            Select-Object -First 1
        if ($null -eq $manifest) {
            throw "$Name.psd1 was not found in the downloaded package."
        }
        $sourceDirectory = $manifest.DirectoryName
        if (Test-Path -LiteralPath $versionDirectory) {
            Remove-Item -LiteralPath $versionDirectory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null
        Copy-Item -Path (Join-Path $sourceDirectory '*') -Destination $versionDirectory -Recurse -Force
    }
    finally {
        if (Test-Path -LiteralPath $extractDirectory) {
            Remove-Item -LiteralPath $extractDirectory -Recurse -Force
        }
    }

    foreach ($junkName in @('_rels', 'package', '[Content_Types].xml')) {
        $junkPath = Join-Path $versionDirectory $junkName
        if (Test-Path -LiteralPath $junkPath) {
            Remove-Item -LiteralPath $junkPath -Recurse -Force
        }
    }
    Get-ChildItem -LiteralPath $versionDirectory -Filter '*.nuspec' -ErrorAction SilentlyContinue |
        Remove-Item -Force
    Get-ChildItem -LiteralPath $versionDirectory -Recurse -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath (Join-Path $versionDirectory "$Name.psd1"))) {
        throw "$Name installation failed: module manifest was not installed."
    }
}

function Install-SecretManagement {
    param([Parameter(Mandatory = $true)]$Release)
    Install-PowerShellModulePackage -Name 'Microsoft.PowerShell.SecretManagement' -Version ($Release.tag_name)
}

function Install-SecretStore {
    param([Parameter(Mandatory = $true)]$Release)
    Install-PowerShellModulePackage -Name 'Microsoft.PowerShell.SecretStore' -Version ($Release.tag_name)
}

function Configure-SecretStore {
    $env:PSModulePath = "$UserModuleRoot;$env:PSModulePath"
    Remove-Module Microsoft.PowerShell.SecretStore, Microsoft.PowerShell.SecretManagement -Force -ErrorAction SilentlyContinue
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop -Force
    Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop -Force

    $storeFile = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore\storefile'
    if (-not (Test-Path -LiteralPath $storeFile)) {
        Reset-SecretStore -Authentication None -Interaction None -Force -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
    }

    if ($null -eq (Get-SecretVault -Name SecretStore -ErrorAction SilentlyContinue)) {
        Register-SecretVault -Name SecretStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault -ErrorAction Stop
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
    Save-RemoteFile -Uri $asset.browser_download_url -Destination $target

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

    $architecture = Get-WindowsArchitecture
    $archive = Save-ReleaseAsset -Release $Release -AssetPattern ("PowerShell-*-win-{0}.zip" -f $architecture) -Destination $DownloadDirectory
    $version = $Release.tag_name -replace '^v', ''
    $destination = Join-Path $PortablePowerShellRoot $version
    Write-Host "Installing PowerShell $($Release.tag_name) for the current user"
    Expand-ZipArchive -Archive $archive -Destination $destination
    $pwsh = Join-Path $destination 'pwsh.exe'
    if (-not (Test-RealExecutable -Path $pwsh)) {
        throw 'PowerShell 7 installation failed: pwsh.exe was not installed.'
    }
    Add-UserPathEntry -PathEntry $destination
    Write-Host 'PowerShell 7 was installed.' -ForegroundColor Green
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Start-InstallerInPowerShell7
    }
}

function Start-InstallerInPowerShell7 {
    $pwsh = Get-PwshExecutable
    if (-not $pwsh) {
        throw 'PowerShell 7 was installed, but pwsh.exe could not be found.'
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path $env:TEMP ('aisetup-continue-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Write-Host 'Downloading a temporary copy to continue under PowerShell 7.' -ForegroundColor Cyan
        Save-RemoteFile -Uri $InstallerUrl -Destination $scriptPath
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
    $arguments += '-WaitForExit'

    Write-Host 'Restarting the installer under PowerShell 7.' -ForegroundColor Cyan
    & $pwsh @arguments
    exit $LASTEXITCODE
}

function Ensure-PowerShell7Execution {
    $release = Get-LatestStableRelease -Repository $repositories.PowerShell
    $installedVersion = Get-InstalledVersion -Name 'PowerShell'
    $needsInstall = $Reinstall -or $null -eq (ConvertTo-NormalizedVersion -Version $installedVersion) -or
        (ConvertTo-NormalizedVersion -Version $installedVersion) -lt (ConvertTo-NormalizedVersion -Version $release.tag_name)

    if ($needsInstall) {
        Write-Host 'Installing current-user PowerShell 7 from the portable ZIP.' -ForegroundColor Yellow
        Install-PowerShell -Release $release
    }

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host 'Switching to PowerShell 7 before package management.' -ForegroundColor Yellow
        Start-InstallerInPowerShell7
    }
}

function Install-WindowsTerminal {
    param([Parameter(Mandatory = $true)]$Release)

    $installer = Save-ReleaseAsset -Release $Release -AssetPattern 'Microsoft.WindowsTerminal_*.msixbundle' -Destination $DownloadDirectory
    Write-Host "Installing Windows Terminal $($Release.tag_name)"
    try {
        Add-AppxPackage -Path $installer -DeferRegistrationWhenPackagesAreInUse -ErrorAction Stop
    }
    catch {
        Add-AppxPackage -Path $installer -DeferRegistrationWhenPackagesAreInUse -ForceUpdateFromAnyVersion
    }
}

function Install-Git {
    param([Parameter(Mandatory = $true)]$Release)

    $archive = Save-ReleaseAsset -Release $Release -AssetPattern 'PortableGit-*-64-bit.7z.exe' -Destination $DownloadDirectory
    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Git'
    $gitBinDirectory = Join-Path $installDirectory 'cmd'

    Write-Host "Installing Git $($Release.tag_name) for the current user"
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    $process = Start-Process -FilePath $archive -ArgumentList @("-o$installDirectory", '-y', '-bd') -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Git extraction failed with exit code $($process.ExitCode)."
    }
    Add-UserPathEntry -PathEntry $gitBinDirectory
}

function Install-Node {
    param([Parameter(Mandatory = $true)]$Release)

    $architecture = Get-WindowsArchitecture
    $version = $Release.tag_name -replace '^v', ''
    $archiveName = "node-v{0}-win-{1}.zip" -f $version, $architecture
    $archive = Join-Path $DownloadDirectory $archiveName
    $archiveUri = "https://nodejs.org/dist/v$version/$archiveName"

    Write-Host "Downloading $archiveName from $archiveUri"
    Save-RemoteFile -Uri $archiveUri -Destination $archive

    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Node.js'
    Expand-ZipArchive -Archive $archive -Destination $installDirectory
    Add-UserPathEntry -PathEntry $installDirectory
}

function Install-Uv {
    param([Parameter(Mandatory = $true)]$Release)

    $architecture = Get-WindowsArchitecture
    $uvArchitecture = if ($architecture -eq 'arm64') { 'aarch64' } else { 'x86_64' }
    $archive = Save-ReleaseAsset -Release $Release -AssetPattern ("uv-{0}-pc-windows-msvc.zip" -f $uvArchitecture) -Destination $DownloadDirectory
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

    $architecture = Get-WindowsArchitecture
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

function ConvertTo-TomlString {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = $Value.Replace('\', '/')
    return '"' + $normalized.Replace('"', '\"') + '"'
}

function Set-HerdrDefaultShell {
    $pwsh = Get-PwshExecutable
    if (-not $pwsh) {
        Write-Host 'Skipping Herdr default shell: a real pwsh.exe was not found.' -ForegroundColor Yellow
        return
    }

    $configDirectory = Join-Path $env:APPDATA 'herdr'
    $configPath = Join-Path $configDirectory 'config.toml'
    $shellAssignment = 'default_shell = ' + (ConvertTo-TomlString -Value $pwsh)
    $terminalConfig = @"
[terminal]
$shellAssignment
"@

    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $configPath)) {
        Set-Content -LiteralPath $configPath -Value $terminalConfig -Encoding UTF8
        return
    }

    $config = Get-Content -LiteralPath $configPath -Raw
    if ($config -match '(?m)^\s*default_shell\s*=') {
        $config = [regex]::Replace($config, '(?m)^\s*default_shell\s*=.*$', $shellAssignment)
    }
    elseif ($config -match '(?m)^\[terminal\]\s*$') {
        $config = [regex]::Replace(
            $config,
            '(?m)^\[terminal\]\s*$',
            "[terminal]`r`n$shellAssignment"
        )
    }
    else {
        $config = $config.TrimEnd() + "`r`n`r`n" + $terminalConfig
    }
    Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8
}

function Set-PowerShellProfileEntries {
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDirectory = Split-Path -Parent $profilePath
    $profileEntries = @(
        '$aisetupModulePath = Join-Path $env:LOCALAPPDATA ''PowerShell\Modules'''
        'if ($env:PSModulePath -notlike "*$aisetupModulePath*") { $env:PSModulePath = "$aisetupModulePath;$env:PSModulePath" }'
        '$env:NETAPP_OPENCODE_USER = $env:USERNAME'
        '$env:NETAPP_OPENCODE_API_KEY = try { $(Get-Secret NETAPP_OPENCODE_API_KEY -AsPlainText -ErrorAction SilentlyContinue) } catch { $null }'
    )

    New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $profilePath) {
        $profile = Get-Content -LiteralPath $profilePath -Raw
    }
    else {
        $profile = ''
    }
    foreach ($entry in $profileEntries) {
        if ($profile -notmatch [regex]::Escape($entry)) {
            $profile = $profile.TrimEnd() + "`r`n" + $entry + "`r`n"
        }
    }
    Set-Content -LiteralPath $profilePath -Value $profile -Encoding UTF8
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
New-Item -ItemType Directory -Path $UserModuleRoot -Force | Out-Null
Ensure-PowerShell7Execution

$packages = @(
    [pscustomobject]@{ Name = 'PowerShell'; Repository = $repositories.PowerShell; Installer = { param($release) Install-PowerShell -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Windows Terminal'; Repository = $repositories.Terminal; Installer = { param($release) Install-WindowsTerminal -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Git'; Repository = $repositories.Git; Installer = { param($release) Install-Git -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Node.js'; Repository = $repositories.Node; Installer = { param($release) Install-Node -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'uv'; Repository = $repositories.Uv; Installer = { param($release) Install-Uv -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'OpenCode'; Repository = $repositories.OpenCode; Installer = { param($release) Install-OpenCode -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Herdr'; Repository = $repositories.Herdr; Installer = { param($release) Install-Herdr -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Microsoft.PowerShell.SecretManagement'; Repository = $null; Installer = { param($release) Install-SecretManagement -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
    [pscustomobject]@{ Name = 'Microsoft.PowerShell.SecretStore'; Repository = $null; Installer = { param($release) Install-SecretStore -Release $release }; Release = $null; InstalledVersion = $null; LatestVersion = $null; NeedsInstall = $false; PreflightError = $null }
)

$preflightFailed = @()
foreach ($package in $packages) {
    try {
        $release = if ($package.Name -in @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')) {
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

Update-ProcessEnvironment
Set-PreferredToolPathEntries
Update-ProcessEnvironment
Write-Host 'Environment variables refreshed.' -ForegroundColor Green

if (Test-RealExecutable -Path (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\herdr.exe')) {
    Set-HerdrDefaultShell
    $pwsh = Get-PwshExecutable
    if ($pwsh) {
        Write-Host "Herdr default shell configured as $pwsh." -ForegroundColor Green
    }
}

Set-PowerShellProfileEntries
Write-Host 'PowerShell profile entries configured.' -ForegroundColor Green

$results += Invoke-PackageInstallation -Name 'SecretStore vault' -Installer { Configure-SecretStore } -Number 1 -Total 1

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

Wait-ForInstallerExit
if ($failed.Count -gt 0) {
    exit 1
}
exit 0
