$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')
$stopSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $watcherStopName)
$stopSignal.Set() | Out-Null
$stopSignal.Dispose()
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Todoist Desktop Widget.lnk'
if (Test-Path -LiteralPath $startupShortcut) { Remove-Item -LiteralPath $startupShortcut }
Write-Output 'Todoist follow mode disabled.'
