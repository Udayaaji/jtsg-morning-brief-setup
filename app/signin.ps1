# Start Menu "Sign in to Claude". The single sign-in IS the connection: it
# writes the credential into claude_profile\, which every later run reads.
$Root = Split-Path -Parent $PSScriptRoot
$cfg = Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
$env:CLAUDE_CONFIG_DIR = Join-Path $Root 'claude_profile'
Write-Host 'Signing in to Claude. A browser window will open; sign in with the firm''s Claude account.'
& $cfg.claude_exe auth login --claudeai
& $cfg.claude_exe auth status --text
Write-Host ''
Write-Host 'You can close this window.'
