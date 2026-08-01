#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the FMDK Agentic OS app and CLI for updates and applies them.
#>

$ErrorActionPreference = 'Stop'

function Update-GitClone {
    param(
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string]$FriendlyName
    )
    if (-not (Test-Path (Join-Path $Dest '.git'))) {
        Write-Host "  $FriendlyName is not installed at $Dest - skipping."
        return
    }
    Write-Host "Checking $FriendlyName for updates..."
    Push-Location $Dest
    try {
        git fetch --quiet origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch exited with code $LASTEXITCODE" }

        $local = git rev-parse HEAD
        $remote = git rev-parse '@{u}'
        if ($local -eq $remote) {
            Write-Host "  $FriendlyName is already up to date."
            return
        }
        Write-Host "  Updating $FriendlyName..."
        git reset --quiet --hard '@{u}'
        if ($LASTEXITCODE -ne 0) { throw "git reset exited with code $LASTEXITCODE" }
        Write-Host "  OK $FriendlyName updated."
    } catch {
        Write-Host "  X Could not check $FriendlyName for updates. Check your internet connection and try again." -ForegroundColor Red
        Write-Host "    ($($_.Exception.Message))" -ForegroundColor DarkGray
    } finally {
        Pop-Location
    }
}

$InstallRoot = Join-Path $env:LOCALAPPDATA 'FMDK-Workbench'

# Stop it first — it holds file locks (its own working directory, loaded
# modules) that can make a live git reset --hard behave oddly on the app
# folder while it's running. Guarded with Test-Path since an install from
# before this script existed won't have it yet.
$stopScript = Join-Path $InstallRoot 'stop-workbench.ps1'
if (Test-Path $stopScript) {
    & $stopScript
}

Update-GitClone -Dest (Join-Path $InstallRoot 'app') -FriendlyName 'FMDK Agentic OS'
Update-GitClone -Dest (Join-Path $InstallRoot 'framework') -FriendlyName 'Framework CLI'

Write-Host ""
Write-Host "Update check complete. Relaunch FMDK Agentic OS from your Desktop or Start Menu shortcut to use the update."
