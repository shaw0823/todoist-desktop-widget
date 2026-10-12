$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.task-copy-ui-test-' + [Guid]::NewGuid().ToString('N')
$testDirectory = Join-Path $root $folderName
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
$window = $null

function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Pump([int]$Milliseconds) {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $end = [Windows.Threading.DispatcherTimer]::new()
    $end.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $end.Tag = $frame
    $end.Add_Tick({ $this.Tag.Continue = $false; $this.Stop() })
    $end.Start()
    try { [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $end.Stop() }
}
function Find-CopyButton([string]$Title) {
    foreach ($row in $ui.Tasks.Children) {
        if ($row.Child.Children[2].Text -ceq $Title) { return $row.Child.Children[1] }
    }
    throw "Missing task row: $Title"
}
function Click-Button($Button) {
    $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
}
function Press-Return($TextBox) {
    $source = [Windows.PresentationSource]::FromVisual($TextBox)
    if ($null -eq $source) { throw 'The input has no presentation source.' }
    $key = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $source, [Environment]::TickCount, [Windows.Input.Key]::Return)
    $key.RoutedEvent = [Windows.Input.Keyboard]::KeyDownEvent
    $TextBox.RaiseEvent($key)
}

try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start.ps1'), [Text.Encoding]::UTF8)
    foreach ($module in @('Runtime.ps1','Tray.ps1','Theme.ps1','Background.ps1','Calendar.ps1','TaskCopy.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1','DisplaySettings.ps1','History.ps1','HistoryUI.ps1','OfflineTasks.ps1','Reminders.ps1','ReminderPopup.ps1','TaskWorkflow.ps1')) {
        $needle = ". (Join-Path " + '$PSScriptRoot' + " '$module')"
        Assert ($source.Contains($needle)) "Module location changed: $module"
        $source = $source.Replace($needle, ". '$(Join-Path $root $module)'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-task-copy-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $realDataAssignment = '$dataDir = Join-Path $env:LOCALAPPDATA ''TodoistDesktopWidget'''
    Assert ($source.Contains($realDataAssignment)) 'Cannot isolate widget settings.'
    $source = $source.Replace($realDataAssignment, ('$dataDir = ' + "'" + $testDirectory.Replace("'", "''") + "'"))
    $source = $source.Replace('$tokenPath = Join-Path $dataDir ''token.dat''', ('$tokenPath = ' + "'" + (Join-Path $testDirectory 'token.dat').Replace("'", "''") + "'"))
    $source = $source.Replace('$window.Add_ContentRendered({ Initialize-TaskWorkflow; Render-Tasks; Load-Tasks; Start-NextOfflineSync; Check-TaskReminders })', '')
    $source = $source.Replace('Start-WidgetMessageLoop -Window $window', '$timer.Stop(); $poll.Stop(); $clockTimer.Stop(); $reminderTimer.Stop()')
    Invoke-Expression $source
    Assert-Equal $dataDir $testDirectory 'Test settings are isolated'
    Assert-Equal $script:token '' 'Test did not read a real API token'

    $script:testRequests = [Collections.Generic.List[object]]::new()
    function Start-Request($Kind, $Method, $Path, $Body, $Context) {
        $script:testRequests.Add(@{Kind=$Kind; Method=$Method; Path=$Path; Body=$Body; Context=$Context})
        $worker = [PowerShell]::Create()
        $worker.AddScript('throw "Fixture offline"') | Out-Null
        $handle = $worker.BeginInvoke()
        $script:jobs.Add(@{Worker=$worker; Handle=$handle; Kind=$Kind; Context=$Context})
    }

    $window.Topmost = $false
    $window.ShowActivated = $false
    $window.Opacity = 0
    $window.Show()
    $ui.HistoryMenuItem.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
    Assert ($null -ne $script:historyWindow -and $script:historyWindow.IsVisible) 'The completed-history menu did not open its window.'
    Assert ($script:historyUi.HistoryStatus.Text.Contains('关联')) 'History did not explain the missing account connection.'
    Assert ($script:testRequests.Count -eq 0) 'History made an API call without a token.'
    $script:historyWindow.Close()

    $script:token = 'isolated-task-copy-token'
    Initialize-TaskWorkflow
    $past = [DateTime]::Today.AddDays(-2)
    $pastKey = $past.ToString('yyyy-MM-dd')
    $todayKey = [DateTime]::Today.ToString('yyyy-MM-dd')
    Set-OfflineTaskSnapshot -Context $script:offlineContext -Tasks @(
        [pscustomobject]@{id='old-a'; content='只复制第一条'; due=@{date=$pastKey}; checked=$false; order=1},
        [pscustomobject]@{id='old-b'; content='稍后复制第二条'; due=@{date=$pastKey}; checked=$false; order=2},
        [pscustomobject]@{id='old-complete'; content='不应再复制'; due=@{date=$pastKey}; checked=$true; order=3}
    )
    Update-TaskProjection
    $script:date = $past
    Render-Tasks
    Assert-Equal $ui.Tasks.Children.Count 2 'Past list should show only its two incomplete tasks'

    $first = Find-CopyButton '只复制第一条'
    Assert-Equal $first.Content '复制到今天' 'Each past task should have its own copy control'
    Click-Button $first
    Assert-Equal $script:offlineContext.Store.Queue.Count 1 'The selected task was not durably queued'
    $copyOperation = $script:offlineContext.Store.Queue[0]
    Assert ($copyOperation.Kind -eq 'Copy' -and $copyOperation.SourceId -eq 'old-a') 'The wrong source task was copied'
    Assert ($copyOperation.TargetDate -eq $todayKey -and $copyOperation.Payload.content -eq '只复制第一条') 'The copy payload or target date was wrong'
    Assert-Equal (Find-CopyButton '只复制第一条').Content '复制中…' 'The source row should show pending copy state'
    Assert (!(Find-CopyButton '只复制第一条').IsEnabled) 'The pending copy button should be disabled'
    Copy-TaskToToday $first
    Assert-Equal $script:offlineContext.Store.Queue.Count 1 'Repeated click created a duplicate copy operation'
    Assert-Equal @($script:testRequests | Where-Object Kind -eq 'Sync').Count 1 'Only one first sync attempt should start'
    $script:date = [DateTime]::Today
    Render-Tasks
    Assert-Equal $ui.Tasks.Children.Count 1 'Today should immediately show the offline copy'
    Assert ($ui.Tasks.Children[0].Child.Children[1].Text.Contains('待同步')) 'The local copy is not labelled as pending'
    Assert (!$ui.Tasks.Children[0].Child.Children[0].IsEnabled) 'A copy without a server ID should not be completable yet'

    $poll.Start()
    Pump 400
    Assert ($script:offlineContext.Store.Queue[0].State -eq 'Pending') 'Network failure did not leave a retryable copy'
    Assert ($ui.Status.Text.Contains('本机')) 'The copy did not report that it was saved locally'
    $firstId = $copyOperation.Id
    Initialize-TaskWorkflow
    $script:nextSyncAttempt = [DateTime]::Now.AddMinutes(1)
    Assert ($script:offlineContext.Store.Queue.Count -eq 1 -and $script:offlineContext.Store.Queue[0].Id -eq $firstId) 'Restart changed or lost the queued copy'
    Update-TaskProjection
    $script:date = $past
    Render-Tasks
    Assert-Equal (Find-CopyButton '只复制第一条').Content '复制中…' 'Pending copy feedback was lost after restart'
    Assert-Equal (Find-CopyButton '稍后复制第二条').Content '复制到今天' 'The other past task is not independently selectable'

    $script:date = [DateTime]::Today
    Render-Tasks
    $ui.Input.Text = '本机新增'
    Press-Return $ui.Input
    Assert-Equal $script:offlineContext.Store.Queue.Count 2 'Pressing Enter did not queue a new task offline'
    Assert-Equal $ui.Input.Text '' 'Successful local save did not clear the input'
    Assert (@($script:offlineContext.Store.Queue | Where-Object { $_.Kind -eq 'Add' -and $_.Payload.content -eq '本机新增' }).Count -eq 1) 'The add operation payload was not saved'
    Assert-Equal $ui.Tasks.Children.Count 2 'Today should show both the offline copy and offline new task'
    Assert-Equal @($script:testRequests | Where-Object Kind -eq 'Sync').Count 1 'Offline backoff should not cause an immediate repeated network attempt'

    $script:date = $past
    Render-Tasks
    Click-Button (Find-CopyButton '稍后复制第二条')
    Assert-Equal $script:offlineContext.Store.Queue.Count 3 'The second past task was not copied independently'
    Assert-Equal (Find-CopyButton '稍后复制第二条').Content '复制中…' 'Second row pending state was not shown'
    Assert-Equal (Find-CopyButton '只复制第一条').Content '复制中…' 'First row pending state unexpectedly changed'
    Assert (@($script:cachedTasks | Where-Object id -eq 'old-a').Count -eq 1) 'Copying removed the original task'

    Complete-OfflineTaskOperation -Context $script:offlineContext -Id $firstId -Response @{
        sync_status = @{ $($firstId) = 'ok' }
        temp_id_mapping = @{ $($copyOperation.TempId) = 'server-copy-a' }
    } | Out-Null
    Update-TaskProjection
    Render-Tasks
    Assert-Equal (Find-CopyButton '只复制第一条').Content '已复制' 'Acknowledged copy does not show durable feedback'
    Assert (!(Find-CopyButton '只复制第一条').IsEnabled) 'Acknowledged copy should not be copied twice'
    $reopened = Open-OfflineTaskStore -DataDir $testDirectory -Token $script:token
    Assert ($reopened.Store.CopyReceipts.ContainsKey('old-a|' + $todayKey)) 'The copy receipt was not saved across restart'
    Write-Output 'PASS: isolated history entry, per-row offline copy, duplicate guard, add via Enter, restart projection, and durable copy receipt.'
} finally {
    if ($null -ne $window) { $window.Close() }
    $resolvedTarget = [IO.Path]::GetFullPath($testDirectory).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedTarget) -cne $root -or [IO.Path]::GetFileName($resolvedTarget) -cne $folderName -or $resolvedTarget -ceq $root) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}