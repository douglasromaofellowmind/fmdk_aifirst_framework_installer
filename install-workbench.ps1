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

function Format-Elapsed {
    param([Parameter(Mandatory)][TimeSpan]$Span)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Span.TotalSeconds -lt 1) { return "$([int]$Span.TotalMilliseconds)ms" }
    if ($Span.TotalSeconds -lt 60) { return $Span.TotalSeconds.ToString('0.0', $inv) + 's' }
    return ('{0}m {1:D2}s' -f [int][math]::Floor($Span.TotalMinutes), [int]$Span.Seconds)
}

$script:StepNumber = 0
$script:StepCount = 10

# One row of the install: the -Name is the label a person reads (in the console
# today, in the window row and the details log next), the -Action is the
# unchanged step function. Every failure still propagates to the top-level
# catch in MAIN; this only adds the banner, the timing, and the OK/X line.
function Invoke-Step {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Action,
        # The step prompts in the console: say so on the row and bring the console forward.
        [switch]$Handoff
    )
    $script:StepNumber++
    $row = $script:StepNumber - 1
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ""
    Write-Host "[$($script:StepNumber)/$($script:StepCount)] $Name" -ForegroundColor Cyan
    $hint = if ($Handoff) { if ($script:Ui) { 'Sign in in the browser; the code goes in the box below' } else { 'Finish signing in in this window' } } else { '' }
    Set-StepRow -Index $row -State running -Hint $hint
    Set-WindowHeader -Status $Name -Completed $row
    try {
        & $Action
    } catch {
        $elapsed = Format-Elapsed $watch.Elapsed
        Write-Host "X $Name - stopped after $elapsed" -ForegroundColor Red
        Set-StepRow -Index $row -State failed -Time $elapsed
        throw
    }
    $elapsed = Format-Elapsed $watch.Elapsed
    Write-Host "OK $Name ($elapsed)" -ForegroundColor Green
    Set-StepRow -Index $row -State done -Time $elapsed
    Set-WindowHeader -Status $Name -Completed ($row + 1)
    if ($Handoff) { Send-WindowMessage @{ Kind = 'activate' } }
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
        # Not `exit` — the documented install path runs this script via `irm | iex`,
        # which dot-sources it into the caller's own interactive session. `exit` there
        # kills that whole window, taking this message with it before it can be read
        # (PowerShell/PowerShell#8816). `throw` unwinds to the one top-level catch at
        # the bottom of this file instead, which pauses and stops safely.
        throw $FriendlyError
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
        throw $Reason
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
        throw "Node.js not found on PATH"
    }
    if (-not (Test-CommandAvailable 'git')) {
        Write-Host "X Git installed but not found on PATH. Close this window, reopen PowerShell, and re-run this script." -ForegroundColor Red
        throw "Git not found on PATH"
    }
    if (-not (Test-CommandAvailable 'gh')) {
        Write-Host "X GitHub CLI installed but not found on PATH. Close this window, reopen PowerShell, and re-run this script." -ForegroundColor Red
        throw "GitHub CLI not found on PATH"
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
        throw "Claude CLI not found after install"
    }
    # The installer updates the persistent User PATH, but this process's own
    # PATH won't see that until a new shell starts — same class of gap as
    # the winget PATH refresh in Install-Runtime.
    $env:Path = $env:Path + ';' + (Split-Path $NativeClaudeExe -Parent)
    Write-Host "OK Claude CLI installed."
}

# A company-managed PC (Entra-joined) signs in to Claude through the
# organisation's SSO. Seen live on exactly such a machine: the plain flow's
# pasted code is rejected server-side with 400 (claude-code#78157 shape), while
# `claude auth login --sso` completes. dsregcmd is the documented read of the
# device's join state.
function Test-EntraJoined {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $status = & dsregcmd /status 2>&1
        return [bool]($status -match '^\s*AzureAdJoined\s*:\s*YES')
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

# `claude auth status` answers as JSON ({"loggedIn":true,"email":...}). Older
# CLIs or a parse failure fall through to the sign-in, never to a false skip.
function Get-ClaudeSignIn {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $status = (& claude auth status 2>&1 | Out-String | ConvertFrom-Json)
        if ($status -and $status.loggedIn) { return $status }
        return $null
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Connect-ClaudeAccount {
    $signedIn = Get-ClaudeSignIn
    if ($signedIn) {
        $who = if ($signedIn.email) { " as $($signedIn.email)" } else { '' }
        Write-Host "  Already signed in to Claude$who - skipping."
        return
    }
    Write-Step "Signing in to Claude..."
    $sso = Test-EntraJoined
    $command = if ($sso) { "claude auth login --sso" } else { "claude auth login" }
    if ($sso) { Write-Host "  Company-managed PC - using your organisation's single sign-on." }
    Write-Host "  A browser window will open - sign in with your Claude account."
    Invoke-Checked -FriendlyError "Claude sign-in did not complete. Run '$command' yourself, then re-run this script." -Action {
        if ($sso) { claude auth login --sso } else { claude auth login }
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

$script:InstallLogPath = $null
$script:InstallLogStart = 0

function Start-InstallLog {
    # Start-Transcript records everything the host shows - our lines and native
    # command output alike - without redirecting any stream, so the two
    # interactive sign-ins (claude / gh) behave exactly as they do without it.
    # Redirecting streams instead would hand those CLIs a pipe rather than a
    # console, and some change their prompts when stdout is not a terminal.
    $path = Join-Path $InstallRoot 'install-log.txt'
    try {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
        # The log is appended across runs (the history has already paid for
        # itself). The window tails only THIS run: it starts at the length the
        # file had before this transcript began - a tail from byte 0 re-reads
        # every earlier run, reopens every old sign-in URL (five tabs, live)
        # and re-shows old prompts.
        $script:InstallLogStart = if (Test-Path $path) { (Get-Item $path).Length } else { 0 }
        Start-Transcript -Path $path -Append -Force | Out-Null
        $script:InstallLogPath = $path
    } catch {
        # A transcript already running in this session, or a locked file. The
        # install works without the log; say so once and carry on.
        Write-Host "  (Could not write the install log at $path - continuing without it.)" -ForegroundColor DarkGray
    }
}

function Stop-InstallLog {
    if ($script:InstallLogPath) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

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
    The Hive AI mark for shortcut icons, or a sensible stand-in.
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
    # Rewritten every run rather than skipped when it already exists: every value below is
    # deterministic, so re-saving is a no-op EXCEPT for the icon — and skipping was why a
    # brand change never reached anyone who had already installed.
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
    Write-Host "OK Shortcuts written."
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
    Write-Host "OK Update shortcut written."
}

function New-StopShortcut {
    $stopScript = Join-Path $InstallRoot 'stop-workbench.ps1'
    Invoke-Checked -FriendlyError "Could not download the stop script. Check your internet connection and try again." -Action {
        Invoke-RestMethod -Uri "$InstallerDistUrl/stop-workbench.ps1" -OutFile $stopScript
    }

    $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'FMDK Agentic OS'
    $path = Join-Path $startMenuDir 'Stop FMDK Agentic OS.lnk'
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
    Write-Host "OK Stop shortcut written."
}

function New-UninstallShortcut {
    $uninstallScript = Join-Path $InstallRoot 'uninstall-workbench.ps1'
    Invoke-Checked -FriendlyError "Could not download the uninstall script. Check your internet connection and try again." -Action {
        Invoke-RestMethod -Uri "$InstallerDistUrl/uninstall-workbench.ps1" -OutFile $uninstallScript
    }

    $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'FMDK Agentic OS'
    $path = Join-Path $startMenuDir 'Uninstall FMDK Agentic OS.lnk'
    $powershellPath = (Get-Command powershell).Source
    Invoke-Checked -FriendlyError "Could not create the Uninstall FMDK Agentic OS shortcut at $path." -Action {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = $powershellPath
        $shortcut.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$uninstallScript`""
        $shortcut.IconLocation = Get-ShortcutIcon $powershellPath
        $shortcut.Description = 'Remove FMDK Agentic OS from this PC (asks first)'
        $shortcut.Save()
    }
    Write-Host "OK Uninstall shortcut written."
}

# ---------------------------------------------------------------------------
# The window (AB#232839). WPF from Windows PowerShell 5.1's own
# PresentationFramework - nothing to install. It lives in a SECOND runspace on
# its own STA thread; the steps keep running on this thread, console-attached,
# so the two interactive sign-ins behave exactly as they do without a window.
# Every update crosses the window's Dispatcher. If WPF cannot load (Server
# Core, a locked-down host) Start-InstallWindow returns $false and every
# Send-WindowMessage below is a no-op: the run is console-only, exactly as before.
# XAML and UI strings stay ASCII so the file reads the same with or without a
# BOM under `powershell -File`.
# ---------------------------------------------------------------------------
$script:Ui = $null

# The Hive AI mark (ui-react/public/brand/hive-ai-mark.png at 128px), embedded
# because nothing else is on the machine before the clone: the mirror carries
# only these scripts. Regenerate: sips -Z 128 <mark.png> --out m.png; base64 m.png.
$script:HiveMarkPng = @'
iVBORw0KGgoAAAANSUhEUgAAAHEAAACACAYAAAA8sIZsAAAAAXNSR0IArs4c6QAAAHhlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAADYAAAAAQAAANgAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAHGgAwAEAAAAAQAAAIAAAAAAnJz2fAAAAAlwSFlzAAAhOAAAITgBRZYxYAAAQABJREFUeAHdnXuwZVdd5/fe53Fvdzqd7iSd7jw6D/IkPYRH4mBUNGgcZEoFpBK0HLSGQYxYcXDwMdb8MdRUTaljGcQRShiVwhellAgyxjLDDCpDMmAQAfMmCQl5kmcn6XTfe17z/Xx/v7XPPvd2x3TSCR1W33PWWr/X+q3fd/3W2nufc2/X1TdZmVVVveeSU7ePVpZe3NSzc6umOkb1/aNJff1gdXrjpr/6yoN1VUnsm6doPt8c5drzzx+cedJjr6jq5sfr2ey1TV2f1KurfpUznFTVaDqd3TGrZn/Znw4+9JdL13/p0o9UIr/wyzcFiI+94Zyzqsn0bb1+/cPNrDpxrDybzgQX+OQMa9Ug2qgW/Y7RrPrD2WzywS0f+8qtL3QYX9AgPvGDp22fzJYurXvTy5qqOXcqeCYCr4NdC2IXqL6QrKuZErP6slTe9/ik+ugJn7j5wa7MC6n9ggRxdsmu4aMrk+/Xdnl5v64unFbV0ijBK8fduomtIdAFzKaa7Z1U9d9OxtPfuuXuW6664PPV6IUEIL6umdrh7f67qqr5968/5+TepPnJfq+6TBvmltFM+RfJ15nNbP3EDjBTtte+9lpVD41ns99cGVW/e8z/vPke9YvVwzsoLyQQd79m19GTpembBrPqp5um3qWAV2yfUbJeAOrpA4mNnoBUVutKZ/aFata8ZzTb9/GtH/vqoznAYV0tTPtw9HT2AydsfHB69KsHvek7m2l1Ua3LTrKPUtdPBSKJWfg5s6cx26H26Nl0NtFl61XNrP/rjwweu3rnR+7amxYOy+ppTOsb4/dMtwwP7thz3rAaXF431Rt7zWzT6iRzz14r07Je2PkWZnRw2VhmignAnMyq3VonH15Zbd67dc8NN9Z/U42LzOFUL0z5cHBMuVPf+wO7di5N+j8xaGZv0Xl1wsp0XM1aT8vWiWTJtk7GtXIxm2eSjSUObLGDpqrGk+md9az3/id7ez+47aN33Fv4h0u9ZsrfWLfu+I6XbD3qqP4P6bD7mV4zPY878QlbZ83LP+kgAAZwTycbUVqY6EInTT5FNdAgqMxms2vHVf2eyROjTxz9ydt2P4XK88o6yOk8N77dc/75G5e2zV41a2Y/15/Vr27qaW/Vl5xsmZllAjIAw4c5iE8nG8t22062bRzEfDTkUJeyuiJe1YF51Up/csWxD0+uqf/mq/sOwspzIvpMpnPIHOFR2c7N03P7g8HlOvMuaZrp5lXdgXONWFInQAS0bjYiA02VXvMtE3rQolHek95lPZOZy4x2V4Opp0KPKDP/uBrP3rtp4y0319/AR3jPZColMs+mrh/87gtPmPQnbx3W9Vt7VXXSKhf3mWEBSoAGWO2WqcvTucOAyMs/8gWgeKnMhaJf6NmzyDqZDvOpmjlET4PoXpXHe7fpKdH7907HH9r+F7ff/1SqzxXvmU7lGftz+0Uv23Jks/H1VU/nXjV7+VQZ5kdlbJcEWw8/A0S123OPyNFfk40tH3dShua6WcFbW3TOPS25tXrqd8xxXjLerJ59djyp3n3UrL6y/oubHt+P1nNGWjeN52qkr1144YZmY/Mdg1n9s7p6/15tk/2RP0RI0JxVmWktkGuysSuDo4DqmjiWyKpeN6vCC3EE1gNYeNRr5QsPw+t5UAfcX85mq9NpfeWoP7ti657p5+q/+spK0Xwu63XTPdSDvUu5ddm3fdu59fLwp3uz6Y/0mvqo1ZluGfSvFljakDykzz6BVNNvQRS/zTZks2851Eq/4FZkbLLzBr2Ufw7AIke9qBecLq0rK7cVTS5+xtP6Yc3kDzTH9x355zfeIvKBlRZNPKPecwriQ6987ebVpdU395vZz+ue65SRwON2va7zwgUwDBJXnsxTL7ZVedXtM7N5HxnAzrJ2izUZmSJAjW3KwQAYGuvfi631nKDUeoSnzGwa5nrLeNr8yu17HvqTl151/54DaTxb+sJUn62xon/LGa9d2nT86OKmbn5RV3Ovmgo03+/lhUntbTC2ylq0tdlIX09pFHICBiCL2Wqgy2AtD0IJMDpFoNAPBYDFZhmn9EvdGdRA4pFpn9Ty/dWjmsHf1R+5brVIH6q6M+qzN/mpiy7q71rZ8JJRr/oFfQD7Bt0yLK3OuGXPTHPWMC0yEBAJhtq5rcY5BQD6cEiezbMvQIwMhI9+CWT0idVTnYtPfQYe7NzL2F29Tii7TbWXeIQ3rfdO6urD41717q3TG244lLckneG6Dh1cmzDe/crXnlg1vbfXdf22ob7XsjobCZ4IcNk+47wToDbfAdKgAHYCR1/Ac1O2kI1SdN/yCayVWBD+UY8AMy6MxfLcAblmsNIttZzR7iowm2p1Wt0/rabva8aj397057c+IBEcflalHeaZWrlu10WbNm04+kcHg9k7evX0nPiIiDOP7ItAR9YRaMCRz+22iv9xPq7fVkv2pk5rC4BYAOjyUqFt23SSvp+ZHVoQGWs/pTtu21aDthzgs0s+jJ7Usy+ujusrttS7P1I/y09J2mH2485Tkjj3ljZvvEin+C/pact3cYyvAhwZ5IBmTfCZAxczCrCD76AjW/pFFgDm4O33bHQ8ErQE1o62DwIONxDtcMSSVaQf3riK1fZKYP66X41/+bZx75pdz/C8tMkY4em9f6q6qH/GK44/d9ZM3ynA3qRVFeeewUoAyAYABSxA8ZkHYJ0ts9G55zmEjIFvbzkKuNRlUYRNvCwLoWQ6NF/8yGBsv/Sxu1ie10xsI2uncDqcaYHklqT2Fqus3DOb1X80aeorjlz50lcO9rxsh1qc7voeIbzhxf9mx8bl6U9pf79MH9FsW8mLlgigAk4Wdu7xWgAAz3MBEF76KaBrqNJm1AA8LmwCCLX3ezYyFqZUWxEP8SHB2w+IFnvaMw6zB/1e7LegeVQc1SuZCWT0dF7qwofzUkfR3at19d5mvO9/bP7wzQ9JY/1K3I9DZcj9sOakL27/V0dsPvH4S5vZ7J0CbxfPOae657MvmW0OuINIcDOYzkZlIr74VoJ5EHSyVFXeXpBZloFXdItMsWFPxfd4krcsscGeCnxk3QlA3VzzVuK4hnxoujG4/MiGK71Rt7TomwVDC9EC4vcFprCsptPeFya92X97dM8DH3863yoIWweYwnW7LhkuN0d+Z92b6X5vdjHBHiv7YjubgxGZxKLJ4BJoAxNBN0gEnZdKXK0ii1yAXNq24W01sxcZAC3gZt/2GcN97GD4nwcxxuf9EJcSSdfZKW1qQOz0ddeaPlOXF3I89elV00ZfEuERXjX7tS1LzTX1Bz5/wG/hSWV9mVWX9K5/6ZZzNk6n/0EXLj/Sm1UbRvomH5+ul4wptQNnegDWZorOPAqZEiDjK8GGPge73T6RNX8OPFeuXsAGq2zJAXy7SLpbasl270IJLE6sKba5hvasuyWSxbj7BMbBCfPZNoA8o6OYljKQODtM1harbW86rR7Xnvf702nzns2nfvbW+l1l67FYyM6b0brhnB87pjdYfrs+nH37oFft4GZd9zUBnoMkAAiSA0tmRVDDvwTSIInuixfVXRmDW7JQIDFsu60yJ2zq1WYeiwAbqltajold09BRQdfxKGMGeX/v+HvIStdWMVxqwCrtrANEjW4g7bD9FiHqIi9+TxcgnJej6exrfKXyyCNHv1P/xj8ufAuvHZ6wfOW8t728mfR+Q1ecr9KDMm2dJYBwAa8TXAMzB7R9yoIMQW/lWQAqbHVlu1sLJALm5XgGI4EGvGKvzW7ZL+3C87jYSZ9Kn7H3U0qc9sM6eFIbRTU8l0JQbRBlsh1QEJJscbXWkUeXF8PP9cq2OxCQfOdnVNVX9Sezdwx/5//dKCkFIlUI+c1nve1sfcL+Z/2mOXffdDXHRCaDSbDcTpBoY4OgtTy2vHk/2sgDZJEtoOR2i6622NhF4M1l46EA/DmtFnieZ8leZlEyFOC8GyGvgp4bdJ7DUsbwYOrE4OFLl6Z2dJFJudw+2z7Kmb2Wpa+fwt/Y71f66srfr6xWl2z53avvFGvmKV9z0r/bWveH/71f98/dN+FbebqMUexSW21B4K+bUUvFasAS7TlPH3VbFrOYT3nstf20NZOsinXVjq+SMm7KIj9ljHDTtdrBl6Lwsp9UjENtf6ilQwlitJ+vdw+tt1LTKG0DRz9pJRsTNAuWtmUUx1ZHE5D8k/oe5bDX+5b+oPr1m97y7ZuYVu+66pLh5hOPffOgqS/fNyWTnMBo6EUUWD204xXclHEG0i58xDp6HbrJZsOPEnazbVmyuOhjSu2FMYASWtGRfylf9MzyW8paVFqpE5qH8L3YNSB09LLf1IyTfdX2AZBMFkBe67ngkeMBa+rG3FFHH3rKSZ/f+ur3m3OPrKc3/NArjruhGZ9+zBYdmG/395Mw5FVNNkjJ2UJ2eNTkpQwZ44wE6qA5M6RPprYZ5b5IU5yALr6+m0Ed7XDONqA7w1TLpmnTyFg8CH1VylDNyuNApbQ+QjdfY5mBbOG7eejfHGjMxliuaBZgAa5kGHHVLURc1DB3ivh8CJkARg0Z2aQjk21CyAXPrNe/7PSNkyOawfCIlzZVfe7IwRMX4QRtEZwcjOAXLw0WQV6kaTTZACQCiU3JyGaAHgAiY34GPORDNoKPTvqDrP1i0kGj74WWi8NbvH1LP6ks40a0bbj0owZ8v9SFvR+RRYVuz67MfbJvLaBJb7NLil1QCmDEijv8Di+yEFrOv10ESZPsivBSdUFvdNSL+9qtXtfXc3U+OhLZ/7yFeWkrUBLQb97C8mR9C+BgxZQJJS3oVkGQknoRFC4wACVkalaRhBnNOPkqGL6+8SZ1fe1UGKvtTJcuQGki+u1DaQCoatH0/FYDaQl6wLRNMDgwwym13Wjr8DG8sprfsDCnFY05fz8tVDwWdXhgKTdLsNWxXMa1ZFULTuoa0LBn9dJHuehgvEMnTku9/nB1UL2yL9+/I77xwpfwAIQAeGTpaDpqzwQQK52+A2uAsBpTj8Cy5zN9rjo1CQCTGQOVfeS4YvSaEKgGo2QrV6jOWL66iGHGQzZAwQW2If12b8gFwf7WZDMrHjVf8UjXSPCWC8aBs2XLRXSz6RGZ87zE0pz3abUSNAygGl1iCbjHEgOXkLM8svmC0MqmYcsVvmgtXzTks1JH7ZgrkdBznW8XiPWypyahWKUC0xEAsNANb5hWbGKEym0HUobIJNm2Pvu9+ujEosCGpD0xDZugGGCuSp1d0na2xWIBaECMRSAgHQ2NrccXBUgmUnOQaz4BHMtFxap6gyF+PBHS+EySxSfpMis1slhTbXiF7xklH1pwqL0YGc1zgqLSbptpy3HmLeXWAZg66JqXNfItgB0e88F0O2bIaUbDvsIfF/vhpwUDzMgsTwlQMKAOgaXGFlniBwAKqLdHwFegZ5qQgTO44ukfcjMyrWSc5QC/L4Nkn2cd9tRmYQAkA9Vss5Jymxo7zngcSrDbccWCLP88Zjocuwp0JgDPFt22QrYMfssL2WBlW5Vtt8EUFwAJvKzy0wKKogFJAGC635EpdliUhdfSJEfW2bTfIMgGvlOLp7AqggQMx1i9BCwFBEhpIkN2+cCFaJ6AcY3xApJYDKoM0O9VeGyypNasw2oCyZZoOdE517yMtA3n2cfZ6K2VWx4SW28BZNQY5moXjPXJigZVW17gsO3GYDGm2ywjFgyKTJP+vJgeDIwgEMys5n0I4ivIrZQzUI5QmBNNgyBZt/VGvwUo+9D8sqL4olueMTo82yoySc9ujDdTGnilikpE5FqsVAUjV7BpVirbJEMwUATG4wGSBotAM5D0DaSbXiBso8DKJxjOSPcEoC5iZjyF8dZKXy+2ZAddPPX56oaBFG0quXiqgwuMK35uq4DIhRil9u7BmAU8tXHb41qCNxV0qP0m26EPBZ7pwUoROkEgZF40JrnT8iIb6UIvtRoteKUtXguw5m3Z5IkV8qWGDpGihjNxWvUJrO/ZmCwCngMrTQ10mCETc4DYJmlKK88tzFk25ZHzNgaoJBlzcLCxEaD5gTf2JKnfgOoAmUArA2d5tno8XbjwuG0GgGyjmYXsGgUY/LDXLaDqo2wq7zgTc/L9KdOCDd0lCOGV5CgA4Dqqtm0gguHwYMm0NGrgkuZMVRugrJJgI4/51PMuZzBTDpulD6nYt42Q4SqfljIxHZVFwHERJybNSif49BEnaCkT6AggMy0TXkUYDCRe+sqRTEOfMKvtWwiCyucj+uMlAKktM7Imsy7POFACuJl0nJFsvQZeKmzZmOGMwIQyNvxMd0wTnQlkCX+j73fPVUyCRNH8OlyRCx2eJUK20BVoA+m+5tsBJrJQSi0Yahc93xtmH5pfdqBjgzFlsOh0ZExigWhwZSLgoawZF2ERfKGBbbKH4KuNIDAQlAA32ugSPE9fQUAn9LM95ejlnKMEWOX8iy1YK8rbKL4kaLoFMXjS8PkIkJyN1FpAuBqgEzX8wHr44HWmyQcfNv6GhKdqf0V3CTm4Mbfw0ubEt2WbzjHcThlnmYTkDJGpy1MXlAFuLXjWlb9demlbB1u8mBO1Ot2XaUmnbRDJRLQ0wwAJTjiLricPn6gYQLhm6F00r1qAQj8AswU5ERdIBE+TA1RnHzLcRwpIpRDAxbaZAJXzT9db3ezTR9xaasrAlI9skh9aX1wLYYd565NwTUxE+VPONrmdvuI7bd7wPmZC14FS5Tm4z1sW7NKUomNCgxjTCUIwlVmeK7IG0ELWcx+loleAKzYW+piTYDg6r1kgQYxh0QVElbg6xU1vq8zY2sLMrrs/B0RdR0XBT9R9hWr90I3MBTxsEqgE0luiRtRZFzJl0iXDsCmnfP7RJuukywYhZ/ULcOrzj/CzO4jud/q0CighAeC+ZJcPAQ4Tll0rpV/oqx92sCnd6AQtYhQCoqMVtwFFSTUyBkO1/DSQnX7wZFdAxeM0dFNPKr6IK33rJR8P9OMXYMFjfHkRNukKvp4ubLyUibeZrGJEU5kWQaB2phEQ8TLADgoEfshKR1wdg6eM08C+CCJ4bIXI+KpVzqTMTFttXLQwScaKYOIs5ydZyzjzq1d5o4CQdQSmEVgEkqtY6rhSRbcU7EXPN+n2EUqhRSuuMudaPvKZKy/LqsG4gAEJ8GLinidzNYMsgleyyX14yW956stW0LOmTymguau3pMciCBHb9x/eaTgTI0heZYFQAsXk8YsB1CgrWrVDgFOSJ/CkSwAtD+GbhiY2WP0ag+DRl15cjKjtbVN8WFyc5FbLfabPUC5i0Pc2qREQIaDiExsKovVI3/+Rrn8PCTsSbPrKCoLhGUjLflnF03FLspJ2HL1zBFv+6UGkPlf1AnSgJcPVsm99sItOxgVrDJNjGWhYBbzUD1BTxzQLSS9r25Mhu9ylpU4Zp3hf5HsTrk7lQAkWAvw4qgRQrIgcLbGYNEGi2+mLAA+ab/KpAylmk9kBO4CdaYJxjgKk2hhUJnmVG0iRfYZyVYsfsgdd20dc7OC0uvoKdb1hqRqec141OH1njIW/o9VqdPNN1firt1oXff/Ac5Qk6gWGFbFMZz6efNX/F+dXvZ2naLihBKWjOcweebAaXf8P+ktw+g01iTEHSu2rTDfDdAHTFzkISI6AAxZjMx0DAC35GLQ8stA6MmqGrogtHaI6jKUQajuVgxqI6SET80UBSvQNkBj8QyD66Kmvn/lWKp63ywDHTAtIqD3rCBWWBAoAOQO1XTJ6uT8UN8DSni8vfQ7jp752Z3Poq1kpW/o7T642/fAbq+VXni/CvOy98srq8T/4/Wr26MPSi/M1uGUeRJBx58UZpgU8vPC7q6Xvek1VbzyiZY5u+nI1vudOgag/LmVgxCKIAELBnIFSrfF8yhTwErSZgJo/HCDGUipg44mzUvq2qT4LhOIhkKftTtQer8eFjYjeRgOaVsGZhgVN2ooEUMFFnAgawACUeDILzBOi+FSBVgBAC04AqZ4zPcH0WaaxZdMuqy7nYjy9saZsY1cXQQ3A6kt82opnmuTwzDOrwWmniLZY+qedVvVPeVG18vCjypbYVZx9MUjsGBqR0RwWFpMKofAfBWOO3cJOAZMtleBnwP2cuICHIdOR4yU506Cjp45fKVf4ZVEs8NFFPpyYb9/0RUTXC4AnNt6u5sLyNLUieFYQyRALOAOoXkCufpuNTBJB2WKynFtqB19gQib3FQyfLwLStxnaXwy2eFxnNd42pSe+VLStanHw2M3A53bKI1+dW/1tW6vB2WdUzbFHh8+d997OnVX/rLOq1etvdMayzbNMABK7eOOZKha0TeMIcCsk4MyLaAq2z3dntjiICSzbxY7BFJE1Y1nFyWBGP/hqO/jYy1fRsyxGVWgXcEuf2jrUCaJirWiwGgkaEpRogE3MTA3ZMwBS8BAtmLAQJCAFWAXcUsUAAGI/qTjB1Yh8iOepPMGRD6wsAThVBNr7PvY3URiCbchbsJ/caDwthv6pJ+ssPEXzQW6xNJs2VcMzzqz2bdtRje++SzFh08G3kF04E00KAGM+6+05eM4cENLCk4gBYq4isW599VvOSEww1wKMg48sihbOOmUKzWOkrm2LTyn62Y2+Bu7rwsafBojh1WQBgu+4tW8xMSkAnv7ZY9VxFkpJwSk3/PC6V6yGVuD4tsCLgAyUDV9x2mTYJHOZuMC2B1zwODMgMXHGwCXedPO/vEFZqK30lBPt7/7e+qedKpBfVI3vvVdjxnaPnO2Tld5Co2d+zq8Avd4ma15x8Cuj2WaV7BIiEG3POdGMWaEpkgK1BR8TzJkFKvDAyW8toMSWV3pCgErbAKuvOHKwiBGrMLIxJoWawZDwnB7Z5GiKH9snweUgJ7gFWLU1OBck3iqVBdwflqcpEsSqs0n3ApJjfIFrYHXBwwYBDf+JAjzcMsqi66e3fXs1POu0qtm0UYz9l/6O46rBWWdWK1/4cjX1VSXbMb7hAQZV5Lfj4rfgRbKaEDIhKFnmqZ3C55tsAIiDLFmAoxhA+eztUH3xObsNHCIWSz5TK/rIw+wsisLzGOJGX3VXVoHhQ2HNQ0CWSeUkPU32CBcmV0CBEAGIjDMcSYMer0KNpaZRWCjaCuMWRBcoOO8ZARpZQp+nNwGqR/A2yyM3FYE54wNlanXZRoennwQniiYzfSwu/5vN/jqmhAbV4EWnVb0TT6qmN98sE8yTUWVBwwGkdxPTRI2B1HMD0XnBX+lzYeVtM0GKzJK8+bJInFBnW2QQbsghWB4bGtcy0OnrhRy7Ajq8oFNcyS8WQZJMc0cEtmZA7D5MbjUdwTUrVMKmSNeX/BECqUQgVLkdgcnMsQYUCl5Ilqs8rjCVaZxLPLEhQ+PMVACUsQQzwAofplpMAR0+izYcVMNzdfV5/DZb5m36+JPVnr/9XNVTZm589StlIGbdP3VnNTjz9Gp02x0eH19Ym3BZWPTZVh1YE6HIgTXFnvDQQr7HrQJG9BII1i2ZCCioA5yzSu0CjHkdPvprM8/go4ONtINezsc03uAh68du9NqME6MUnw/qKGihgR21DSYk9OAkSPAACRGPEPLdR3Fs2yyaJi9svIAMpFRx2raVedwTsjLZUtXm6pR/9URCysaeL1pO5tslUooyvu/Bau9n/6nqH3dMtfSKXVVvy5Fm9LZuMYjN33+pGj/0kIbxQJoy/rID4K/aNHhpnHCG9mJxJvsCiTNM4g6uZMgIComuuASoCMigk1801b4Ag1ZAKaBCY2zzpFfsYtMLgAYFewhm8bjl6tSBZ9DCVc2KZ3IQk248mSSk6Mhh9R0DhFjRAMmkCA2CZJfAMygEjVOSK1JtS85AiRJMZ6CA0oKa2oba0vW5i0ikpxpyWhk4fNHxUNuyevu91erNd1XTJ/ZVo6/d14LI+ANdxfZO3lmNH3xY8vhGwWk7jslCUTN8dkCDnO/QQaKci8xVfhskWStbXmZWgExMpYcMdQue6LhRAIJnuaxLX12XVg4diMkwncdu3UmBmQsNBdCrVc2WHmPRDxLvAYxXs1cxjmAEMOEz2dgm2fd9oaNhDQ7rAUck5w+LfYEEkGxz8cCc2454SE4W6/no8nK1xFZ69GYGcZnu3lOt3Hp3NX74Sck+XI2+el+1tOv0sC2J/knHV0tnn16t3nBrNdUjuXZrFo9NKOKSM8KfEiRbzze2R2+nQoQnMkhJ0XUXuAKAAZMQ2ZIAsagNusZoL4oYy/qStQ7xy5ddkY66Lc2d7HPe6jpDZ6Il5ExMgqCHlgRptnQUJdW9CGIsAABs1b6KclNvyjK0TbcpXcB4ayS7yDLMs0SZGrIKjG2g0slYX+iEdzwJarYeWW34lrMy8lJTGd319Wr1Ft1G6L+dGT/2ZLUqQCcPP1b1j91ifrNxueq/6BRf0Y7vvEtZowVijvz06LqpYA6J3wFvMUCA7RRtBb49C5lMyTa31dePz06AMTgy3oJVgMUUbdWSsT3L0k86TPjl5UVGXwRfqHGfGBZEZUIxKVfqUdpsdAc+9lQbOPhaKQp+AGwhBLQ94hR00TjbAENgxUdGmjE62OGPs7MVAaz5OIcdQGejQE482cPb4SnHVxvOOxWBKLKzctv91eqdD2p1D/gfoQTivdXozvtbEBEc6n5yICDHd93v6bF2iQMv+44Qc7HPENcU8TgTfXVawMgs83mHIfndZph5smFQxKNvPguUfsjbAWQKjaZ1JEyb0gKbBDstOo8TtQi0r0lY1tnmrMUkukWzNWjQUtkSCVxgmbqph3wsDr1LLj4SCrs+L/P8M5CsxLzQwRdnpbdTQMeO9Ii4nps2mzdUG16mW4Yt8wfTk0ee0FZ6r7dS33NqHqv3aEu94+vV8nlnKHFIEc2XC54zT632ffEmXck+rqkw5/RJ/AKq44BP64p88HaqhUUciKfqcpMeV6yiSTVoEnC2oiYiQBiMoKPfAs5wZFgXvCIrOY9V+uq64AMgKlbyiEkyGSxlwCw1f/NUAy0TDSpGEOct20EXjcwTzSq+P1QmyQlvxSaSWRqXM1IgRwZG1jFW46sCzsXIQCbLTPrbtlQb/+UZc8fUWr3jAV3QKLv0qyS1fj+dAE4e21etfOWeauODu6v+jniuCpj9U0+qBiceX+27fo+saXymoNc8+zS69GMBMmanaD4zX5lq3TM3woYI8vRp80YYM0PdxvfSL9kHYFZAFp18qbJRaLQtB8mdsO02MRcdEDWPPBMzE4thsbrF4DBbiqrIjuiCVFzAEBAZxz52yMAiwqp3tsEHYE1CdfspvGwzRnnIDXzEQoioJTl0hkNdnJxULZ+1I62q0la8cvsD1crXHpEomRuFD3RX9JecV+/8egsinMHJO/SQ4GRlrs5FrpBRwFU17DJzESeihUa3SBC/eRXg7KRkMtg+FgwugMumAaQttQKk6LEIsKWxWgCxK1s4Ao0628U/T7DQ8dNnoh+GSDiWjING4DxqWzMtgpkvPIIXFt0mwxx260hO9ZzGBUvQ/H1Rkj/7fBHYH/62tmNlMf6U8zD9mk56VW/zEdXGbzl18d7wwcerfTfdV00e5TM+ZYh3FYIxqEb3PeosnY3m/x8JNoZnnFw1xxyjcZkDY6Cn7wSQZdzI8yACoNYVxYEzsVzc9JDTy7Xm19N5bN2kQW/7ySs0MggA1Pc5zlmePP3OYfAYB+DdZ06pQ41/0PXrwmSjHrv1tH0BFCXeJZU/AAw56e4iqz5gqsRjK606Z57okL1FwpVkyVTVNqN7Rq9cCYao+rTNzGwkOOqbI8B5ojI44ehq4/mnYrQtK7cpC2+6t5rsUwYNdeWqFexzRlfGk0dXqpUb7xaYj1TDnflkR6t4oAujwcnHV5MHHhVwfOdVPnvlM6XYSA8EInuog6wa7/mQ2ruO4mqes4qYEGTmLt/hQQcQysL2iZx4sMrW2cqISICgU/CzZGGhp01FC0r3JWGKKrdgmR8090wLuXIz7ulDN4ABHkAbchzQT3xrnOxTh6tOtlRNtDwc50YfnQCeK1m5x3Z6RF9XpCdVwxPm94ZspWMycLBULZ1xvJOCOWbyaqvWn4nVKpg8/ERVFRDF7u/QBY6yceWGO3SOrkSgRae0c2jjEXS/Y5ts14sPmbW25DtAqi4gefykGUjpJC+2UAkUGfSdkUnDeS8GMdBBjlfZhiOASffgwZOIv55hhK0hSlvTVlGso9DAaiHR10uDB5VuyDhJ3UaaB9ySQChBBRjuGXE2FoH6jkqefxImoM5OLYC+7g2P+NZTPBYWXTS5zRefW23+7nPUbT1IZvhh//LqNBl6WKD/feq04wXmNm239ygQoIBp5qIFxeICgHUFIUdeHHzPQBJwxFW1ATcgyOvlixTV+uLWHBzo9KVjwOjTFgEd/ZheeNQUV3pDlg6+y4jvE7nh9yqEV0pXTzQHtfCIEUYyw6LLewJqgt7En/kbbWrz4wcAMAEIUgDszyLZO+UT52d8DVGZyGrQFefS6cdWG887QQKLhavRnNEi45/pDU/eLiBPrFbv0n9eqgB50cmhshzXxQJ7Cq7PQ845Z4d8FUDeSYh9Bry9wQcMvnFHmHiy4nEk326n2AzQ2mw2WJItMmq226nthx9zoJl/+9gN6TUlM6k7IU8WNLJ4+6OPejDVo28CKKkJkEJIpPgEH1lsKOt8m4EYowCatirdksRuqwBIr7dxqTri/JN0YbOUoz77qqdHdkunn1jt/dJt/vTDtz/4R2awupwia8dBQEETiD7rSsaSPegR5Ay+b4kkGmcjerywjRw2oh/nt9r0F17IIqNXLpjQB/S0Q4NdRrdWeJRU6mwuNtzzG/NDOUXdheSG3goLkIpM2ifX/bAcPOWwF4fkeDjOBMg6PzNVJHkgwH/sTFAHOzZXm17Z+dyQ8Z5l4XJ/cLI+MD5pu+4ZvxrBVsBwFc8IHlPKKeRo6vnKkJAhSFZp6viLPPGFXsBwW6oC2Tf/gO4tFBkJ66cFH1nzgm4/TGMcHEHHjazDR1+hih3bqV1HSAXvSxEpqYuT6sq0spIUPVjxHgFBILZGTVsGBSZbJ1urAWYMCJJWZvozPmUjj9nqpWG1Ydd2XYgsfhFqdPdj1X3vvaYaf13/EYz+iJ1/qwpHHZgA31+9UJ+FsXzOjmrza87TVerczvDEY/1JyMqt9znj23kSbM+6UNSlKJC+hQG5kh3IkX0E2YFGLoCAHplGP+XUNK1c0Kjv4u029awveXjoYbcdhyZ9+UiFH7Ohb5RCyFQ1u0WyAYeIUmrbrQyWshRmOVuUSV6xZKUOu9hWaSvIqPFslYDxA2CiGUAtaa9sttItG6pN33pC1QwVuCwzPRvdd+vD1e7/c3s1038AzDnaYIcY6IYpJg9NCnxPVQtk/NAebZ/6OkcHxGaTPg05dUf15DFHVWPdbvCVC18Vo4eRztSgmMB5SDaKz9kXYgmWJtBegSr4bZuJtRlIG718yZTlkJfD7XmJjv1AnqHTXpfOts+9qT7Z0d4QQvvxWoxOQa4UjIViocxrZZfg88Bx7ydZsk9RgaNln3zI6ZwAs4T3J7JWTyEUrKWTt1abLlj83HDy2Eq154v3V1P9Bz6NnuLob7FGMKk9MXW9dcklsBB9JJ2Vrz5cHaHPGgGvlIFuPYanbNfnjE9ofBYPs8KOI1jEXIuKYQWbBQlfwoDhTFTX4DBgyAU9+V1Qy1baBRadLrg4UmgGjk7SygIQxQ8TBnoc6Scx9hDBTlnT7XA00zS6QFSnqyObuVu64YcBniNCMAmXtk05ydMdtlT+8dxUGOrecFBtfPlx1XDH/GE3w40f3Vft+Tz/OZrkHEyWh2zJJB8yU3z34hYj6Z/+cs++2x+qVu/eXS2f3QHxOF3g6HZjnx4YTPetSF++EbSFiaQhaCwyNq8EzDsN5HIVClh6hQmyVRNmzpg0eGoUEMtYMP09HHh60e8CyvDQZCfqlEGWpzaaN/sDYrQXS5cg+XlZ6MzJtApqnGkLfUIpSt7kkzAhEDf+/oRffnAO6i/uOqH6246oNn/74m2F/vtJgbG72nvzbgVIwJPJthzOTrUA+KUaD+0hRCcAeq3e81i1qmesy2dtz7FVDfq6wDlWX+nY6uesnHmRZHjvGdiW38SIWwz5jK8EUS9vhwgAmMeiHWM6tg42sqJjHB3JtuPkgjCAtqO3IoMP1kM3xrNbpc2YE/0pqXBWAjl57KwrBVDEXGi0SHRo2SSbaErMFy0tuNKiDYpKN5vTm4NHZgK++LXOwA1nb602vuSYNBjVePdqtecfvq4PfvVXP5fJChXpsRkzV4qvFk3RMDkAARvvXqn2saXu3uuzNqT1XP3Eo3U2bhfIeoheQGitFamsMcQjQYDBdgFFenS9sNjK6QGOHySQnYhSS87ZKZ4zUrLqt3SMMBF4+FIykmgW39Bv28RA34TXO1EUw618W+jMGchRzOZtrVzpZ+0tk0H5kXLqezhtTeVjKLMIBJnFebh5WVl4fNXTltot40f2VU9c+4BIPu3Dbac1UmHcth0JQYtNWHrjgmjljkcE1u5qgy6YSulv1UNxXfT0brinmuhrHt4xfO7lHFIwvuTExQ/ZKj+xjQhAlmAXUOVeuzW3oEm4zTr5I3rJZi+KAjI21bYsA9BmAhomFo/aJumNRaKNZ56JJVskGzOnUQpanRKR6hC6/G47RSTvEDNxDi+V6NNiW1RPWeh7Ra3Cmf4W5GNXP1DtvZX/S1JhZXVrKx59/Ylq7236QFfbIHRsxGglG0sPKNgNQsLvsrty52PVwx/7p2p47Z2OvZUVJIPngzTC8eQ/3VmN9AlJvUTk5LPOrMkTe6vpk3rC5KtTjUNwCbJ+YpuVHGvLWZS1Aw+iEmp5alu3yMCDxlB6KwvCfdGLLnXRY1DanIn6+6f1Z475xA36FOMcLirWFckduHSYbnb665QII0W1Mgd/vITkKM24p0MmAYOo/xYUWcvrChMZ72QEVgFpuBol5tgAZPgKQARS2ytBy+BAQ9fPR7lqsrwq0QhGo09AfL+p/+TKwSQWtisdbArEWvejPALkUyOAsk3s5z1ejE0fHezgS/ZxEhveCsMmj+T8cMD64hmsIsO81QYoqcbWq76aLZDiD+TPaDz5ONPwepXamiKVQrT2nE03WMFYw54Ltq2iEZLeRnFaRrg301s4qHfzAIR7Q4IvMd9GAL76bBhszfxT8sZ543FEMY8ObWzKNgZMySbPW4mxgyeagZSAyFh2kITuAh8wDAyWCW6IxvmLMfroqmGH1TdgjI2uXqaLzziF13ko7nPRoCEbNstZWvqYau17PDkvW6ybGMi1mk+jMJFu8W64SOqys41AAIa6deBkuxNvyztY1iijGRKJy4bfRU+T7CHE0eDpPUDOhcEiMVPCIWQJpCm2Zrq2X4lgEjlfgWoA8z0QTPX18vKQTGQKyqLbBiKcmzm2n8xgj7H1om9ARVPw29sRQEUfGrrI2GyMaeBZIHgjvm3hKdupdo242VfzKYtngoQUn1VBX8YyWi2Q2PQYMVAASDvKvF/4eJK+AJJKmMygs12KPwcXiU5f8bAEcVEJwNQgQDaboBBQp514ZWtTvwVJ/HgumnoOvoy6Fg+ygIuMSj30JbLwbXADjLBe6PIqvhhg+mWO8gWa+gZxOspMZDSoVAcqEZcDcQ+CziAy5hnOa996iGNMQFfOLGZ4ONd++i6JuLXYj9Ood0osgg5BTWcBJKmbDyAZuLCoQOnH4BUZhAk4Ajp0WzDJEtHn+tEPIDCSem7C08tjFboNCpQynvrwczF4TLHML3pWIbP9bTe4WSJ2pbe+/uf46zUOQMGDBEoteqXvjhz1mWdEaRcZ5IouzdCEGpkY7LatWKGLTkkovlqjH9MCPDclR9alPYTtAxXgqDZ48NVX27LIWyfrFhzGjVsIA532LIu8bWkMYeBMhibAPE6xWbbYMi6127jAeKoZT5nOprpYFiO2yKN3AP5i1qxXW0/BiwhxeLRGwmwmRnglqTfqKPOWwTZRsqrBvetitJNn9Ioh0cAKqygRINqqYyzo2vqgJi+CjBIyuTCQoU1gpd+CQte24xwswJcPjVs5bHdf6i7cQ2KXDMWeQGvjYB35okeW60Fk7G4U6D9nBc8YjFLa1N0S/e75GVkaMs6gFLfbDqa2Ws1PPzl5BZdmHpJxVZlKKV/sxNQDKJSjX8DBCP6oL/BYAHG+QVKkzePME8dbIXRs8SptGurrx3QYpY1+3nJE1sm+7KAe+qnjvmS5tNawCSKGeXVKeJ8EOp2ywJvTD0CeC+y3xbihWUYJTzQBcbpezftreEyqFALRVXI7CZZDl8xBQRc7qkNddBH5B6HNOlZ8CKsWw/ahIZP3eqItbpvYBkz4DMObdIut1gZ20mby2gxFhQxst2gRJGpbruFJQN+M338miu/SRg2LJcTJ21/Vyu+PuYaGyXx1g7ogBV/FZrNtQtG1AfiZR5rc3FbqFQXziFkot9sSkWnHCRBjvELnqlYPBBRsdAhi+SgqbECHJqZUAAUfLJfAFX4LEHIGTQ2fhTFue9UJsAuAp7xp4YN9BmD/VhSjPVVpgSliEFRaenTLe3JLt62LdkvoNIL3VBIdYZpyuR1e80gIYczp6rVXoJ5x12XkFDjpEnmDQRsAVIcnHXAgWFgNwkWfANIo4UPXNosMhsjQzFa2V/Q8RoBmHsAUcMgs7KkfPqGjNluqdekzNm8q3HdO/bXn2T44JfjJDqHy3kYMAhJFugh06gXZOb1o2D5vvIgDjdKn644b8WaHpc1kCBOyRcbt6EdWhEq8z42GS+oX3TKuVQl+YSUQVrWwGBImqFKOsRNcjIkVIKlhHQxDzxe6KOmnBdN9aLyQR0VgGOSUtz50XoVW+oGVVbWQmn5/Fa//b9+br4RUSrCjd6B3rKscSPhA9NDqvKcdKI6Q+jmvWG2FT62XPOfSvciyTZlu3hoZRyBAAYCiHx+AKWiyM7fVbTMOgWKckEOXrZA+YNAPR8V3kNGfty2nvv2zvE4t19z4I6ca+4DFGGkjgNVYdpfxuHCh7rzQ8+2HfrVBT2z0ZebP6Gsp/Y+PZ2N+w7otnWZL06hrCiMdXLFG+5b6XpGlLXvdPsEqfUSYdAuICRAt46C4nYB4u1ObOtshqz42RGt11vD9qYSDTkCRV6BlO9qMV0AB7AQWP5HBhwJyAtS14fnYzwQzAWoXh/sBrGn08c9+dNqirY4mq9Px+LPN7smeLwr56/UZtwafl3WYzVmdlhyPZdOhZXPBQJwBMQHpeL688VIp4DiYSU/wnEUOUJFXvcArE0x6GMSoXuhQA0C2FYzIzI6e+SFHsOLpEToBXmunvZ+I7THAxC5jR+Aj2AlCGd8g5IKwnPjOJsZEFn38SRvp8xzwWCw+Ax0j/e+mS8tccF07mTQ3NLufGD+qxHxfgwEDIrtZFnAoxAPWORk7vrYtJUgUs7Kz0C5njmQKqEVBk2xXeFmRnih0SgDQZor0Ld/aARBkGJBgZVu1PoJepNHnkZrpKe9MlM1cCN46Wz6yip1sx/ZJZs71wg5sZGKsWEQ5hnwomW9ZfDONWnaKrbatOAnIiT5frevBb9+65dY9zaXVpau7H5n9yeps9ZNLNd+yxgFeURaAXOgUif3UiybSXCGqtnneCFjSTcNW25jzoOUk5usMWkzYHtiO+m1woZZ+qbG9BtBc2UEvgZacs0d9B5SxghdAYQfQsAuPRQMfeVXFB9NDNwAKvdBBNeyHvGyV+TBXG5Kv7RwYI2Q2bDiiGo+mf3bXE3d87IL6ghFeVK+pXvNIMxlfPq4m1+t3jCCpFEMHvn4JuQO943y+YmbpV9o1r6NbHDd7jW4r27HXtZ3B9BpLMH0WYh4wFmgxfpu1DowF9YZ9QjLPRNtcm0WSKdkX8vSxm3SDEX0vAgNR+NhPQFxDp591TCJoC3MM/oaNG3UWjv5+3DTvPPvYs/UrX7EEpF7PLnz8+2/SV+rfPK7Gn9bv5GoaxtfGPDmkPVCpw+g6WgHD8p036A4mZtCN4padpV9kVCcw8yGLjiZs+QiGdSxLv9CwVfq00eVV+GWFB41f4gn+HDwRYuWTXUr/2ISQK9sguh15A1vGQXdNlmns1u92UaS841F0iy/U0Wbsgf7E2fKyAFxZvUrfefjxLcvLd+oBQwu5RJiCgNz9ff/Qe6T3hsls5T8r0Pct1UOZwThORR2TNanzVngdUtsUrwtSsYOKQU0+dGh+67Qzi0wvK9ygpay3Q9oqanvLMU2Bd53BkB3PIXleJA6e5lbksx/BAyAcYtFgo4CCHfWLL8gsgAIPWU/GcnFGYgo7qd/W8tlnBL7neFmLIDP65p/+ArKaX1vZu/Lzq8tLbzpyaemGAqAMGmrqtryyuvihux594r/qs7qLR9X493Q7uXdYD2QWZ1uxeaNLW2jT0cs0ajeiT7ublclqA0MfmVIzmvVNCDquGxgzRSNApZRgIR/tUs/PGIHnDEx+BthgxcAxZkvHFqXYy0VBPw/qckbOwUieEPC4elBbPjfNSYTJ9l1jlHlq3OUNG3QR23t8376V945Hs+858silK7bW9aOteDaKZ2vp7l9X/enw4aM2f6cWwy/2ZvXFPB/Udrso27VgB8QutE4/fMPJVBcAbgImL35KPP30Img8yfBzyZII6NFGhlfbl13afCEJO/7+ikiWkXz2fYuXutBCFntqowuP20BuAVwHjTH95SbzGUfyai/I008b4R820xfx+HV0f2GKWl+/t76arV3Ppa6G+uP0+q0wXThPr5yMR7+2ZdumaxQD/eLJ/gvTPWDZpSvXV+3+vk/uebh+vZ4GvEWv6xbOSxxwUaMAVkgFrZbVCgdoyKHT1QukYYQVJmV0O7JFp0U8eZ0M0QChbzvYyj7Ba+XYvijw1PaQZFehhWxkFbLIQevQF87K4C3KS9zZjs2SuWmDAUuGwlOfJzBLww36XvX0C/rC2I/u3vPApVuPO/LvngrAsMz70yh6bll/+tiP7mimG36qN+td1m8G21Yr/c47uvhVSgGl0DT3Fghk4DumohJUt0VnFaOjN69iOuVoES/oc74zA10yqGRpyT7onczDdsO5R1aojq8qhoyPQz7DY/zMQLKp9JFvswv9zNjIKLm1JoOdVdYJXmvHfjKGbLM4cyzm39P3aJeUfaPJ+G4lyvv6m5c/sHlz/ZBGizWlxlMVpvu0ioadfeeDb7x39PDn/ovWzMWTavT7+khmJc7LYkIOUrKKutPpAGjEWpYabuvN2UJdDMEofRHNhwRNfdgIOzNpJ91kjJRX8lTNs402fOlgr7TDaPRN9yCLfBtJ3W5GKvPMoibbbCvk6LdnIh9kikfm6dfq9qysjD7QNKvf88mrl39VAOr30J8egJJrvaV9UOXK6sqlLUfXF+npwS8J4O8iAONa52WZL5PPts80+wwt6BGzFAAYzRO5yEK5QvapzPvKCEisYOS8otWXrs8WzixA5YeMoU2GQifLMmMjC+hDjzPL3zxzZoStciaWrKHfSDayaq5LNvrMZRzOyMwyj1vOzJJ5OgO7Yw95bKY7BH395K+Xes0v37l62zW7du1alVcHXSJSB602V/hU9aebBsdt+dH+tH5H0/TPmejCh7+p70UtMU2ZN71iEtZUPOLDWfUKgAgBiHiWB0SDSj8BwY4BSbkEzVtTtsuFQwse9tEBpA6wBTi2P8jefgUGHzK0W6bHyr5thJ3Ywjt2vRjU94IKW15YAIgedIOoYZb0J631l5P1jfsvjqrRFatHbf7Izp21/pbLMy8a5dkX1tPfHP3RE5d6R75dwXmbftnqmNV61fuBs8cAMo6GY0QqggudPpNMGdcEsvQLOCVAojtA6Dvg2FIWAIQCFkELWpyBahuAlMnMaLM1wQVk6yJredlqgQ+7oSO+s0zyCVJ8Wzz18El8Zyk+chWK7/oVgWX9DwLj6eh+Afi+2aD57e3nbXpA843dXWrPtGiUQ1c+VX2qv7Rt/BJ9ov4L/aZ5gxxc0r1mDMCEKKoIUjRUZdsgMFlY0Axity8SQWtBlBw2Cbhi5kWBnoJoUAEFYAEYuvrzixvJlO0VQNAn8F4UuUV2APS42NX4BiTBc7ZbX3T8SADLtsrCaPQXLrhlmFSTvRrnw/t643fvvH3rDfWl+jvYh6hodoe+cF4ec+LgYv2vbL+omL+K851N1sCoHVmocROoeWYmD3DgEbis6fveDRZ0gEEOAAAEwAiiQevwkUVOgY/7tJQxcGmjBTjlsJOAxdZJHzu5IACMfgIfAEqXsRJU9Nk2vcj61Sf120u/+uADR/3drku1RR3iopGfu3Ll0Vdu3rLcf3OvGf68vmh0yliLb6pfyVYINFsmHcPTLNlncOATSFXuIyAgIttQBdCUKaABotoOJEFOgOOSP+y3GWfAdRYyBm0CnwB4USSAkYGMFTL4ML+QwTfGw4+QKQByyzBY5lP36hYt3l958N47/+SlP/ZS/X8Pz03Bvees/NHeP1rZ+fjpnz/tqOP/l6La089Zg3qw5L9nAzD6MVAEHGDoA4Rr3EowYACi6VEHuJJFHLoQKnxnqGhkTvDRRy4zNu0VWqmdzZJzNiOjlyvsUAotbQUfOfEkowlWS8tLAq9+WN+W+MB0Mv7ZE19z9P/e8bIdhzz77E++MfzzUq4+6eoNs8HeV+lBwTuaXu97FeH+mD+HRKBYzfx0ATRoIpqHjNwkiGQMPLLAAU890yWT9Nj66IuPDXR4aRv0QgEIb33qZx0XN2KUTLRuyEfmyw5br+jlCtV0yQ+X9BFeM1ud1tMr9cTlipUjtn3uzH9d6298PPdFXj2/5VOnfmrLcq/3+l7T/Iw2p5fP9AshviUhSwgOZQE4BZVgJoAF9Ha7FPDWk85amjOrPS8BsgMcdOyKZuDV9lVmARx7+NMCKn14nbMRPrcMsWBmn9VB8e4NG6dXbnvdNn7F+XkrzzuIObP66rOuPqFXTd6qLfat/V7/pFUeFPj+MoIdYBF1kQkotTJpDiJ08REh2IAJIMiQcaK1GWhgUsYghEzJUoMPHWAFmm1IP85MwBYNe+aFXE+/rDrU39GZ1JPb9Mvm75+Mqg+96Ce287dZnvci775x5f3V+wcv2/Wyc/WL55f36t4lOjU3c0vip1UFFDw0iAQSMDOgCZaDyzYMmIBYgKVf2gZRBAOLnNqWDRnrkXHYxy7yXVnozkjZV7081NOWZvqIPP3jXjN57ylHHX/zobxlOFhE5O03vlx7wic2TrYd9yr9T6U/V/f7r270SShXsvMszMAKQGeda9EAooCtdgEtMhFA4KdOAdpgdHSdmWknn6q0mVlsJ8ADZZ7GXJ3V46um0+aK3uZ915z2b0/Tl6+/seWwALGE4NMv+fTWYX/4Q/2m9zO6MT9vol9jmjT8wXWCDkoAJekWROhzkAI08Qk+mVRAdiZCT/nOlhoXOgCul8Bq7TGO7fAHDvQ7/LIx7dXXTmfT9zSjvZ84/T+evlsSh0WR14dX4RHeZ87/zM5hM/yJXq/3ll7TP0HPGONjOXnr86lkJMCCLWBxnjGbsoWarjeDAUjiIQ+4BlhtaNn24vCCkBFAVsX9Xl9/nnrajO+U6Pv3TVY/eO5/OvVeaR1WhWkfluXa868djPv1ecOmvlyflr5RT1s2jfwpiT52dWYprAYNEAMQb4PONmhkqAQAirbpILN/nkGUvM9F1cMh4M12S+PDVW/83q+Nbr3x1e969ZqvNRweoSMMh3URmBsnG6tX68LnndpiLxIY+h/48hGeAVIGup6D6exsMzKANNACMDJ3rlMyl3XA/eJQj8r0C62TWX96lQz/+kOPz67+tnfvfFafMjzXAT7sQSwBuPrC645eHq68qe4Pf1r3mLv47JI/5hdZJim22MxCb60tsB0QTZtnaDc7tXX77NNntV8Q0NZZHqQAAAGXSURBVO95cu/o4y//jdPWfSmp+HM41S8YEAnau6p3Na/7vtedPBn3fnI4GF6mD1S3+ItbBZysW2DVX9xqZSS3VZ+LPlv1p6T1nU5tow/p7P1N/YLR75797p36M/1P/5N1fPtGlhcUiCVQ1+26brjv1On3609rXj7oDy7UXzBe0rNKb5W+eDF4ku6chWXLLXw+0egLPNV79fne3+rvF/zWk08+eNUFH7jggN8qK+MfbvULEsQSxC//4Je3j2b9S/W56mX6+oQeGugw4zNWg8g2yhYbYHZpbJ166bfdJ1+u+9P37V2dfPSCD5zN91pekOUFDWKJ+D++4Yaz9EtCbxv0+j+s+7kTJ/rKph6HLYDI+dfT38zu6eJF2/Adk+n4D/Wg+vfO+72zbit2Xqj1NwWIBJ9bksGpG16hP//+48q61yrTTtKr7z+SoGyc1PoOdVXdob9y/JdNM/zQdY997kuXfuRSIf3CL980IBYoeFhw/SXXbx8Nll48mU7O1S3fMcrO+2f92fWTurnxFR8886C+DljsHs71/weO8aOJggogMwAAAABJRU5ErkJggg==
'@

$script:WindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FMDK Agentic OS installer" Width="820" SizeToContent="Height"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="14" Background="#FFFFFF" Foreground="#1B1B1F">
  <DockPanel>
    <Border DockPanel.Dock="Top" Padding="24,18,24,14" BorderBrush="#E6E6EA" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="12"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Image x:Name="Logo" Grid.Row="0" Grid.Column="0" Width="32" Height="32" Margin="0,0,14,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Status" Grid.Row="0" Grid.Column="1" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center" Text="Ready to install"/>
        <TextBlock x:Name="Count" Grid.Row="0" Grid.Column="2" FontSize="14" Foreground="#5D5D66" VerticalAlignment="Center" Text="0 of 10 steps"/>
        <ProgressBar x:Name="Bar" Grid.Row="2" Grid.ColumnSpan="3" Height="6" Minimum="0" Maximum="10" Value="0" Foreground="#A3119A" Background="#E9E9EE" BorderThickness="0"/>
      </Grid>
    </Border>
    <Border DockPanel.Dock="Bottom" Padding="24,12,16,12" Background="#F7F7FA" BorderBrush="#E6E6EA" BorderThickness="0,1,0,0">
      <DockPanel>
        <Button x:Name="Action" DockPanel.Dock="Right" MinWidth="92" Padding="16,6" Content="Cancel"/>
        <TextBlock DockPanel.Dock="Right" Margin="0,0,16,0" VerticalAlignment="Center" FontSize="12" Foreground="#8E8E97">Powered by <Run Foreground="#A3119A" FontWeight="SemiBold">Hive AI</Run></TextBlock>
        <ToggleButton x:Name="DetailsToggle" HorizontalAlignment="Left" Padding="4,6" BorderThickness="0" Background="Transparent" Foreground="#5D5D66" Content="&gt;  Show details"/>
      </DockPanel>
    </Border>
    <Border x:Name="Details" DockPanel.Dock="Bottom" Visibility="Collapsed" Background="#1E1E24">
      <TextBox x:Name="Log" Height="220" IsReadOnly="True" BorderThickness="0" Background="#1E1E24" Foreground="#D6D6DE"
               FontFamily="Consolas" FontSize="12" Padding="16,12" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
    </Border>
    <Border x:Name="Prompt" DockPanel.Dock="Bottom" Visibility="Collapsed" Padding="24,14,24,16" Background="#FFF8E6" BorderBrush="#F3D9A0" BorderThickness="0,1,0,0">
      <StackPanel>
        <TextBlock x:Name="PromptTitle" FontSize="14" FontWeight="SemiBold" Text=""/>
        <TextBlock x:Name="PromptText" Margin="0,4,0,10" FontSize="13" Foreground="#5D5D66" TextWrapping="Wrap" Text=""/>
        <DockPanel x:Name="CodeEntry" Visibility="Collapsed">
          <Button x:Name="Send" DockPanel.Dock="Right" MinWidth="92" Padding="16,6" Margin="12,0,0,0" Content="Send" IsEnabled="False"/>
          <TextBox x:Name="Code" FontFamily="Consolas" FontSize="14" Padding="8,6" VerticalContentAlignment="Center"/>
        </DockPanel>
        <DockPanel x:Name="ShowCode" Visibility="Collapsed">
          <Button x:Name="Continue" DockPanel.Dock="Right" MinWidth="92" Padding="16,6" Margin="12,0,0,0" Content="Continue"/>
          <Button x:Name="Copy" DockPanel.Dock="Right" MinWidth="72" Padding="12,6" Margin="12,0,0,0" Content="Copy"/>
          <TextBox x:Name="OneTimeCode" IsReadOnly="True" FontFamily="Consolas" FontSize="26" FontWeight="Bold" BorderThickness="0" Background="Transparent" Padding="0" VerticalContentAlignment="Center"/>
        </DockPanel>
        <TextBlock x:Name="PromptCheck" Margin="0,8,0,0" FontSize="12" Text=""/>
      </StackPanel>
    </Border>
    <StackPanel x:Name="Steps" Margin="12,8">
      <!--ROWS-->
    </StackPanel>
  </DockPanel>
</Window>
'@

# One row. {i} is the row index, {name} the label a person reads (escaped).
$script:RowXaml = @'
      <Grid x:Name="Row{i}" Height="44" Margin="0,0,0,2">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="32"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid Grid.Column="0" Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Ellipse x:Name="Dot{i}" Width="6" Height="6" Fill="#C9C9D1"/>
          <Path x:Name="Spin{i}" Visibility="Collapsed" Stroke="#A3119A" StrokeThickness="2" Data="M8,1 A7,7 0 1 1 1,8" RenderTransformOrigin="0.5,0.5">
            <Path.RenderTransform><RotateTransform Angle="0"/></Path.RenderTransform>
          </Path>
          <Path x:Name="Check{i}" Visibility="Collapsed" Stroke="#059669" StrokeThickness="2.2" Data="M2,8.5 L6,12.5 L14,4.5"/>
          <Path x:Name="Cross{i}" Visibility="Collapsed" Stroke="#D12F2F" StrokeThickness="2.2" Data="M3,3 L13,13 M13,3 L3,13"/>
        </Grid>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="4,0,0,0">
          <TextBlock x:Name="Name{i}" Text="{name}" FontSize="15" Foreground="#8E8E97"/>
          <TextBlock x:Name="Hint{i}" Margin="10,0,0,0" FontSize="12" FontWeight="SemiBold" Foreground="#D97706" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="Time{i}" Grid.Column="2" Margin="0,0,12,0" FontSize="13" Foreground="#8E8E97" VerticalAlignment="Center" MinWidth="56" TextAlignment="Right"/>
      </Grid>
'@

function Get-WindowXaml {
    param([Parameter(Mandatory)][string[]]$StepNames)
    $rows = for ($i = 0; $i -lt $StepNames.Count; $i++) {
        $script:RowXaml.Replace('{i}', "$i").Replace('{name}', [Security.SecurityElement]::Escape($StepNames[$i]))
    }
    return $script:WindowXaml.Replace('<!--ROWS-->', ($rows -join "`n"))
}

# Runs on the UI runspace. `$ui` is the synchronized hashtable both sides share.
$script:WindowThread = {
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        [xml]$xml = $ui.Xaml
        $w = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xml))
        $ui.Window = $w
        # The Hive AI mark, from the base64 the main runspace put on $ui: the
        # window's icon (title bar + taskbar) and the header.
        try {
            $mark = New-Object Windows.Media.Imaging.BitmapImage
            $mark.BeginInit()
            $mark.StreamSource = New-Object IO.MemoryStream(, [Convert]::FromBase64String($ui.MarkPng))
            $mark.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $mark.EndInit()
            $mark.Freeze()
            $w.Icon = $mark
            $w.FindName('Logo').Source = $mark
        } catch { $ui.ApplyError = "mark: $($_.Exception.Message)" }
        $log = $w.FindName('Log')
        $details = $w.FindName('Details')
        $toggle = $w.FindName('DetailsToggle')
        $action = $w.FindName('Action')
        $bc = New-Object Windows.Media.BrushConverter
        $show = { param($on) if ($on) { 'Visible' } else { 'Collapsed' } }
        $prompt = $w.FindName('Prompt')
        $promptTitle = $w.FindName('PromptTitle')
        $promptText = $w.FindName('PromptText')
        $promptCheck = $w.FindName('PromptCheck')
        $codeEntry = $w.FindName('CodeEntry')
        $code = $w.FindName('Code')
        $send = $w.FindName('Send')
        $showCode = $w.FindName('ShowCode')
        $oneTime = $w.FindName('OneTimeCode')
        $copy = $w.FindName('Copy')
        $continue = $w.FindName('Continue')
        $red = $bc.ConvertFromString('#D12F2F')
        $green = $bc.ConvertFromString('#059669')

        # The CLIs read their codes from the console's keyboard. The window
        # types into that same console input buffer (this is the same process,
        # same console), so the CLI cannot tell it from a real paste and the
        # auth commands stay exactly what they are. Redirecting the CLI's stdin
        # instead would let it notice it is not on a terminal and change its
        # prompts - the class of surprise this installer has had enough of.
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Fmdk {
  public static class ConsoleInput {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct KEY_EVENT_RECORD { public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode; public char UnicodeChar; public uint dwControlKeyState; }
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct INPUT_RECORD { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buffer, uint length, out uint written);
    public static void TypeLine(string text) {
      string s = text + "\r";
      INPUT_RECORD[] records = new INPUT_RECORD[s.Length * 2];
      for (int i = 0; i < s.Length; i++) {
        char c = s[i];
        ushort vk = c == '\r' ? (ushort)0x0D : (ushort)0;
        for (int d = 0; d < 2; d++) {
          INPUT_RECORD r = new INPUT_RECORD();
          r.EventType = 1;
          r.KeyEvent.bKeyDown = d == 0 ? 1 : 0;
          r.KeyEvent.wRepeatCount = 1;
          r.KeyEvent.wVirtualKeyCode = vk;
          r.KeyEvent.UnicodeChar = c;
          records[i * 2 + d] = r;
        }
      }
      uint written;
      if (!WriteConsoleInputW(GetStdHandle(-10), records, (uint)records.Length, out written)) throw new System.ComponentModel.Win32Exception();
    }
  }
}
'@

        $code.Add_TextChanged({
            $t = $code.Text.Trim()
            $send.IsEnabled = $t.Length -gt 0
            if ($t.Length -eq 0) { $promptCheck.Text = ''; return }
            if ($t -match '^\S+#\S+$' -and $t.Length -gt 20) {
                $promptCheck.Text = 'Looks like a complete code.'
                $promptCheck.Foreground = $green
            } else {
                $promptCheck.Text = 'Does not look complete - copy everything the page shows, including the part after #.'
                $promptCheck.Foreground = $red
            }
        })
        $send.Add_Click({
            try {
                [Fmdk.ConsoleInput]::TypeLine($code.Text.Trim())
                $codeEntry.Visibility = 'Collapsed'
                $promptText.Text = 'Sent - checking with Claude...'
                $promptCheck.Text = ''
            } catch {
                $promptCheck.Text = "Could not type into the console: $($_.Exception.Message). Paste the code in the PowerShell window instead."
                $promptCheck.Foreground = $red
            }
        })
        $copy.Add_Click({ try { [Windows.Clipboard]::SetText($oneTime.Text) } catch { } })
        $continue.Add_Click({
            try {
                [Fmdk.ConsoleInput]::TypeLine('')
                $continue.IsEnabled = $false
                $promptText.Text = 'Opening github.com - enter the code there, then come back.'
            } catch {
                $promptCheck.Text = "Could not type into the console: $($_.Exception.Message). Press Enter in the PowerShell window instead."
                $promptCheck.Foreground = $red
            }
        })
        $toggle.Add_Click({
            $open = [bool]$toggle.IsChecked
            $details.Visibility = & $show $open
            $toggle.Content = if ($open) { '>  Hide details' } else { '>  Show details' }
        })
        $action.Add_Click({
            if ($ui.Finished) { $w.Close(); return }
            # Cooperative: the running step finishes; MAIN reads this before the next one.
            $ui.Cancel = $true
            $action.Content = 'Cancelling after this step...'
            $action.IsEnabled = $false
        })
        # Closing the window mid-run is a cancel too: the step in flight finishes,
        # nothing new starts, and the console shows where it stopped.
        $w.Add_Closed({ if (-not $ui.Finished) { $ui.Cancel = $true }; $ui.Closed = $true })

        # Everything the main thread wants shown arrives as a plain hashtable on
        # $ui.Queue and is applied HERE, on this thread, by code that lives in
        # this runspace. Handing a scriptblock across runspaces to
        # Dispatcher.Invoke does not work: it runs in whichever runspace the UI
        # thread holds, where the caller's variables do not exist - the first
        # live run opened the window and never moved a row. Data crosses
        # runspaces; code does not.
        $apply = {
            param($m)
            switch ($m.Kind) {
                'row' {
                    $i = $m.Index
                    $s = $m.State
                    if ($s -eq 'running') { $ui.CurrentRow = $i }
                    if ($s -eq 'done' -or $s -eq 'failed') { $prompt.Visibility = 'Collapsed' }
                    $w.FindName("Dot$i").Visibility = & $show ($s -eq 'pending')
                    $spin = $w.FindName("Spin$i")
                    $spin.Visibility = & $show ($s -eq 'running')
                    if ($s -eq 'running') {
                        $anim = New-Object Windows.Media.Animation.DoubleAnimation(0, 360, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(900)))
                        $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
                        $spin.RenderTransform.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $anim)
                    } else {
                        $spin.RenderTransform.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
                    }
                    $w.FindName("Check$i").Visibility = & $show ($s -eq 'done')
                    $w.FindName("Cross$i").Visibility = & $show ($s -eq 'failed')
                    $nameColor = switch ($s) { 'pending' { '#8E8E97' } 'failed' { '#D12F2F' } default { '#1B1B1F' } }
                    $rowColor = switch ($s) { 'running' { '#F7F7FA' } 'failed' { '#FFF5F5' } default { '#00FFFFFF' } }
                    $w.FindName("Name$i").Foreground = $bc.ConvertFromString($nameColor)
                    $w.FindName("Row$i").Background = $bc.ConvertFromString($rowColor)
                    $w.FindName("Time$i").Text = [string]$m.Time
                    $w.FindName("Hint$i").Text = [string]$m.Hint
                }
                'header' {
                    $w.FindName('Status').Text = [string]$m.Status
                    $w.FindName('Count').Text = "$($m.Completed) of $($m.Total) steps"
                    $bar = $w.FindName('Bar')
                    $bar.Value = [double]$m.Completed
                    if ($m.Tone) {
                        $bar.Foreground = $bc.ConvertFromString($(if ($m.Tone -eq 'failed') { '#D12F2F' } else { '#8E8E97' }))
                    }
                }
                'finished' {
                    $action.Content = 'Close'
                    $action.IsEnabled = $true
                    if ($m.Failed) {
                        $toggle.IsChecked = $true
                        $toggle.Content = '>  Hide details'
                        $details.Visibility = 'Visible'
                    }
                }
                'activate' { [void]$w.Activate() }
                'close' { $w.Close() }
            }
        }

        # One timer, this thread: drain the queue, then tail the transcript for
        # the details pane (the main thread is inside winget or git for most of
        # the run, so it cannot do either).
        # Only this run's text: the transcript file is appended across runs.
        $ui.LogPos = [long]$ui.LogStart
        $ui.LogText = ''
        $ui.OpenedUrls = New-Object Collections.ArrayList
        $ui.CurrentRow = $null
        $ui.PasteSeen = 0
        $ui.InvalidSeen = 0
        $ui.OneTimeShown = $null
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $timer.Add_Tick({
            while ($ui.Queue.Count -gt 0) {
                $m = $ui.Queue.Dequeue()
                try { & $apply $m } catch { $ui.ApplyError = "$($m.Kind): $($_.Exception.Message)" }
            }
            if (-not $ui.LogPath -or -not (Test-Path $ui.LogPath)) { return }
            try {
                $fs = [IO.File]::Open($ui.LogPath, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($fs.Length -le $ui.LogPos) { return }
                    $fs.Position = $ui.LogPos
                    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                    $chunk = $sr.ReadToEnd()
                    $ui.LogPos = $fs.Length
                } finally { $fs.Dispose() }
                # Drop the transcript's own header/footer block; keep what the console showed.
                $lines = @($chunk -split "`r?`n" | Where-Object {
                    $_ -notmatch '^\*{5,}|^(Windows PowerShell transcript|Start time|End time|Username|RunAs User|Configuration Name|Machine|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion|Transcript st)'
                })
                if ($lines.Count) {
                    $log.AppendText(($lines -join "`r`n") + "`r`n")
                    $log.ScrollToEnd()
                    $ui.LogText += ($lines -join "`n") + "`n"
                }
                # The Claude CLI's own browser launch does not work on some
                # Windows machines (seen live, elevated or not) and it falls back
                # to printing the sign-in URL - ~400 characters, wrapped by the
                # console. Copying that by hand is how a code_challenge gets a
                # break in it and the code the page hands back is "invalid".
                # So open the exact URL from here: reassemble the wrapped lines
                # (continuations have no spaces) once a normal line has followed
                # them, and Start-Process it - which does work on those machines.
                # A continuation line is non-space to its END (the lookahead) - otherwise the
                # first word of the next prompt line gets glued onto the URL.
                $urlMatches = [regex]::Matches($ui.LogText, "(?:didn't open, visit:|Open this URL[^:\r\n]*:|Failed opening a web browser at)\s*(https?://\S+(?:\n\S+(?=\n))*)")
                foreach ($um in $urlMatches) {
                    $after = $ui.LogText.Substring($um.Index + $um.Length)
                    if ($after -notmatch '(?m)^\S+\s+\S') { continue }   # the URL may still be arriving
                    $url = $um.Groups[1].Value -replace '\n', ''
                    if ($ui.OpenedUrls.Contains($url)) { continue }
                    [void]$ui.OpenedUrls.Add($url)
                    try { Start-Process $url } catch { $ui.ApplyError = "open browser: $($_.Exception.Message)" }
                    if ($ui.CurrentRow -ne $null) {
                        $w.FindName("Hint$($ui.CurrentRow)").Text = 'Sign in in the browser that just opened'
                    }
                }
                # Claude: the CLI's paste prompt opens the entry box; a later
                # "Invalid code" reopens it with that line, so nobody is left
                # blind in the console. The prompt itself is not reprinted on a
                # bad code, so both counts are watched.
                $pasteCount = ([regex]::Matches($ui.LogText, 'Paste code here')).Count
                $invalidCount = ([regex]::Matches($ui.LogText, 'Invalid code')).Count
                if ($pasteCount -gt $ui.PasteSeen -or $invalidCount -gt $ui.InvalidSeen) {
                    $again = $invalidCount -gt $ui.InvalidSeen
                    $ui.PasteSeen = $pasteCount
                    $ui.InvalidSeen = $invalidCount
                    $promptTitle.Text = 'Sign in to Claude'
                    $promptText.Text = 'Sign in in the browser that opened, copy the code it shows, and paste it here.'
                    $code.Text = ''
                    $promptCheck.Text = if ($again) { 'The console said: Invalid code. Please make sure the full code was copied.' } else { '' }
                    $promptCheck.Foreground = $red
                    $showCode.Visibility = 'Collapsed'
                    $codeEntry.Visibility = 'Visible'
                    $prompt.Visibility = 'Visible'
                    [void]$w.Activate()
                    [void]$code.Focus()
                }
                # GitHub: the one-time code goes the other way (into the browser),
                # so show it large with Copy, and Continue sends the Enter gh waits for.
                $otc = [regex]::Match($ui.LogText, 'one-time code: ([A-Z0-9]{4}-[A-Z0-9]{4})')
                if ($otc.Success -and $ui.OneTimeShown -ne $otc.Groups[1].Value) {
                    $ui.OneTimeShown = $otc.Groups[1].Value
                    $promptTitle.Text = 'Sign in to GitHub'
                    $promptText.Text = 'Copy this code, press Continue to open github.com, and enter the code there.'
                    $oneTime.Text = $ui.OneTimeShown
                    $promptCheck.Text = ''
                    $continue.IsEnabled = $true
                    $codeEntry.Visibility = 'Collapsed'
                    $showCode.Visibility = 'Visible'
                    $prompt.Visibility = 'Visible'
                    [void]$w.Activate()
                }
            } catch { }
        })
        $timer.Start()
        if (-not $ui.LogPath) { $log.Text = "No install log on this run - the PowerShell window behind this one has the full text.`r`n" }
        $ui.Ready = $true
        [void]$w.ShowDialog()
    } catch {
        $ui.Error = $_.Exception.Message
    } finally {
        $ui.Closed = $true
    }
}

function Start-InstallWindow {
    param([Parameter(Mandatory)][string[]]$StepNames)
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        Write-Host "  (No window on this host - continuing in the console.)" -ForegroundColor DarkGray
        return $false
    }
    $ui = [hashtable]::Synchronized(@{
        Xaml     = (Get-WindowXaml -StepNames $StepNames)
        LogPath  = $script:InstallLogPath
        LogStart = [long]$script:InstallLogStart
        MarkPng  = $script:HiveMarkPng
        Ready    = $false
        Closed   = $false
        Cancel   = $false
        Finished = $false
        Error    = $null
        Window   = $null
        # Main thread enqueues hashtables; the window's timer applies them.
        Queue      = [Collections.Queue]::Synchronized((New-Object Collections.Queue))
        ApplyError = $null
    })
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('ui', $ui)
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:WindowThread)
    $ui.Runspace = $rs
    $ui.PowerShell = $ps
    $ui.Handle = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(8)
    while (-not $ui.Ready -and -not $ui.Error -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not $ui.Ready) {
        $why = if ($ui.Error) { ": $($ui.Error)" } else { '' }
        Write-Host "  (The window did not open$why - continuing in the console.)" -ForegroundColor DarkGray
        try { $ps.Dispose(); $rs.Close() } catch { }
        return $false
    }
    $script:Ui = $ui
    return $true
}

# Data only - the window's own timer applies it on its thread (see $apply).
function Send-WindowMessage {
    param([Parameter(Mandatory)][hashtable]$Message)
    if (-not $script:Ui -or $script:Ui.Closed) { return }
    $script:Ui.Queue.Enqueue($Message)
}

function Set-StepRow {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][ValidateSet('pending', 'running', 'done', 'failed')][string]$State,
        [string]$Time = '',
        [string]$Hint = ''
    )
    Send-WindowMessage @{ Kind = 'row'; Index = $Index; State = $State; Time = $Time; Hint = $Hint }
}

function Set-WindowHeader {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][int]$Completed,
        [ValidateSet('', 'failed', 'cancelled')][string]$Tone = ''
    )
    Send-WindowMessage @{ Kind = 'header'; Status = $Status; Completed = $Completed; Total = $script:StepCount; Tone = $Tone }
}

# The run is over, one way or another: the button becomes Close; a failure
# opens the details so the error is on screen without a click.
function Set-WindowFinished {
    param([switch]$Failed)
    if (-not $script:Ui) { return }
    $script:Ui.Finished = $true
    Send-WindowMessage @{ Kind = 'finished'; Failed = [bool]$Failed }
}

# $true if a window was up and the person has now closed it; $false when the
# run was console-only, so the caller falls back to the Read-Host pause.
function Wait-WindowClosed {
    if (-not $script:Ui) { return $false }
    Write-Host ""
    Write-Host "Close the installer window to finish." -ForegroundColor DarkGray
    while (-not $script:Ui.Closed) { Start-Sleep -Milliseconds 200 }
    return $true
}

function Stop-InstallWindow {
    if (-not $script:Ui) { return }
    # An update the window could not apply is the one thing that would make it
    # look frozen; say so in the console rather than let it pass silently.
    if ($script:Ui.ApplyError) { Write-Host "  (A window update failed: $($script:Ui.ApplyError))" -ForegroundColor DarkGray }
    if (-not $script:Ui.Closed) {
        Send-WindowMessage @{ Kind = 'close' }
        $deadline = (Get-Date).AddSeconds(3)
        while (-not $script:Ui.Closed -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    }
    try { $script:Ui.PowerShell.Dispose(); $script:Ui.Runspace.Close() } catch { }
    $script:Ui = $null
}

# ==== MAIN ====
# Wrapped in one try/catch so every failure (every `throw` above) lands in ONE
# place instead of calling `exit` at the point of failure. The documented install
# path is `irm <url> | iex`, which dot-sources this script into the caller's own
# interactive PowerShell session — `exit` there would kill that whole window,
# taking the error with it (PowerShell/PowerShell#8816). `return` only unwinds
# this script, leaving the caller's session alive to read the error above. The
# Read-Host pause covers the other launch path (`powershell -File`, a genuinely
# separate process) where the window closes on completion regardless of
# return/exit unless -NoExit was passed — pausing is the only thing that keeps
# that one open long enough to read.
# Ten rows over twelve calls: the three shortcut writes are one step to a
# person. The Name values are the labels the window shows, in this order;
# scripts/installer-window.test.mjs pins both the count and the names.
$steps = @(
    @{ Name = 'Set up the runtime (Node.js, Git, GitHub CLI, Azure CLI)'; Action = { Install-Runtime } }
    @{ Name = 'Install the Claude CLI'; Action = { Install-ClaudeCli } }
    @{ Name = 'Sign in to Claude'; Action = { Connect-ClaudeAccount }; Handoff = $true }
    @{ Name = 'Sign in to GitHub'; Action = { Connect-GitHubAccount }; Handoff = $true }
    @{ Name = 'Download the FMDK Agentic OS app'; Action = { Install-GitClone -Url $AppRepoUrl -Dest $AppDir -FriendlyName 'FMDK Agentic OS app' } }
    @{ Name = 'Download the Framework CLI'; Action = { Install-GitClone -Url $FrameworkRepoUrl -Dest $CliDir -FriendlyName 'Framework CLI' } }
    @{ Name = 'Set up your workbench home'; Action = { Initialize-WorkbenchHome -FmdkCliPath (Join-Path $CliDir 'framework\bin\fmdk.js') } }
    @{ Name = 'Configure the app'; Action = { Set-AppConfig } }
    @{ Name = 'Create shortcuts'; Action = { Install-Shortcuts; New-UpdateShortcut; New-StopShortcut; New-UninstallShortcut } }
    @{ Name = 'Launch FMDK Agentic OS'; Action = { Start-WorkbenchApp } }
)

try {
    Start-InstallLog
    Write-Host "FMDK Agentic OS installer" -ForegroundColor Green
    Write-Host "This installs Node.js, Git, GitHub CLI, the Azure CLI, and the Claude CLI, then sets up your workbench."
    Write-Host "Already-installed pieces are skipped, so it's safe to re-run this script."
    [void](Start-InstallWindow -StepNames @($steps | ForEach-Object { $_.Name }))

    $cancelled = $false
    foreach ($step in $steps) {
        # Cooperative Cancel: read between steps only, so winget and git are
        # never killed mid-write; the finished steps are skipped on a re-run.
        if ($script:Ui -and $script:Ui.Cancel) { $cancelled = $true; break }
        Invoke-Step -Name $step.Name -Action $step.Action -Handoff:([bool]$step.Handoff)
    }
    if ($cancelled) {
        Write-Host ""
        Write-Host "Stopped before '$($step.Name)'. Nothing else was changed - re-run any time; finished steps are skipped." -ForegroundColor Yellow
        Set-WindowHeader -Status 'Cancelled - nothing else was changed' -Completed $script:StepNumber -Tone cancelled
        Set-WindowFinished
        [void](Wait-WindowClosed)
        return
    }

    Write-Host ""
    Write-Host "All set! FMDK Agentic OS is running at http://127.0.0.1:3030" -ForegroundColor Green
    Write-Host "Find it any time via the Desktop shortcut or the Start Menu 'FMDK Agentic OS' folder."
    Set-WindowHeader -Status 'All set! FMDK Agentic OS is running at http://127.0.0.1:3030' -Completed $script:StepCount
    Set-WindowFinished
    [void](Wait-WindowClosed)
} catch {
    Write-Host ""
    Write-Host "Setup did not finish. See the error above for what happened." -ForegroundColor Red
    Write-Host "Fix that, then re-run this script - already-installed pieces are skipped." -ForegroundColor Red
    if ($script:InstallLogPath) {
        Write-Host "Full log: $($script:InstallLogPath)" -ForegroundColor Red
    }
    Set-WindowHeader -Status 'Setup did not finish - see details' -Completed ([math]::Max(0, $script:StepNumber - 1)) -Tone failed
    Set-WindowFinished -Failed
    if (-not (Wait-WindowClosed)) {
        Write-Host ""
        Write-Host "Press Enter to close this window..." -ForegroundColor DarkGray
        Read-Host | Out-Null
    }
    return
} finally {
    Stop-InstallWindow
    Stop-InstallLog
}
