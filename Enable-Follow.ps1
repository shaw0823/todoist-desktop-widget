$ErrorActionPreference = 'Stop'
$watcherPath = Join-Path $PSScriptRoot 'Follow-Todoist.ps1'
if (!(Test-Path -LiteralPath $watcherPath)) { throw 'Missing Follow-Todoist.ps1' }
$startupFolder = [Environment]::GetFolderPath('Startup')
if (!$startupFolder) { throw 'Windows Startup folder is unavailable.' }
$startupShortcut = Join-Path $startupFolder 'Todoist Desktop Widget.lnk'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($startupShortcut)
$link.TargetPath = $powershellExe
$link.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherPath`""
$link.WorkingDirectory = $PSScriptRoot
$link.WindowStyle = 7
$link.Description = 'Open the desktop widget when Todoist starts.'
$link.Save()
Start-Process -FilePath $powershellExe -ArgumentList $link.Arguments -WindowStyle Hidden | Out-Null
Write-Output 'Todoist follow mode enabled.'
