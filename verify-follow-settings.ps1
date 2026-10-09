$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')
. (Join-Path $PSScriptRoot 'FollowSettings.ps1')

# Use a private folder, event and mutex: never modify the user's startup folder,
# stop their real watcher, launch Todoist, or open the widget.
$testFolder = Join-Path $PSScriptRoot ('.follow-settings-test-' + [Guid]::NewGuid())
[IO.Directory]::CreateDirectory($testFolder) | Out-Null
$script:followSettingsRoot = $testFolder
$script:watcherMutexName = 'Local\TodoistFollowSettingsTest-' + [Guid]::NewGuid()
$script:watcherStopName = $watcherMutexName + '-Stop'
$script:testShortcut = Join-Path $testFolder 'Todoist Desktop Widget.lnk'
$script:testStartMode = 'Normal'
$script:testStartPids = [Collections.Generic.List[int]]::new()
$script:testLastSkip = $false
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-Test([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Get-FollowShortcutPath { return $script:testShortcut }
function Get-FollowShortcutInfo([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Write-FollowShortcut([string]$Path, [string]$WatcherPath) {
    $value = [ordered]@{
        TargetPath = $powershellExe
        Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherPath`""
        WorkingDirectory = $script:followSettingsRoot
        WindowStyle = 7
    }
    [IO.File]::WriteAllText($Path, ($value | ConvertTo-Json), [Text.UTF8Encoding]::new($true))
}
function Start-FollowWatcher([string]$WatcherPath, [switch]$SkipInitialOpen) {
    $script:testLastSkip = [bool]$SkipInitialOpen
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherPath`" -MutexName `"$watcherMutexName`" -StopName `"$watcherStopName`" -Mode $script:testStartMode"
    $process = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $script:testStartPids.Add($process.Id)
    return $process
}
function Test-TestWatcherAlive([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    $process.Dispose()
    return $true
}
function Wait-TestWatcherExit([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $true }
    try { return $process.WaitForExit(1000) }
    finally { $process.Dispose() }
}

$fakeWatcher = @'
param([string]$MutexName, [string]$StopName, [string]$Mode)
if ($Mode -eq 'Exit') { exit 1 }
$mutex = [Threading.Mutex]::new($false, $MutexName)
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); exit 2 }
$signal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $StopName)
try {
    $signal.Reset() | Out-Null
    $signal.WaitOne() | Out-Null
    # Deliberate delay catches the rapid off/on race against an old watcher.
    Start-Sleep -Milliseconds 350
} finally {
    $signal.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
'@
[IO.File]::WriteAllText((Join-Path $testFolder 'Follow-Todoist.ps1'), $fakeWatcher, [Text.UTF8Encoding]::new($true))
try {
    Assert-Test (!(Get-FollowEnabled)) 'A new installation unexpectedly follows Todoist.'
    Set-FollowEnabled $true -SkipInitialOpen
    Assert-Test (Get-FollowEnabled) 'Enable did not persist its startup shortcut.'
    Assert-Test $script:testLastSkip 'Enabling from an open widget lost SkipInitialOpen.'
    $firstPid = $script:testStartPids[$script:testStartPids.Count - 1]
    Assert-Test (Test-TestWatcherAlive $firstPid) 'Enable returned without a running watcher.'
    $link = Get-FollowShortcutInfo $script:testShortcut
    Assert-Test ($link.Arguments -notmatch 'SkipInitialOpen') 'A later Windows login must detect Todoist normally.'

    # A repeated enable waits for the previous instance, then installs one watcher.
    Set-FollowEnabled $true -SkipInitialOpen
    $secondPid = $script:testStartPids[$script:testStartPids.Count - 1]
    Assert-Test ($secondPid -ne $firstPid) 'Repeated enable did not replace the watcher.'
    Assert-Test (!(Test-TestWatcherAlive $firstPid)) 'The old watcher survived replacement.'
    Assert-Test (Test-TestWatcherAlive $secondPid) 'The replacement watcher exited.'

    Set-FollowEnabled $false
    Assert-Test (!(Get-FollowEnabled)) 'Disable left its startup shortcut.'
    Assert-Test (Wait-TestWatcherExit $secondPid) 'The watcher did not exit after disable.'
    Set-FollowEnabled $true -SkipInitialOpen
    $thirdPid = $script:testStartPids[$script:testStartPids.Count - 1]
    Assert-Test (Test-TestWatcherAlive $thirdPid) 'Rapid off/on failed to restart the watcher.'

    # Startup failure must preserve the previous shortcut bytes exactly.
    $previous = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:testShortcut))
    $script:testStartMode = 'Exit'
    $failed = $false
    try { Set-FollowEnabled $true } catch { $failed = $true }
    Assert-Test $failed 'An immediately exiting watcher was treated as enabled.'
    Assert-Test ($previous -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:testShortcut))) 'Failed enable changed the prior shortcut.'
    Set-FollowEnabled $false
    $failed = $false
    try { Set-FollowEnabled $true } catch { $failed = $true }
    Assert-Test ($failed -and !(Get-FollowEnabled)) 'Failed first-time enable left a startup shortcut.'

    # Reject a coincidentally named unrelated shortcut without deleting it.
    [IO.File]::WriteAllText($script:testShortcut, '{"TargetPath":"C:\\Windows\\notepad.exe","Arguments":""}')
    $foreign = [IO.File]::ReadAllText($script:testShortcut)
    foreach ($enabled in @($false, $true)) {
        $failed = $false
        try { Set-FollowEnabled $enabled } catch { $failed = $true }
        Assert-Test $failed 'An unrelated startup shortcut was accepted as widget-owned.'
        Assert-Test ($foreign -eq [IO.File]::ReadAllText($script:testShortcut)) 'An unrelated startup shortcut was modified.'
    }
    'PASS: follow enable/disable handshake, rapid restart, startup failure rollback and unrelated shortcut protection.'
} finally {
    $cleanupSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $watcherStopName)
    $cleanupSignal.Set() | Out-Null
    foreach ($processId in $script:testStartPids) {
        $remaining = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -ne $remaining) {
            if (!$remaining.WaitForExit(1500)) { $remaining.Kill(); $remaining.WaitForExit(1000) | Out-Null }
            $remaining.Dispose()
        }
    }
    $cleanupSignal.Dispose()
    $resolved = [IO.Path]::GetFullPath($testFolder)
    $workspace = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
