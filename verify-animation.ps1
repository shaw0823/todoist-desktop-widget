$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.animation-ui-test-' + [Guid]::NewGuid().ToString('N')
$testDirectory = Join-Path $root $folderName
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
$window = $null

function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Pump([int]$Milliseconds) {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $end = [Windows.Threading.DispatcherTimer]::new()
    $end.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $end.Tag = $frame
    $end.Add_Tick({ $this.Tag.Continue = $false; $this.Stop() })
    $end.Start()
    try { [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $end.Stop() }
}
function FakeTask([string]$Id) {
    [pscustomobject]@{ id=$Id; content=('离线完成 ' + $Id); due=@{date=[DateTime]::Today.ToString('yyyy-MM-dd')}; checked=$false; completed_count=0; order=1 }
}
function Find-TaskCheck([string]$Id) {
    foreach ($row in $ui.Tasks.Children) {
        $check = $row.Child.Children[0]
        if ([string]$check.Tag.Id -eq $Id) { return $check }
    }
    throw "Missing task row $Id"
}

try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start.ps1'), [Text.Encoding]::UTF8)
    foreach ($module in @('Runtime.ps1','Tray.ps1','Theme.ps1','Background.ps1','Calendar.ps1','TaskCopy.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1','DisplaySettings.ps1','History.ps1','HistoryUI.ps1','OfflineTasks.ps1','Reminders.ps1','ReminderPopup.ps1','TaskWorkflow.ps1')) {
        $needle = ". (Join-Path " + '$PSScriptRoot' + " '$module')"
        Assert ($source.Contains($needle)) "Module location changed: $module"
        $source = $source.Replace($needle, ". '$(Join-Path $root $module)'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-animation-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $realDataAssignment = '$dataDir = Join-Path $env:LOCALAPPDATA ''TodoistDesktopWidget'''
    Assert ($source.Contains($realDataAssignment)) 'Cannot isolate widget settings.'
    $source = $source.Replace($realDataAssignment, ('$dataDir = ' + "'" + $testDirectory.Replace("'", "''") + "'"))
    $source = $source.Replace('$tokenPath = Join-Path $dataDir ''token.dat''', ('$tokenPath = ' + "'" + (Join-Path $testDirectory 'token.dat').Replace("'", "''") + "'"))
    $source = $source.Replace('$window.Add_ContentRendered({ Initialize-TaskWorkflow; Render-Tasks; Load-Tasks; Start-NextOfflineSync; Check-TaskReminders })', '')
    $source = $source.Replace('Start-WidgetMessageLoop -Window $window', '$timer.Stop(); $poll.Stop(); $clockTimer.Stop(); $reminderTimer.Stop()')
    Invoke-Expression $source
    Assert ($dataDir -ceq $testDirectory -and !$script:token) 'Fixture settings or API token were not isolated.'

    $script:testRequests = [Collections.Generic.List[object]]::new()
    function Start-Request($Kind, $Method, $Path, $Body, $Context) {
        $script:testRequests.Add(@{ Kind=$Kind; Method=$Method; Path=$Path; Context=$Context })
        $worker = [PowerShell]::Create()
        $worker.AddScript('throw "Fixture offline"') | Out-Null
        $handle = $worker.BeginInvoke()
        $script:jobs.Add(@{ Worker=$worker; Handle=$handle; Kind=$Kind; Context=$Context })
    }

    $window.Topmost = $false
    $window.ShowActivated = $false
    $window.Opacity = 0
    $window.Show()
    $script:token = 'isolated-animation-token'
    Initialize-TaskWorkflow
    Set-OfflineTaskSnapshot -Context $script:offlineContext -Tasks @((FakeTask 'one'), (FakeTask 'two'))
    Update-TaskProjection
    Render-Tasks
    Assert ($ui.Tasks.Children.Count -eq 2) 'The fixture tasks were not displayed.'

    $check = Find-TaskCheck 'one'
    $check.IsChecked = $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Animate-Complete $check
    $clock.Stop()
    Assert ($clock.ElapsedMilliseconds -lt 350) 'Completing a task blocked the UI on the network.'
    Assert ($script:offlineContext.Store.Queue.Count -eq 1) 'Completion was not written to the durable queue before sync.'
    $operation = $script:offlineContext.Store.Queue[0]
    Assert ($operation.Kind -eq 'Close' -and $operation.TaskId -eq 'one') 'The wrong completion was queued.'
    Assert ($script:pending.ContainsKey('one') -and !$check.IsEnabled) 'The completion animation did not begin.'
    Assert (@($script:cachedTasks | Where-Object id -eq 'one').Count -eq 0) 'The locally completed task remained in the projection.'
    Assert (@($script:testRequests | Where-Object Kind -eq 'Sync').Count -eq 1) 'Only one sync attempt should start.'
    $poll.Start()
    Pump 900
    Assert (!$script:pending.Count) 'The animation did not finish.'
    Assert ($ui.Tasks.Children.Count -eq 1) 'The completed row reappeared after the simulated network error.'
    Assert ($script:offlineContext.Store.Queue.Count -eq 1 -and $script:offlineContext.Store.Queue[0].State -eq 'Pending') 'Network failure did not preserve a retryable completion.'
    Assert ($ui.Status.Text -match '缓存|待同步') 'The UI did not explain the offline state.'

    $reopened = Open-OfflineTaskStore -DataDir $testDirectory -Token $script:token
    Assert ($reopened.Store.Queue.Count -eq 1 -and $reopened.Store.Queue[0].Id -eq $operation.Id) 'Restart changed the queued completion ID.'
    $retry = ConvertTo-OfflineSyncCommand -Operation $reopened.Store.Queue[0]
    Assert ($retry.uuid -eq $operation.Id -and $retry.type -eq 'item_close') 'Restart did not preserve the idempotent sync command.'

    $check = Find-TaskCheck 'two'
    $check.IsChecked = $true
    Animate-Complete $check
    Pump 500
    Assert ($ui.Tasks.Children.Count -eq 0 -and $script:offlineContext.Store.Queue.Count -eq 2) 'A second offline completion did not work independently.'
    Assert (@($script:offlineContext.Store.Queue | ForEach-Object { $_.Id } | Select-Object -Unique).Count -eq 2) 'Two completions shared one operation ID.'
    Write-Output 'PASS: nonblocking completion animation, immediate local removal, offline queue, restart-safe retry, and independent tasks.'
} finally {
    if ($null -ne $window) { $window.Close() }
    $resolvedTarget = [IO.Path]::GetFullPath($testDirectory).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedTarget) -cne $root -or [IO.Path]::GetFileName($resolvedTarget) -cne $folderName -or $resolvedTarget -ceq $root) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}