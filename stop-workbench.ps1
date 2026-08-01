#Requires -Version 5.1
<#
.SYNOPSIS
    Stops FMDK Agentic OS if it's currently running.
.DESCRIPTION
    Finds whatever process is listening on the app's port and stops it —
    the app runs with a hidden window (no console, no taskbar entry), so
    there's no window to close by hand otherwise. Also called by
    update-workbench.ps1 before pulling updates, since a running instance
    holds file locks (its own working directory, loaded modules) that can
    make a live update — or a manual folder delete — fail with "file in
    use" errors.
#>

$ErrorActionPreference = 'Stop'

$Port = 3030

try {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Stop-Process -Id $conn.OwningProcess -Force
        Write-Host "Stopped FMDK Agentic OS (was running as process $($conn.OwningProcess))."
    } else {
        Write-Host "FMDK Agentic OS isn't currently running."
    }
} catch {
    Write-Host "Could not check/stop FMDK Agentic OS: $($_.Exception.Message)" -ForegroundColor Red
}
