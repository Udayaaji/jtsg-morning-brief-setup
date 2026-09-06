# Run by the uninstaller from <root>\app\. Removes the scheduled task only if
# it belongs to this installation. The delivery folder is never touched.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$task = Get-ScheduledTask -TaskName 'JTSG Morning Brief' -ErrorAction SilentlyContinue
if ($task) {
    $taskArgs = [string]$task.Actions[0].Arguments
    if ($taskArgs.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Unregister-ScheduledTask -TaskName 'JTSG Morning Brief' -Confirm:$false
    }
}
exit 0
