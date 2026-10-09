# Shared by the settings dialog and optional command-line launchers.
$script:followSettingsRoot = $PSScriptRoot

function Get-FollowShortcutPath {
    $startupFolder = [Environment]::GetFolderPath('Startup')
    if (!$startupFolder) { throw '找不到 Windows 启动文件夹。' }
    return Join-Path $startupFolder 'Todoist Desktop Widget.lnk'
}
function Get-FollowEnabled {
    return [bool](Test-Path -LiteralPath (Get-FollowShortcutPath) -PathType Leaf)
}
function Get-FollowShortcutInfo([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    return $shell.CreateShortcut($Path)
}
function Test-FollowShortcutOwned([string]$Path) {
    try {
        $link = Get-FollowShortcutInfo $Path
        return [IO.Path]::GetFileName($link.TargetPath) -ieq 'powershell.exe' -and
            $link.Arguments -match '(?i)(?:^|\s)-File\s+(?:"[^"]*[\\/]Follow-Todoist\.ps1"|[^\s]*[\\/]Follow-Todoist\.ps1)(?:\s|$)'
    } catch { return $false }
}
function Write-FollowShortcut([string]$Path, [string]$WatcherPath) {
    $link = Get-FollowShortcutInfo $Path
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherPath`""
    $link.WorkingDirectory = $script:followSettingsRoot
    $link.WindowStyle = 7
    $link.Description = '打开 Todoist 时自动启动 todoist widge'
    $link.Save()
}
function Start-FollowWatcher([string]$WatcherPath, [switch]$SkipInitialOpen) {
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherPath`""
    if ($SkipInitialOpen) { $arguments += ' -SkipInitialOpen' }
    return Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
}
function Wait-FollowWatcherStopped {
    $probe = [Threading.Mutex]::new($false, $watcherMutexName)
    $acquired = $false
    try {
        try { $acquired = $probe.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw '后台联动程序仍在停止，请稍后重试。' }
    } finally {
        if ($acquired) { $probe.ReleaseMutex() }
        $probe.Dispose()
    }
}
function Wait-FollowWatcherStarted($Process) {
    $probe = [Threading.Mutex]::new($false, $watcherMutexName)
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $readySince = $null
    try {
        while ($deadline.ElapsedMilliseconds -lt 5000) {
            $Process.Refresh()
            if ($Process.HasExited) { throw '后台联动程序启动失败。' }
            $acquired = $false
            try { $acquired = $probe.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            if ($acquired) {
                $probe.ReleaseMutex()
                $readySince = $null
            } elseif ($null -eq $readySince) {
                $readySince = [Diagnostics.Stopwatch]::StartNew()
            } elseif ($readySince.ElapsedMilliseconds -ge 200) {
                return
            }
            Start-Sleep -Milliseconds 50
        }
        throw '后台联动程序启动超时，请稍后重试。'
    } finally { $probe.Dispose() }
}
function Set-FollowEnabled([bool]$Enabled, [switch]$SkipInitialOpen) {
    # CLI and settings changes must not reset the stop signal while an older
    # watcher still owns its mutex. The UI runs this operation off its thread.
    $operationMutex = [Threading.Mutex]::new($false, ($watcherMutexName + '-Settings'))
    $operationAcquired = $false
    $stopSignal = $null
    $startedProcess = $null
    $shortcutChanged = $false
    $previousShortcut = $null
    $hadShortcut = $false
    try {
        try { $operationAcquired = $operationMutex.WaitOne(10000) }
        catch [Threading.AbandonedMutexException] { $operationAcquired = $true }
        if (!$operationAcquired) { throw '另一项联动设置正在保存，请稍后重试。' }
        $shortcutPath = Get-FollowShortcutPath
        $hadShortcut = Test-Path -LiteralPath $shortcutPath -PathType Leaf
        if ($hadShortcut) {
            if (!(Test-FollowShortcutOwned $shortcutPath)) {
                throw '启动文件夹中存在同名的其他快捷方式，请先调整其名称。'
            }
            $previousShortcut = [IO.File]::ReadAllBytes($shortcutPath)
        }
        $watcherPath = Join-Path $script:followSettingsRoot 'Follow-Todoist.ps1'
        if ($Enabled -and !(Test-Path -LiteralPath $watcherPath -PathType Leaf)) {
            throw '找不到 Follow-Todoist.ps1，请保留完整的应用文件夹。'
        }
        $stopSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $watcherStopName)
        $stopSignal.Set() | Out-Null
        Wait-FollowWatcherStopped
        if (!$Enabled) {
            if ($hadShortcut) { Remove-Item -LiteralPath $shortcutPath -ErrorAction Stop }
            return
        }
        $shortcutChanged = $true
        Write-FollowShortcut $shortcutPath $watcherPath
        $stopSignal.Reset() | Out-Null
        $startedProcess = Start-FollowWatcher $watcherPath -SkipInitialOpen:$SkipInitialOpen
        if ($null -eq $startedProcess) { throw '后台联动程序未能启动。' }
        Wait-FollowWatcherStarted $startedProcess
    } catch {
        $failure = $_
        if ($Enabled -and $shortcutChanged) {
            if ($null -ne $stopSignal) { $stopSignal.Set() | Out-Null }
            if ($null -ne $startedProcess) {
                try {
                    if (!$startedProcess.WaitForExit(1500)) { $startedProcess.Kill(); $startedProcess.WaitForExit(1000) | Out-Null }
                } catch { }
            }
            try {
                if ($hadShortcut) { [IO.File]::WriteAllBytes($shortcutPath, $previousShortcut) }
                elseif (Test-Path -LiteralPath $shortcutPath -PathType Leaf) { Remove-Item -LiteralPath $shortcutPath -ErrorAction Stop }
            } catch { throw "联动设置失败，恢复启动快捷方式也失败：$($_.Exception.Message)" }
        }
        throw $failure
    } finally {
        if ($null -ne $startedProcess) { $startedProcess.Dispose() }
        if ($null -ne $stopSignal) { $stopSignal.Dispose() }
        if ($operationAcquired) { $operationMutex.ReleaseMutex() }
        $operationMutex.Dispose()
    }
}
