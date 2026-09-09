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
    $installer = Save-ReleaseAsset -Release $release -AssetPattern '^PowerShell-.*-win-x64\.msi$' -Destination $DownloadDirectory

    Write-Host "Installing PowerShell $($release.tag_name)"
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $installer, '/qn', '/norestart') -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "PowerShell installation failed with exit code $($process.ExitCode)."
    }
}

function Install-WindowsTerminal {
    $release = Get-LatestStableRelease -Repository $repositories.Terminal
    $bundle = Save-ReleaseAsset -Release $release -AssetPattern '^Microsoft\.WindowsTerminal_.*_8wekyb3d8bbwe\.msixbundle$' -Destination $DownloadDirectory

    Write-Host "Installing Windows Terminal $($release.tag_name)"
    Add-AppxPackage -Path $bundle
}

New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null

Install-PowerShell
Install-WindowsTerminal

Write-Host 'PowerShell 7 and stable Windows Terminal installation completed.' -ForegroundColor Green
