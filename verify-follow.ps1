$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')

# Exercise the real watch loop without opening apps or reading real process state.
function Get-TestState {
    $state = $script:samples[$script:sampleIndex]
    return [pscustomobject]@{
        Present = $state -in @('main','minimized','cloaked')
        Open = $state -eq 'main'
    }
}
function Record-Launch { $script:launches++ }
function Test-FollowScenario($Name, [string[]]$Samples, [int]$Expected, [bool]$SkipInitial = $false) {
    $script:samples = $Samples
    $script:sampleIndex = 0
    $script:launches = 0
    $testSignal = [pscustomobject]@{}
    $testSignal | Add-Member -MemberType ScriptMethod -Name Reset -Value { $false }
    $testSignal | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    $testSignal | Add-Member -MemberType ScriptMethod -Name WaitOne -Value {
        param($milliseconds)
        $script:sampleIndex++
        return $script:sampleIndex -ge $script:samples.Count
    }
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Follow-Todoist.ps1'))
    $source = $source.Replace('param([switch]$SkipInitialOpen)', '$SkipInitialOpen = $SkipInitial')
    $source = $source.Replace(". (Join-Path `$PSScriptRoot 'Runtime.ps1')", '')
    $source = $source.Replace('Get-TodoistState', 'Get-TestState')
    $source = $source.Replace('$stopSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $watcherStopName)', '$stopSignal = $testSignal')
    $source = $source.Replace('Start-Widget', 'Record-Launch')
    $source = $source.Replace('Enter-WidgetMutex $watcherMutexName', 'Enter-WidgetMutex ($watcherMutexName + "-test-" + [Guid]::NewGuid())')
    Invoke-Expression $source
    if ($script:launches -ne $Expected) { throw "$Name expected $Expected launches, got $script:launches" }
}
Test-FollowScenario 'Background helpers only' (@('off','background') * 6) 0
Test-FollowScenario 'Normal launch' ((@('background') * 4) + (@('main') * 6)) 1
Test-FollowScenario 'Close during initial appearance' (@('main') + (@('off') * 6)) 0
Test-FollowScenario 'Close transient handle reappearance' ((@('main') * 3) + (@('off') * 2) + @('main') + (@('off') * 4) + (@('background') * 4)) 1
Test-FollowScenario 'Short handle gap' ((@('main') * 3) + (@('off') * 2) + (@('main') * 5)) 1
Test-FollowScenario 'Close and real reopen' ((@('main') * 3) + (@('off') * 4) + (@('main') * 3)) 2
Test-FollowScenario 'Minimize and restore' ((@('main') * 3) + (@('minimized') * 6) + (@('main') * 3)) 1
Test-FollowScenario 'Initially minimized' ((@('minimized') * 6) + (@('main') * 3)) 1
Test-FollowScenario 'Virtual desktop changes' ((@('main') * 3) + (@('cloaked') * 6) + (@('main') * 3)) 1
Test-FollowScenario 'Full exit with helper restart' ((@('main') * 3) + (@('off') * 4) + (@('background') * 3) + (@('main') * 3)) 2
Test-FollowScenario 'Watcher update keeps current session' ((@('main') * 5) + (@('off') * 4) + (@('main') * 3)) 1 $true

# Acquire, release, and reacquire the single-instance guard.
$testName = 'Local\TodoistWidgetTest-' + [Guid]::NewGuid()
$guard = Enter-WidgetMutex $testName
if (!$guard) { throw 'Initial mutex acquisition failed' }
$guard.ReleaseMutex(); $guard.Dispose()
$guard = Enter-WidgetMutex $testName
if (!$guard) { throw 'Mutex was not released' }
$guard.ReleaseMutex(); $guard.Dispose()
'PASS: background/closing regression, debounced reopen, minimize/desktop transitions, mutex lifecycle'
