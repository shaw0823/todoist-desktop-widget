$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')

# Exercise the real watch loop with simulated process/window states only.
$script:samples = @('off', 'visible', 'visible', 'hidden', 'visible', 'off', 'visible')
$script:sampleIndex = 0
$script:launches = 0
function Get-TestProcesses {
    $state = $script:samples[$script:sampleIndex]
    if ($state -eq 'off') { return }
    $p = [pscustomobject]@{ MainWindowHandle = [IntPtr]$(if ($state -eq 'visible') { 1 } else { 0 }) }
    $p | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    $p
}
function Record-Launch { $script:launches++ }
$testSignal = [pscustomobject]@{}
$testSignal | Add-Member -MemberType ScriptMethod -Name Reset -Value { $false }
$testSignal | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
$testSignal | Add-Member -MemberType ScriptMethod -Name WaitOne -Value {
    param($milliseconds)
    $script:sampleIndex++
    return $script:sampleIndex -ge $script:samples.Count
}
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Follow-Todoist.ps1'))
$source = $source.Replace(". (Join-Path `$PSScriptRoot 'Runtime.ps1')", '')
$source = $source.Replace("Get-Process -Name 'Todoist' -ErrorAction SilentlyContinue", 'Get-TestProcesses')
$source = $source.Replace('$stopSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $watcherStopName)', '$stopSignal = $testSignal')
$source = $source.Replace('Start-Widget', 'Record-Launch')
$source = $source.Replace('Enter-WidgetMutex $watcherMutexName', 'Enter-WidgetMutex ($watcherMutexName + "-test-" + [Guid]::NewGuid())')
Invoke-Expression $source
if ($script:launches -ne 3) { throw "Expected 3 launch/open events, got $script:launches" }

# Acquire, release, and reacquire the single-instance guard.
$testName = 'Local\TodoistWidgetTest-' + [Guid]::NewGuid()
$guard = Enter-WidgetMutex $testName
if (!$guard) { throw 'Initial mutex acquisition failed' }
$guard.ReleaseMutex(); $guard.Dispose()
$guard = Enter-WidgetMutex $testName
if (!$guard) { throw 'Mutex was not released' }
$guard.ReleaseMutex(); $guard.Dispose()
'PASS: launch, tray reopen, no repeated launches, mutex lifecycle'
