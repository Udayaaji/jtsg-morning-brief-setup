<#
.SYNOPSIS
    One-time setup, run by the installer from <root>\app\ after config.json
    has been written. Builds a private Python, fetches the pipeline, installs
    Claude Code, registers the schedule and opens the Claude sign-in.

.DESCRIPTION
    Prints one plain-language line per step. Any failure prints SETUP FAILED
    with the reason and exits 1, which the installer surfaces.

    -SkipClaudeInstall and -SkipSignIn exist for the author's own checks on a
    machine that already has Claude Code. The installer never passes them.
#>
param([switch]$SkipClaudeInstall, [switch]$SkipSignIn)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$App  = $PSScriptRoot
$Root = Split-Path -Parent $App
. (Join-Path $App 'jtsg_launcher.ps1')

$UvVersion        = '0.11.6'
$UvZipUrl         = "https://github.com/astral-sh/uv/releases/download/$UvVersion/uv-x86_64-pc-windows-msvc.zip"
$ClaudeInstallUrl = 'https://claude.ai/install.ps1'
$TaskName         = 'JTSG Morning Brief'
$Utf8             = New-Object System.Text.UTF8Encoding $false

function Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }

function Fail([string]$m) {
    Write-Host ''
    Write-Host "SETUP FAILED: $m" -ForegroundColor Red
    Write-Host 'Take a photo or screenshot of this window and send it to support.'
    # The installer reads this file to name the reason in its own message box,
    # and the pause keeps the console readable after the process exits.
    try {
        $logDir = Join-Path $Root 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $logDir 'setup_failed.txt'), "$m`r`n", $Utf8)
    } catch {}
    Read-Host 'Press Enter to close this window' | Out-Null
    exit 1
}

function Set-ConfigValue([string]$key, $value) {
    $path = Join-Path $Root 'config.json'
    $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
    [IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json -Depth 5), $Utf8)
}

function Register-BriefTask {
    # Safety rule: never take over a task that belongs to another
    # installation (on the author's machine, the production task).
    $launcher = Join-Path $App 'jtsg_launcher.ps1'
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        $current = [string]$existing.Actions[0].Arguments
        # Match the exact launcher path, not the root: root alone is a prefix of
        # every sibling install folder (for example "... Test2").
        if ($current.IndexOf($launcher, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Write-Host "A '$TaskName' task already exists for another installation; schedule registration skipped." -ForegroundColor Yellow
            return
        }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$launcher`""
    $daily = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday, Saturday -At '06:40'
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($daily, $logon) -Settings $settings -Principal $principal | Out-Null
    Write-Host 'Scheduled: Monday to Saturday at 06:40, and at every Windows sign-in, with catch-up for missed mornings.'
}

try {
    $cfg = Read-Config $Root
    foreach ($d in 'state', 'logs', 'workspace', 'python', 'uv_cache', 'claude_profile') {
        New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
    }
    Remove-Item (Join-Path $Root 'logs\setup_failed.txt') -Force -ErrorAction SilentlyContinue
    # The Start Menu shortcut points here, so it has to exist from the first day.
    try {
        New-Item -ItemType Directory -Path $cfg.delivery_folder -Force | Out-Null
    } catch {
        Write-Host "Could not create the delivery folder $($cfg.delivery_folder): $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Step 'Downloading the Python installer (uv)'
    $zip = Join-Path $Root 'state\uv.zip'
    Invoke-WebRequest -Uri $UvZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 180
    # GitHub serves the .sha256 as application/octet-stream, so PowerShell 5.1
    # hands back a byte array rather than a string. Decode before parsing.
    $shaBody = (Invoke-WebRequest -Uri "$UvZipUrl.sha256" -UseBasicParsing -TimeoutSec 60).Content
    if ($shaBody -is [byte[]]) { $shaBody = [Text.Encoding]::UTF8.GetString($shaBody) }
    $expected = ([string]$shaBody -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) { Fail 'the uv download did not match its checksum' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $x = Join-Path $Root 'state\uvx'
    Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
    $uvExe = Get-ChildItem $x -Recurse -Filter 'uv.exe' | Select-Object -First 1
    if (-not $uvExe) { Fail 'uv.exe was not inside the download' }
    Copy-Item $uvExe.FullName (Join-Path $App 'uv.exe') -Force
    Remove-Item $zip, $x -Recurse -Force -ErrorAction SilentlyContinue
    $uv = Join-Path $App 'uv.exe'
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $Root 'python'
    $env:UV_CACHE_DIR = Join-Path $Root 'uv_cache'

    Step 'Installing a private Python 3.12 (nothing else on this computer is changed)'
    # --no-bin keeps uv from dropping a python3.12.exe shim into the user's
    # ~\.local\bin, and --no-registry keeps the interpreter out of the Windows
    # registry. Everything this install creates stays under <root>\python.
    & $uv python install 3.12 --no-bin --no-registry
    if ($LASTEXITCODE -ne 0) { Fail 'the Python install did not complete' }

    Step 'Downloading the Morning Brief pipeline'
    $fetch = Update-Pristine $Root $cfg
    if (-not $fetch.ok) { Fail "the pipeline download failed: $($fetch.error)" }
    $state = Read-State $Root
    $state.pristine_sha = $fetch.sha
    $state.pristine_fetched_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    Write-State $Root $state
    Write-Host "Pipeline version $($fetch.sha.Substring(0, 7))"

    Step 'Installing the pipeline dependencies (this is the slow step)'
    & $uv venv (Join-Path $Root 'venv') --python 3.12
    if ($LASTEXITCODE -ne 0) { Fail 'the Python environment could not be created' }
    & $uv pip install --python (Join-Path $Root 'venv\Scripts\python.exe') -r (Join-Path $Root 'pristine\requirements.txt')
    if ($LASTEXITCODE -ne 0) { Fail 'the dependencies could not be installed' }

    Step 'Installing Claude Code'
    $claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (-not $SkipClaudeInstall) {
        $installer = Join-Path $Root 'state\claude_install.ps1'
        Invoke-WebRequest -Uri $ClaudeInstallUrl -OutFile $installer -UseBasicParsing -TimeoutSec 60
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
        if ($LASTEXITCODE -ne 0) { Fail 'the Claude Code install did not complete' }
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $claudeExe)) {
        $found = Get-Command claude.exe -ErrorAction SilentlyContinue
        if ($found) { $claudeExe = $found.Source } else { Fail 'claude.exe was not found after the install' }
    }
    Set-ConfigValue 'claude_exe' $claudeExe
    Write-Host "Claude Code at $claudeExe"

    Step 'Registering the morning schedule'
    Register-BriefTask

    [IO.File]::WriteAllText((Join-Path $App 'version.txt'), "bootstrap 1.0.0`nuv $UvVersion`n" + (Get-Date).ToString('yyyy-MM-dd HH:mm') + "`n", $Utf8)

    if (-not $SkipSignIn) {
        Step 'Signing in to Claude (a browser window will open; sign in with the firm''s Claude account)'
        # The install is already complete at this point, so a sign-in that fails
        # must never reach the outer catch and be reported as a setup failure.
        try {
            $env:CLAUDE_CONFIG_DIR = Join-Path $Root 'claude_profile'
            & $claudeExe auth login --claudeai
            $statusText = & $claudeExe auth status --json | Out-String
            if ($statusText -match '"loggedIn"\s*:\s*true') {
                $email = ''
                if ($statusText -match '"email"\s*:\s*"([^"]+)"') { $email = $Matches[1] }
                $plan = ''
                if ($statusText -match '"subscriptionType"\s*:\s*"([^"]+)"') { $plan = $Matches[1] }
                Write-Host "Signed in as $email ($plan)" -ForegroundColor Green
            } else {
                Write-Host 'Not signed in yet. Use "Sign in to Claude" from the Start Menu when ready.' -ForegroundColor Yellow
            }
        } catch {
            Write-Host 'Not signed in yet. Use "Sign in to Claude" from the Start Menu when ready.' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host 'Setup complete. The Morning Brief will be generated on the next scheduled morning or Windows sign-in.' -ForegroundColor Green
    exit 0
} catch {
    Fail $_.Exception.Message
}
