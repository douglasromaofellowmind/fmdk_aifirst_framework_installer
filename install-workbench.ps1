#Requires -Version 5.1
<#
.SYNOPSIS
    FMDK Agentic OS installer — bare Windows to a running app, one script.
.DESCRIPTION
    Installs Node.js, Git, the GitHub CLI, and the Claude CLI (via
    winget/npm), signs in to GitHub (needed because the app and framework
    repos are private — a private GitHub repo returns 404, not 401, to an
    unauthenticated clone, so plain git never gets to prompt for
    credentials on its own), clones the standalone FMDK Agentic OS app and
    the framework CLI, scaffolds your personal workbench home, configures
    the app, and creates Desktop + Start Menu shortcuts. Safe to re-run —
    already-installed pieces are skipped.
#>

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$FriendlyError
    )
    # Native commands (npm, winget, gh, git...) routinely write informational
    # or warning text to stderr on an otherwise-successful run — e.g. npm's
    # advisory "npm warn allow-scripts ..." line during a global install.
    # Under $ErrorActionPreference = 'Stop', any stderr line from a native
    # command gets promoted into a script-terminating error regardless of
    # exit code, so this function would report success as failure. Relax it
    # locally to the exit-code check this function actually performs (same
    # fix already applied to the one-off `gh auth status` check in
    # Connect-GitHubAccount — this covers every other Invoke-Checked caller).
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Reset before every call so the check below reflects THIS action, not
        # a stale exit code left over from an earlier native command elsewhere
        # in the script — needed because non-native actions (COM calls,
        # Start-Process) never touch $LASTEXITCODE themselves. Must be
        # $global: — a bare assignment here would just shadow the real
        # automatic variable in this function's own scope.
        $global:LASTEXITCODE = 0
        & $Action
        if ($LASTEXITCODE -ne 0) {
            throw "exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Host ""
        Write-Host "X $FriendlyError" -ForegroundColor Red
        Write-Host "  ($($_.Exception.Message))" -ForegroundColor DarkGray
        exit 1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$CheckCommand,
        [Parameter(Mandatory)][string]$FriendlyName,
        [string]$Scope = '',
        # An optional package enables a FEATURE, not the app itself, so every
        # failure path warns and the install continues. Without this, one
        # nice-to-have that a locked-down machine won't take costs the user the
        # entire workbench.
        [switch]$Optional,
        [string]$OptionalNote = ''
    )
    if (Test-CommandAvailable $CheckCommand) {
        Write-Host "  $FriendlyName already installed - skipping."
        return
    }

    # One place to give up, so every bail-out below honours -Optional the same way.
    $bail = {
        param($Reason, $Fix)
        if ($Optional) {
            Write-Host "! Skipping $FriendlyName - $Reason" -ForegroundColor Yellow
            if ($OptionalNote) { Write-Host "  $OptionalNote" -ForegroundColor Yellow }
            Write-Host "  To add it later: $Fix" -ForegroundColor Yellow
            return
        }
        Write-Host "X $Reason" -ForegroundColor Red
        Write-Host "  $Fix" -ForegroundColor Red
        exit 1
    }

    Write-Step "Installing $FriendlyName..."
    if (-not (Test-CommandAvailable 'winget')) {
        & $bail "winget is not available on this machine." "Install 'App Installer' from the Microsoft Store, then re-run this script."
        return
    }
    # A package with no user-scope installer needs machine-scope, which winget
    # will silently sit on a UAC elevation prompt for on a standard account —
    # fail fast with clear guidance instead of hanging or leaving a confusing
    # winget exit code as the only clue.
    if ($Scope -ne 'user' -and -not (Test-IsAdmin)) {
        & $bail "$FriendlyName needs administrator rights to install on this machine, and this isn't running as admin." "Ask your IT admin to install $FriendlyName for you, or right-click PowerShell and choose 'Run as administrator', then re-run this script."
        return
    }

    $scopeArgs = @()
    if ($Scope) { $scopeArgs = @('--scope', $Scope) }

    if ($Optional) {
        winget install --id $Id -e @scopeArgs --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Host "! $FriendlyName did not install (winget exit $LASTEXITCODE) - continuing without it." -ForegroundColor Yellow
            if ($OptionalNote) { Write-Host "  $OptionalNote" -ForegroundColor Yellow }
            Write-Host "  To add it later: winget install -e --id $Id" -ForegroundColor Yellow
        }
        return
    }

    Invoke-Checked -FriendlyError "Could not install $FriendlyName. Check your internet connection and try again." -Action {
        winget install --id $Id -e @scopeArgs --source winget --accept-package-agreements --accept-source-agreements
    }
}

function Install-Runtime {
    Write-Step "Setting up the runtime (Node.js, Git, GitHub CLI, Azure CLI)..."
    # OpenJS.NodeJS.LTS's winget manifest has no user-scope installer (checked 2026-07 against microsoft/winget-pkgs) — needs admin rights, handled by the elevation check in Install-WingetPackage. Git.Git does support user scope. GitHub.cli's scope support is unconfirmed — left unset so the same elevation check applies if it turns out to need it too.
    Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -CheckCommand 'node' -FriendlyName 'Node.js'
    Install-WingetPackage -Id 'Git.Git' -CheckCommand 'git' -FriendlyName 'Git' -Scope 'user'
    # Required, not optional: the app and framework repos are private, and a
    # private GitHub repo answers 404 rather than 401, so a plain clone never
    # gets a challenge to prompt against. `gh auth login` is what makes the
    # clones below work at all.
    Install-WingetPackage -Id 'GitHub.cli' -CheckCommand 'gh' -FriendlyName 'GitHub CLI'
    # Every live connection (Project Operations, Azure DevOps, SharePoint) signs
    # in as the `az` user — no PAT, no app registration — so without this the
    # workbench can only ever reach sample data and Excel imports. Optional
    # because that fallback is genuinely usable, and because the MSI is
    # machine-scope: a standard account would otherwise lose the whole install
    # over a connector it may not even need.
    Install-WingetPackage -Id 'Microsoft.AzureCLI' -CheckCommand 'az' -FriendlyName 'Azure CLI' `
        -Optional -OptionalNote 'Your workbench still works on Excel imports and sample data; live Project Operations, Azure DevOps and SharePoint need this.'

    # winget-installed tools need a PATH refresh for this process before Get-Command can see them.
    $env:Path = $env:Path + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

    if (-not (Test-CommandAvailable 'node')) {
        Write-Host "X Node.js installed but not found on PATH. Close this window, reopen PowerShell, and re-run this script." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-CommandAvailable 'git')) {
        Write-Host "X Git installed but not found on PATH. Close this window, reopen PowerShell, and re-run this script." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-CommandAvailable 'gh')) {
        Write-Host "X GitHub CLI installed but not found on PATH. Close this window, reopen PowerShell, and re-run this script." -ForegroundColor Red
        exit 1
    }
    Write-Host "OK Node.js, Git, and GitHub CLI ready."
}

$NativeClaudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'

function Install-ClaudeCli {
    if (Test-Path $NativeClaudeExe) {
        Write-Host "  Claude CLI already installed - skipping."
        return
    }
    Write-Step "Installing the Claude CLI..."
    # `npm install -g @anthropic-ai/claude-code` only produces a real
    # claude.exe once its postinstall (and its win32-x64 optional
    # dependency's own postinstall) both run and link the native binary into
    # place — recent npm gates install scripts behind --allow-scripts, and
    # even granted, npm still creates `claude.cmd` / `claude.ps1` text shims
    # alongside it. Those shims run fine from an interactive shell, but the
    # Claude Agent SDK spawns the CLI directly with no shell, and Windows
    # can't execute a batch/PowerShell script that way — it fails with
    # EFTYPE ("inappropriate file type"). Anthropic's native installer
    # sidesteps all of that: one real claude.exe, nothing to link or shim.
    Invoke-Checked -FriendlyError "Could not install the Claude CLI. Check your internet connection and try again." -Action {
        Invoke-Expression (Invoke-RestMethod 'https://claude.ai/install.ps1')
    }
    if (-not (Test-Path $NativeClaudeExe)) {
        Write-Host "X Claude CLI installer finished but $NativeClaudeExe was not found." -ForegroundColor Red
        exit 1
    }
    # The installer updates the persistent User PATH, but this process's own
    # PATH won't see that until a new shell starts — same class of gap as
    # the winget PATH refresh in Install-Runtime.
    $env:Path = $env:Path + ';' + (Split-Path $NativeClaudeExe -Parent)
    Write-Host "OK Claude CLI installed."
}

function Connect-ClaudeAccount {
    Write-Step "Signing in to Claude..."
    Write-Host "  A browser window will open - sign in with your Claude account."
    Invoke-Checked -FriendlyError "Claude sign-in did not complete. Run 'claude auth login' yourself, then re-run this script." -Action {
        claude auth login
    }
    Write-Host "OK Signed in to Claude."
}

function Connect-GitHubAccount {
    # The app and framework repos are private. A private GitHub repo returns
    # 404 (not 401) to an unauthenticated git operation specifically so it
    # doesn't reveal the repo exists — and git only knows to prompt for
    # credentials in response to a real 401 challenge, so a bare `git clone`
    # against a private GitHub repo never gets the chance to ask for
    # sign-in. `gh auth login` does the actual sign-in (a real browser/device
    # flow, no token typed by hand); `gh auth setup-git` wires git itself to
    # use that sign-in for subsequent `git clone`/`git fetch` calls.
    # A plain redirect of a native command's stderr (what `gh auth status`
    # writes its "not logged in" message to) can get promoted into a
    # script-terminating error under $ErrorActionPreference = 'Stop', even
    # though this check only cares about the exit code. Relax that locally,
    # just for this one check, so "not logged in yet" is treated as the
    # ordinary, expected first-run case it is, not a fatal error.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    gh auth status --hostname github.com 2>&1 | Out-Null
    $isLoggedIn = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $previousErrorActionPreference
    if (-not $isLoggedIn) {
        Write-Step "Signing in to GitHub..."
        Write-Host "  A browser window will open - sign in with the GitHub account that has access to the FMDK Agentic OS repos."
        Invoke-Checked -FriendlyError "GitHub sign-in did not complete. Run 'gh auth login' yourself, then re-run this script." -Action {
            gh auth login --hostname github.com --git-protocol https --web
        }
    } else {
        Write-Host "  Already signed in to GitHub - skipping."
    }
    Invoke-Checked -FriendlyError "Could not configure git to use your GitHub sign-in." -Action {
        gh auth setup-git
    }
    Write-Host "OK GitHub ready."
}

$InstallRoot = Join-Path $env:LOCALAPPDATA 'FMDK-Workbench'
$AppDir = Join-Path $InstallRoot 'app'
$CliDir = Join-Path $InstallRoot 'framework'
$WorkbenchHome = Join-Path $env:USERPROFILE 'FMDK-Workbench'

$AppRepoUrl = 'https://github.com/douglas-romao_fmdk/fmdk_aifirst_framework_ui.git'
$FrameworkRepoUrl = 'https://github.com/douglas-romao_fmdk/fmdk_aifirst_framework.git'
$InstallerDistUrl = 'https://raw.githubusercontent.com/douglasromaofellowmind/fmdk_aifirst_framework_installer/main'

function Install-GitClone {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string]$FriendlyName
    )
    if (Test-Path (Join-Path $Dest '.git')) {
        Write-Host "  $FriendlyName already installed at $Dest - skipping."
        return
    }
    Write-Step "Downloading $FriendlyName..."
    $parentDir = Split-Path $Dest -Parent
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null

    # Clone into a temp sibling, then rename into place only on success, so an
    # interrupted clone (laptop sleep, wifi drop, closed terminal) never leaves
    # a partial .git dir that a later run's Test-Path check mistakes for a
    # completed install.
    $tempDest = "$Dest.partial"
    if (Test-Path $tempDest) {
        Remove-Item -Recurse -Force $tempDest
    }
    Invoke-Checked -FriendlyError "Could not download $FriendlyName. Check your internet connection and sign-in, then try again." -Action {
        git clone --quiet -- $Url $tempDest
    }
    Rename-Item -Path $tempDest -NewName (Split-Path $Dest -Leaf)
    Write-Host "OK $FriendlyName downloaded."
}

function Initialize-WorkbenchHome {
    param([Parameter(Mandatory)][string]$FmdkCliPath)

    New-Item -ItemType Directory -Force -Path $WorkbenchHome | Out-Null

    $markerPath = Join-Path $WorkbenchHome '.agents\fmdk.json'
    $mcpConfigPath = Join-Path $WorkbenchHome '.mcp.json'
    if ((Test-Path $markerPath) -and (Test-Path $mcpConfigPath)) {
        Write-Host "  Workbench home already set up at $WorkbenchHome - skipping."
        return
    }

    Write-Step "Setting up your workbench home at $WorkbenchHome..."
    Push-Location $WorkbenchHome
    try {
        Invoke-Checked -FriendlyError "Could not set up your workbench home. Try re-running this script." -Action {
            node $FmdkCliPath init --workbench --force
        }
    } finally {
        Pop-Location
    }
    Write-Host "OK Workbench home ready."
}

function Set-PersistentEnvVar {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $current = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($current -eq $Value) {
        Write-Host "  $Name already set - skipping."
        return $false
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "Env:$Name" -Value $Value
    Write-Host "OK $Name set."
    return $true
}

function Stop-RunningApp {
    # A running instance only ever reads these env vars once, at its own
    # startup — updating them here does nothing for it, and the launch
    # shortcut reuses an already-running instance rather than restarting it
    # (see the README), so a stale process would silently keep using the old
    # value. Same reasoning update-workbench.ps1 already applies before
    # pulling updates; a config change on re-run needs the same treatment.
    $conn = Get-NetTCPConnection -LocalPort 3030 -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Stop-Process -Id $conn.OwningProcess -Force
        Write-Host "  Stopped the running FMDK Agentic OS instance so it picks up the new config on next launch."
    }
}

function Set-AppConfig {
    Write-Step "Configuring the app..."
    $configChanged = $false
    $configChanged = (Set-PersistentEnvVar -Name 'CLAUDE_DIR' -Value $WorkbenchHome) -or $configChanged
    # Nitro only honors the NUXT_-prefixed form as a runtime override for a
    # runtimeConfig key, and the app ships prebuilt, so the bare name alone was
    # silently ignored — cloning a project failed with "Framework CLI not found.
    # Reinstall the workbench.", advice that could never have helped because a
    # reinstall set the same ignored variable again. Both names are written: the
    # NUXT_ one is what Nitro reads, the bare one is what older builds read.
    $fmdkCli = Join-Path $CliDir 'framework\bin\fmdk.js'
    $configChanged = (Set-PersistentEnvVar -Name 'FMDK_CLI_PATH' -Value $fmdkCli) -or $configChanged
    $configChanged = (Set-PersistentEnvVar -Name 'NUXT_FMDK_CLI_PATH' -Value $fmdkCli) -or $configChanged
    # The Claude Agent SDK's own bundled native CLI binary is an optional,
    # platform-specific dependency resolved via node_modules at install time
    # — absent from the standalone extracted app (no node_modules shipped).
    # Point it at the `claude` CLI this script already installed instead.
    # Nitro only honors a NUXT_-prefixed env var as a runtime override for
    # any runtimeConfig key (confirmed the hard way earlier in this same
    # installer, for reactDistDir/REACT_DIST_DIR) — not the bare name.
    # Use the known native-install path directly rather than `Get-Command
    # claude`: if a stray npm-based install is also on PATH, that resolves
    # `claude.cmd` / `claude.ps1` — text shims the SDK can't spawn directly
    # (it fails with EFTYPE, "inappropriate file type") — instead of the
    # real claude.exe Install-ClaudeCli just verified exists.
    $claudeCliPath = if (Test-Path $NativeClaudeExe) { $NativeClaudeExe } else { (Get-Command claude).Source }
    $configChanged = (Set-PersistentEnvVar -Name 'NUXT_CLAUDE_CLI_PATH' -Value $claudeCliPath) -or $configChanged
    if ($configChanged) {
        Stop-RunningApp
    }
}

function New-HiddenLauncher {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetScript
    )
    # A .lnk pointed straight at node.exe always shows a visible console window
    # on launch — a .lnk's own WindowStyle only affects the initial state of a
    # window the target itself creates, and a console app's window still flashes
    # before any minimize takes effect. Routing through a tiny VBScript launched
    # via wscript.exe (which supports a genuinely hidden Shell.Run) is the
    # standard, well-known way to get a silent double-click launch on Windows.
    $nodePath = (Get-Command node).Source
    $vbs = @"
Set shell = CreateObject("WScript.Shell")
shell.Run """$nodePath"" ""$TargetScript""", 0, False
"@
    # VBScript expects the system's ANSI codepage, not hard ASCII, so a
    # non-ASCII character in a Windows username/path (accented, CJK, etc.)
    # doesn't get silently mangled.
    Set-Content -Path $Path -Value $vbs -Encoding Default
}

<#
.SYNOPSIS
    The Fellowmind marker for shortcut icons, or a sensible stand-in.
.DESCRIPTION
    Ships with the built React app (ui-react/public/favicon.ico -> react-dist/favicon.ico).
    Before this existed the shortcuts wore node.exe's and powershell.exe's icons. Falls back
    rather than failing: an older app clone, or a layout change, must still yield a working
    shortcut.
#>
function Get-ShortcutIcon {
    param([Parameter(Mandatory)][string]$Fallback)
    $icon = Join-Path $AppDir 'react-dist\favicon.ico'
    if (Test-Path $icon) { return $icon }
    return $Fallback
}

function New-AppShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LauncherScript,
        [Parameter(Mandatory)][string]$Description
    )
    if (Test-Path $Path) {
        Write-Host "  Shortcut already exists at $Path - skipping."
        return
    }
    $wscriptPath = (Get-Command wscript).Source
    $iconPath = Get-ShortcutIcon (Get-Command node).Source
    Invoke-Checked -FriendlyError "Could not create the shortcut at $Path." -Action {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $wscriptPath
        $shortcut.Arguments = "`"$LauncherScript`""
        $shortcut.IconLocation = $iconPath
        $shortcut.Description = $Description
        $shortcut.Save()
    }
}

function Install-Shortcuts {
    Write-Step "Creating shortcuts..."
    $binScript = Join-Path $AppDir 'bin\start.mjs'
    $launcherScript = Join-Path $InstallRoot 'launch-hidden.vbs'
    New-HiddenLauncher -Path $launcherScript -TargetScript $binScript

    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'FMDK Agentic OS'
    New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null

    New-AppShortcut -Path (Join-Path $desktop 'FMDK Agentic OS.lnk') -LauncherScript $launcherScript -Description 'FMDK Agentic OS'
    New-AppShortcut -Path (Join-Path $startMenuDir 'FMDK Agentic OS.lnk') -LauncherScript $launcherScript -Description 'FMDK Agentic OS'
    Write-Host "OK Shortcuts created."
}

function Start-WorkbenchApp {
    Write-Step "Launching FMDK Agentic OS..."
    $binScript = Join-Path $AppDir 'bin\start.mjs'
    $nodePath = (Get-Command node).Source
    # -WindowStyle Hidden means a crash here is otherwise completely silent —
    # redirect to log files so a failure to start is actually diagnosable
    # instead of just "nothing happens."
    $outLog = Join-Path $InstallRoot 'app-output.log'
    $errLog = Join-Path $InstallRoot 'app-error.log'
    # bin/start.mjs opens the browser itself once the server actually
    # responds (it polls, with a real timeout) — not a fixed sleep here,
    # which was too short on a cold machine's first launch.
    Invoke-Checked -FriendlyError "Could not start FMDK Agentic OS. Try launching it from the shortcut instead." -Action {
        Start-Process -FilePath $nodePath -ArgumentList "`"$binScript`"" -WorkingDirectory $AppDir -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    }
    Write-Host "OK FMDK Agentic OS is starting - your browser will open in a few seconds."
    Write-Host "  If it doesn't, check $errLog for errors."
}

function New-UpdateShortcut {
    $updateScript = Join-Path $InstallRoot 'update-workbench.ps1'
    # $PSCommandPath is empty when this script runs via `irm | iex` (the
    # documented bootstrap) — there's no local script file to copy from,
    # just an evaluated string. Fetch the update script from the same
    # public mirror this installer itself came from instead.
    Invoke-Checked -FriendlyError "Could not download the update script. Check your internet connection and try again." -Action {
        Invoke-RestMethod -Uri "$InstallerDistUrl/update-workbench.ps1" -OutFile $updateScript
    }

    $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'FMDK Agentic OS'
    $path = Join-Path $startMenuDir 'Check for Updates.lnk'
    if (Test-Path $path) {
        Write-Host "  Update shortcut already exists - skipping."
        return
    }

    $powershellPath = (Get-Command powershell).Source
    Invoke-Checked -FriendlyError "Could not create the Check for Updates shortcut at $path." -Action {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = $powershellPath
        $shortcut.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$updateScript`""
        $shortcut.IconLocation = Get-ShortcutIcon $powershellPath
        $shortcut.Description = 'Check FMDK Agentic OS for updates'
        $shortcut.Save()
    }
    Write-Host "OK Update shortcut created."
}

function New-StopShortcut {
    $stopScript = Join-Path $InstallRoot 'stop-workbench.ps1'
    Invoke-Checked -FriendlyError "Could not download the stop script. Check your internet connection and try again." -Action {
        Invoke-RestMethod -Uri "$InstallerDistUrl/stop-workbench.ps1" -OutFile $stopScript
    }

    $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'FMDK Agentic OS'
    $path = Join-Path $startMenuDir 'Stop FMDK Agentic OS.lnk'
    if (Test-Path $path) {
        Write-Host "  Stop shortcut already exists - skipping."
        return
    }

    $powershellPath = (Get-Command powershell).Source
    Invoke-Checked -FriendlyError "Could not create the Stop FMDK Agentic OS shortcut at $path." -Action {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = $powershellPath
        $shortcut.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$stopScript`""
        $shortcut.IconLocation = Get-ShortcutIcon $powershellPath
        $shortcut.Description = 'Stop FMDK Agentic OS'
        $shortcut.Save()
    }
    Write-Host "OK Stop shortcut created."
}

# ==== MAIN ====

Write-Host "FMDK Agentic OS installer" -ForegroundColor Green
Write-Host "This installs Node.js, Git, GitHub CLI, the Azure CLI, and the Claude CLI, then sets up your workbench."
Write-Host "Already-installed pieces are skipped, so it's safe to re-run this script."

Install-Runtime
Install-ClaudeCli
Connect-ClaudeAccount
Connect-GitHubAccount

Install-GitClone -Url $AppRepoUrl -Dest $AppDir -FriendlyName 'FMDK Agentic OS app'
Install-GitClone -Url $FrameworkRepoUrl -Dest $CliDir -FriendlyName 'Framework CLI'

Initialize-WorkbenchHome -FmdkCliPath (Join-Path $CliDir 'framework\bin\fmdk.js')
Set-AppConfig
Install-Shortcuts
New-UpdateShortcut
New-StopShortcut
Start-WorkbenchApp

Write-Host ""
Write-Host "All set! FMDK Agentic OS is running at http://127.0.0.1:3030" -ForegroundColor Green
Write-Host "Find it any time via the Desktop shortcut or the Start Menu 'FMDK Agentic OS' folder."
