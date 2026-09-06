# Start Menu "Sign in to Claude". The single sign-in IS the connection: it
# writes the credential into claude_profile\, which every later run reads.
$Root = Split-Path -Parent $PSScriptRoot
$cfgPath = Join-Path $Root 'config.json'
$notReady = 'Claude Code is not installed yet. Run the installer again or contact support.'
if (-not (Test-Path $cfgPath)) { Write-Host $notReady; exit 1 }
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$claudeExe = [string]$cfg.claude_exe
if (-not $claudeExe) { Write-Host $notReady; exit 1 }
if (-not (Test-Path $claudeExe)) { Write-Host $notReady; exit 1 }
$env:CLAUDE_CONFIG_DIR = Join-Path $Root 'claude_profile'
Write-Host 'Signing in to Claude. A browser window will open; sign in with the firm''s Claude account.'
& $claudeExe auth login --claudeai
& $claudeExe auth status --text
Write-Host ''
Write-Host 'You can close this window.'
