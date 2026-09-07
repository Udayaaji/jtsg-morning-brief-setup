<#
.SYNOPSIS
    JTSG Morning Brief client launcher. Installed once into app\ and never
    changed by the daily update.

.DESCRIPTION
    Guards against duplicate and pointless runs, fetches the stable branch of
    the pipeline repository into pristine\ by verify-then-swap, and hands off
    to the runner that the fetch delivered. Fetch failure is never fatal and
    never silent: the run continues on the cached pristine copy and the reason
    is recorded for the status report.

    Every function takes its root explicitly and can be dot-sourced:
    bootstrap.ps1 reuses the fetch during installation and the runner reuses
    the integrity helpers. The main body runs only when this file is invoked
    directly.

    Root layout: this file lives in <root>\app\. Everything else is relative
    to <root>: config.json, pristine\, workspace\, venv\, claude_profile\,
    state\, logs\.
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$script:Root = Split-Path -Parent $PSScriptRoot
$script:LockStream = $null
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-RunDate {
    # The brief is dated by IST regardless of the machine clock. The override
    # exists for the author-side tests only; it is never set on a client.
    $override = $env:JTSG_LAUNCHER_DATE_OVERRIDE
    if ($override -and $override -match '^\d{4}-\d{2}-\d{2}$') {
        return [datetime]::ParseExact($override, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    }
    return [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'India Standard Time')
}

function Read-Config([string]$root) {
    $path = Join-Path $root 'config.json'
    if (-not (Test-Path $path)) { throw "config.json not found at $path" }
    $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in 'delivery_folder', 'access_key', 'repo_zip_url', 'claude_exe') {
        if (-not $cfg.PSObject.Properties[$k]) { throw "config.json is missing '$k'" }
    }
    if (-not $cfg.PSObject.Properties['toast']) { $cfg | Add-Member -NotePropertyName toast -NotePropertyValue $true }
    if (-not $cfg.PSObject.Properties['max_attempts_per_day']) { $cfg | Add-Member -NotePropertyName max_attempts_per_day -NotePropertyValue 2 }
    return $cfg
}

function Read-State([string]$root) {
    $path = Join-Path $root 'state\state.json'
    if (Test-Path $path) { return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    return [pscustomobject]@{
        pristine_sha = $null; pristine_fetched_at = $null
        last_fetch_error = $null; last_fetch_error_at = $null
        attempts = [pscustomobject]@{}
    }
}

function Write-State([string]$root, $state) {
    $dir = Join-Path $root 'state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [IO.File]::WriteAllText((Join-Path $dir 'state.json'), ($state | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
}

function Write-Log([string]$root, [string]$iso, [string]$message) {
    $dir = Join-Path $root 'logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $message
    [IO.File]::AppendAllText((Join-Path $dir "launcher_$iso.log"), $line + "`n", $script:Utf8NoBom)
    Write-Host $line
}

function Set-KeepAwake([bool]$on) {
    # Flags are decimal on purpose: 0x80000001 parses as a negative Int32 in
    # PowerShell and fails to bind to the uint parameter.
    try {
        if (-not ('Jtsg.KeepAwake' -as [type])) {
            Add-Type -Namespace Jtsg -Name KeepAwake -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true)] public static extern uint SetThreadExecutionState(uint esFlags);'
        }
        $continuous = [uint32]2147483648
        if ($on) { [Jtsg.KeepAwake]::SetThreadExecutionState($continuous -bor [uint32]1) | Out-Null }
        else     { [Jtsg.KeepAwake]::SetThreadExecutionState($continuous) | Out-Null }
    } catch { Write-Host "keep-awake unavailable: $($_.Exception.Message)" }
}

function Show-Toast([string]$title, [string]$body, [string]$openFolder, [bool]$enabled) {
    # JTSG_SUPPRESS_TOAST is set only by the author's test harness, which runs
    # this launcher for real against throwaway roots. Without it the
    # config-error path below cannot honour a config that says "toast": false,
    # because the config is exactly what could not be read, so every test run
    # raised a real notification on the author's desktop pointing at a temp
    # folder. It is never set on a client machine.
    # Suppressed is never silent: the notification is written to the
    # launcher log instead, so a genuine setup-failure toast is still on
    # the record if this is ever set machine-wide.
    if ($env:JTSG_SUPPRESS_TOAST -eq '1') {
        $line = "toast suppressed: $title - $body"
        $logged = $false
        if ($script:Root) {
            try {
                Write-Log $script:Root ((Get-RunDate).ToString('yyyy-MM-dd')) $line
                $logged = $true
            } catch {}
        }
        if (-not $logged) { Write-Host $line }
        return
    }
    if (-not $enabled) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $launch = [Security.SecurityElement]::Escape('file:///' + ($openFolder -replace '\\', '/'))
        $t = [Security.SecurityElement]::Escape($title)
        $b = [Security.SecurityElement]::Escape($body)
        $xml = "<toast activationType='protocol' launch='$launch'><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>"
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch { Write-Host "toast failed: $($_.Exception.Message)" }
}

function Enter-RunLock([string]$root) {
    $dir = Join-Path $root 'state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $lock = Join-Path $dir 'lock'
    if (Test-Path $lock) {
        $age = (Get-Date) - (Get-Item $lock).LastWriteTime
        if ($age.TotalHours -lt 3) { return $false }
    }
    try {
        # Deleting the stale lock belongs inside the try: with ErrorActionPreference
        # set to Stop, a delete that fails (a sibling run older than three hours is
        # still alive and holding it, or an ACL problem) would otherwise terminate
        # the script before anything is logged. Failing to take the lock is enough.
        if (Test-Path $lock) { Remove-Item $lock -Force }
        $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = [Text.Encoding]::ASCII.GetBytes([string]$PID)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        $script:LockStream = $fs
        return $true
    } catch { return $false }
}

function Exit-RunLock([string]$root) {
    if ($script:LockStream) { $script:LockStream.Dispose(); $script:LockStream = $null }
    Remove-Item (Join-Path $root 'state\lock') -Force -ErrorAction SilentlyContinue
}

function Get-TreeHashes([string]$tree) {
    $hashes = [ordered]@{}
    $files = Get-ChildItem $tree -File -Recurse -Force | Where-Object { $_.FullName -notmatch '\\__pycache__\\' } | Sort-Object FullName
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($tree.Length).TrimStart('\') -replace '\\', '/'
        $hashes[$rel] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Test-ManifestComplete([string]$tree) {
    $manifest = Join-Path $tree 'client_repo_manifest.txt'
    if (-not (Test-Path $manifest)) { throw 'client_repo_manifest.txt is missing from the fetched tree' }
    $missing = @()
    foreach ($line in Get-Content $manifest -Encoding UTF8) {
        $entry = $line.Trim()
        if (-not $entry -or $entry.StartsWith('#')) { continue }
        if (-not (Test-Path (Join-Path $tree $entry))) { $missing += $entry }
    }
    if ($missing.Count -gt 0) { throw "fetched tree is missing manifest entries: $($missing -join ', ')" }
}

function Install-PristineFromZip([string]$root, [string]$zipPath) {
    # Extract, verify, swap. Never throws; never touches the zip itself.
    # Staging lives under state\ because Windows' 260-character path limit
    # bites when the SHA-named top folder is extracted under a long temp path.
    $result = @{ ok = $false; sha = $null; error = $null }
    $x = Join-Path $root 'state\stage\x'
    try {
        Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $x -Force | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $x)
        $tops = @(Get-ChildItem $x -Directory)
        if ($tops.Count -ne 1) { throw "expected one top-level folder in the zipball, found $($tops.Count)" }
        $top = $tops[0]
        if ($top.Name -notmatch '-([0-9a-f]{40})$') { throw "top folder '$($top.Name)' carries no commit SHA" }
        $sha = $Matches[1]
        Test-ManifestComplete $top.FullName

        $pristine = Join-Path $root 'pristine'
        $prev = Join-Path $root 'pristine_prev'
        Remove-Item $prev -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $pristine) { Rename-Item $pristine 'pristine_prev' }
        Move-Item $top.FullName $pristine
        Remove-Item $prev -Recurse -Force -ErrorAction SilentlyContinue

        $hashes = Get-TreeHashes $pristine
        [IO.File]::WriteAllText((Join-Path $root 'state\pristine_hashes.json'), ($hashes | ConvertTo-Json), $script:Utf8NoBom)
        $result.ok = $true
        $result.sha = $sha
    } catch {
        $result.error = $_.Exception.Message
    } finally {
        Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Update-Pristine([string]$root, $cfg) {
    # Download the stable zipball with the access key, then install it.
    # Returns @{ ok; sha; error } and never throws.
    $stage = Join-Path $root 'state\stage'
    $result = @{ ok = $false; sha = $null; error = $null }
    try {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $zip = Join-Path $stage 'stable.zip'
        Invoke-WebRequest -Uri $cfg.repo_zip_url -OutFile $zip -UseBasicParsing -TimeoutSec 60 `
            -Headers @{ Authorization = "Bearer $($cfg.access_key)"; 'User-Agent' = 'jtsg-morning-brief-launcher' }
        $result = Install-PristineFromZip $root $zip
        if ($result.ok) {
            # Archiving the download is not part of the install. By this point
            # pristine has been swapped and pristine_hashes.json describes the new
            # tree, so a failure to keep the zip must not be reported as a fetch
            # failure: that would leave the runner stamping the old SHA.
            try {
                Move-Item $zip (Join-Path $root 'state\last_good.zip') -Force
            } catch {
                Write-Log $root ((Get-RunDate).ToString('yyyy-MM-dd')) "could not archive the download as last_good.zip: $($_.Exception.Message)"
            }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response) { $msg = "HTTP $([int]$_.Exception.Response.StatusCode): $msg" }
        $result = @{ ok = $false; sha = $null; error = $msg }
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Write-MinimalStatus([string]$root, $cfg, [string]$iso, [string]$suffix, [string]$verdictLine, [string]$advice) {
    $folder = [string]$cfg.delivery_folder
    try { if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null } } catch {}
    if (-not (Test-Path $folder)) { $folder = Join-Path $root 'logs'; New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $log = Join-Path $root "logs\launcher_$iso.log"
    $text = "# Morning Brief status, $iso`n`n## $verdictLine`n`n$advice`n`n## Details for support`n`nLauncher log: $log`n"
    $path = Join-Path $folder "Morning_Brief_Status_$suffix.md"
    [IO.File]::WriteAllText($path, $text, $script:Utf8NoBom)
    return $path
}

function Invoke-Launcher {
    $root = $script:Root
    $date = Get-RunDate
    $iso = $date.ToString('yyyy-MM-dd')
    $suffix = $date.ToString('dd_MMM_yyyy', [Globalization.CultureInfo]::InvariantCulture)

    try { $cfg = Read-Config $root } catch {
        Write-Log $root $iso "config error: $($_.Exception.Message)"
        Show-Toast 'Morning Brief is not set up correctly' 'Open the logs folder and forward the launcher log to support.' (Join-Path $root 'logs') $true
        return 2
    }
    if ($date.DayOfWeek -eq [DayOfWeek]::Sunday) {
        Write-Log $root $iso 'Sunday in IST, nothing to do'
        return 0
    }
    if (-not (Enter-RunLock $root)) {
        Write-Log $root $iso 'another run holds the lock, exiting'
        return 0
    }
    try {
        # An update interrupted between the rename and the move leaves a complete
        # pristine_prev\ and no pristine\. Put it back before anything else looks
        # for the runner, or the client is told no earlier copy exists while a good
        # one sits beside it. This runs under the lock because a live sibling run
        # may be mid-swap, and that run holds the lock.
        $pristineDir = Join-Path $root 'pristine'
        $prevDir = Join-Path $root 'pristine_prev'
        if ((-not (Test-Path $pristineDir)) -and (Test-Path $prevDir)) {
            try {
                Rename-Item $prevDir 'pristine'
                Write-Log $root $iso 'recovered pristine from an interrupted update'
            } catch {
                Write-Log $root $iso "could not recover pristine from pristine_prev: $($_.Exception.Message)"
            }
        }
        $pdf = Join-Path ([string]$cfg.delivery_folder) "Morning_Brief_JTSG_$suffix.pdf"
        if (Test-Path $pdf) {
            Write-Log $root $iso "today's brief already exists at $pdf, nothing to do"
            return 0
        }
        $state = Read-State $root
        $prop = $state.attempts.PSObject.Properties[$iso]
        $attempts = 0
        if ($prop) { $attempts = [int]$prop.Value }
        $max = [int]$cfg.max_attempts_per_day
        if ($attempts -ge $max) {
            Write-Log $root $iso "already attempted $attempts time(s) today, nothing to do"
            return 0
        }

        Set-KeepAwake $true
        Write-Log $root $iso "attempt $($attempts + 1) of $max; fetching $($cfg.repo_zip_url)"
        $fetch = Update-Pristine $root $cfg
        $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $fetchNote = ''
        if ($fetch.ok) {
            $state.pristine_sha = $fetch.sha
            $state.pristine_fetched_at = $now
            $state.last_fetch_error = $null
            $state.last_fetch_error_at = $null
            Write-Log $root $iso "pristine updated to $($fetch.sha)"
        } else {
            $state.last_fetch_error = $fetch.error
            $state.last_fetch_error_at = $now
            $since = $state.pristine_fetched_at
            if (-not $since) { $since = 'unknown' }
            $fetchNote = "running on cached code from $since, last update attempt failed: $($fetch.error)"
            Write-Log $root $iso "fetch failed: $($fetch.error)"
        }

        $runner = Join-Path $root 'pristine\jtsg_client_run.ps1'
        if (-not (Test-Path $runner)) {
            Write-State $root $state
            $path = Write-MinimalStatus $root $cfg $iso $suffix 'Not produced: setup problem' "The pipeline code could not be downloaded and no earlier copy exists on this computer. Last error: $($fetch.error). Forward this file to support."
            Write-Log $root $iso "no runner available; status written to $path"
            Show-Toast 'Morning Brief not produced today' 'See the status report in the delivery folder.' ([string]$cfg.delivery_folder) ([bool]$cfg.toast)
            return 2
        }

        $state.attempts | Add-Member -NotePropertyName $iso -NotePropertyValue ($attempts + 1) -Force
        Write-State $root $state
        $sha = $state.pristine_sha
        if (-not $sha) { $sha = 'unknown' }
        & $runner -Root $root -IsoDate $iso -Suffix $suffix -Sha $sha -FetchNote $fetchNote -Attempt ($attempts + 1)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        Write-Log $root $iso "runner exited $code"
        return $code
    } catch {
        Write-Log $root $iso "launcher error: $($_.Exception.Message)"
        return 2
    } finally {
        Set-KeepAwake $false
        Exit-RunLock $root
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-Launcher
    exit $exitCode
}
