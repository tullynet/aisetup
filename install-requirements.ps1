# This file is intended to be hosted at a trusted HTTPS URL and invoked with:
#   Invoke-WebRequest -UseBasicParsing <URL> | Invoke-Expression
# It intentionally uses only commands available in Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DownloadDirectory = Join-Path $env:TEMP 'aisetup-downloads'

$repositories = @{
    PowerShell = 'PowerShell/PowerShell'
    Terminal   = 'microsoft/terminal'
    Git        = 'git-for-windows/git'
}

function Get-LatestStableRelease {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $headers = @{
        Accept     = 'application/vnd.github+json'
        'User-Agent' = 'WindowsPowerShell-requirements-installer'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = "https://api.github.com/repos/$Repository/releases/latest"
    $release = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing

    if ($release.draft -or $release.prerelease) {
        throw "GitHub returned a non-stable release for ${Repository}: $($release.tag_name)"
    }
    return $release
}

function Save-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][regex]$AssetPattern,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $asset = @($Release.assets | Where-Object { $_.name -match $AssetPattern }) | Select-Object -First 1
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

function Install-PowerShell {
    $release = Get-LatestStableRelease -Repository $repositories.PowerShell
    $bundle = Save-ReleaseAsset -Release $release -AssetPattern '^PowerShell-[0-9].*\.msixbundle$' -Destination $DownloadDirectory

    Write-Host "Installing PowerShell $($release.tag_name) for the current user"
    Add-AppxPackage -Path $bundle -DeferRegistrationWhenPackagesAreInUse
    Write-Host 'PowerShell 7 was installed. Restart Windows Terminal to load its dynamic profile.' -ForegroundColor Green
}

function Install-WindowsTerminal {
    $release = Get-LatestStableRelease -Repository $repositories.Terminal
    $installer = Save-ReleaseAsset -Release $release -AssetPattern '^Microsoft\.WindowsTerminal_.*_8wekyb3d8bbwe\.msixbundle$' -Destination $DownloadDirectory

    Write-Host "Installing Windows Terminal $($release.tag_name)"
    Add-AppxPackage -Path $installer -DeferRegistrationWhenPackagesAreInUse
}

function Install-Git {
    $release = Get-LatestStableRelease -Repository $repositories.Git
    $archive = Save-ReleaseAsset -Release $release -AssetPattern '^PortableGit-.*-64-bit\.7z\.exe$' -Destination $DownloadDirectory
    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Git'
    $gitBinDirectory = Join-Path $installDirectory 'cmd'

    Write-Host "Installing Git $($release.tag_name) for the current user"
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    $process = Start-Process -FilePath $archive -ArgumentList @("-o$installDirectory", '-y') -Wait -PassThru
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

function Invoke-PackageInstallation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Installer,
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][int]$Total
    )

    Write-Host "`n[$Number/$Total] $Name" -ForegroundColor Cyan
    Write-Host ('-' * ($Name.Length + 8)) -ForegroundColor DarkGray
    $timer = [Diagnostics.Stopwatch]::StartNew()

    try {
        & $Installer
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

$packages = @(
    [pscustomobject]@{ Name = 'PowerShell'; Installer = { Install-PowerShell } }
    [pscustomobject]@{ Name = 'Windows Terminal'; Installer = { Install-WindowsTerminal } }
    [pscustomobject]@{ Name = 'Git'; Installer = { Install-Git } }
)

$totalPackages = $packages.Count
$packageNumber = 0
$results = foreach ($package in $packages) {
    $packageNumber++
    Invoke-PackageInstallation -Name $package.Name -Installer $package.Installer -Number $packageNumber -Total $totalPackages
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
