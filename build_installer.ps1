<#
.SYNOPSIS
    Compile JTSG-Morning-Brief-Setup.exe, and with -Publish create the GitHub
    Release that JTSG downloads from. Author-side only.
#>
param([string]$Version = '1.0.0', [switch]$Publish)
$ErrorActionPreference = 'Stop'
$candidates = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe")
$iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'ISCC.exe not found. Install Inno Setup 6 first.' }
& $iscc "/DAppVersion=$Version" (Join-Path $PSScriptRoot 'setup.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC exited $LASTEXITCODE" }
$exe = Join-Path $PSScriptRoot 'dist\JTSG-Morning-Brief-Setup.exe'
"Built $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 2)) MB)"
if ($Publish) {
    gh release create "v$Version" $exe -R Udayaaji/jtsg-morning-brief-setup --title "JTSG Morning Brief Setup $Version" --notes-file (Join-Path $PSScriptRoot 'RELEASE_NOTES.md')
    if ($LASTEXITCODE -ne 0) { throw "gh release create exited $LASTEXITCODE" }
    "Published: https://github.com/Udayaaji/jtsg-morning-brief-setup/releases/latest/download/JTSG-Morning-Brief-Setup.exe"
}
