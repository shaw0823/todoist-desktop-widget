$ErrorActionPreference = 'Stop'
$scriptFile = Join-Path $PSScriptRoot 'Start.ps1'
if (![IO.File]::Exists($scriptFile)) { throw 'Missing Start.ps1' }
$desktopFolder = [Environment]::GetFolderPath('DesktopDirectory')
if (!$desktopFolder -or ![IO.Directory]::Exists($desktopFolder)) { throw 'Windows Desktop folder is unavailable.' }
$shortcutPath = Join-Path $desktopFolder 'todoist widge.lnk'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
$iconLocation = $powershellExe + ',0'
$todoistLinks = @(
    (Join-Path $desktopFolder 'Todoist.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Todoist.lnk'),
    (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Todoist.lnk')
)
foreach ($todoistLink in $todoistLinks) {
    if (![IO.File]::Exists($todoistLink)) { continue }
    $todoist = $shell.CreateShortcut($todoistLink)
    if ([IO.Path]::GetFileName($todoist.TargetPath) -ine 'Todoist.exe' -or ![IO.File]::Exists($todoist.TargetPath)) { continue }
    $iconLocation = $todoist.TargetPath + ',0'
    if ($todoist.IconLocation -match '^(.*),\s*(-?\d+)$' -and [IO.File]::Exists($Matches[1].Trim('"'))) {
        $iconLocation = $todoist.IconLocation
    }
    break
}
if ($iconLocation -eq ($powershellExe + ',0')) {
    $todoistExe = Join-Path $env:LOCALAPPDATA 'Programs\todoist\Todoist.exe'
    if ([IO.File]::Exists($todoistExe)) { $iconLocation = $todoistExe + ',0' }
}
$arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptFile`""
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellExe
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 7
$shortcut.Description = '独立打开 Todoist 桌面小组件'
$shortcut.IconLocation = $iconLocation
$shortcut.Save()
$verified = $shell.CreateShortcut($shortcutPath)
if ($verified.TargetPath -ine $powershellExe -or $verified.Arguments -cne $arguments -or $verified.IconLocation -cne $iconLocation) {
    throw 'Desktop shortcut verification failed.'
}
Write-Output ('已创建桌面快捷方式：' + $shortcutPath)
Write-Output ('图标：' + $verified.IconLocation)
