$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.task-copy-ui-test-' + [Guid]::NewGuid().ToString('N')
$testDirectory = Join-Path $root $folderName
$null = [IO.Directory]::CreateDirectory($testDirectory)
$window = $null

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
function Get-CopyButton([int]$Index) { $ui.Tasks.Children[$Index].Child.Children[1] }
function Find-CopyButton([string]$Title) {
    foreach ($row in $ui.Tasks.Children) {
        if ($row.Child.Children[2].Text -ceq $Title) { return $row.Child.Children[1] }
    }
    throw "Missing task row: $Title"
}
function Click-Copy($Button) {
    $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}

try {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start.ps1'))
    foreach ($module in 'Runtime.ps1','Tray.ps1','Theme.ps1','Background.ps1','Calendar.ps1','TaskCopy.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1','DisplaySettings.ps1') {
        $path = (Join-Path $PSScriptRoot $module).Replace("'", "''")
        $source = $source.Replace(". (Join-Path `$PSScriptRoot '$module')", ". '$path'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-task-copy-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $realDataAssignment = "`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'"
    if (!$source.Contains($realDataAssignment)) { throw 'Cannot isolate widget settings.' }
    $fixtureDataPath = $testDirectory.Replace("'", "''")
    $fixtureTokenPath = (Join-Path $testDirectory 'token.dat').Replace("'", "''")
    $source = $source.Replace($realDataAssignment, "`$dataDir = '$fixtureDataPath'")
    $source = $source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$fixtureTokenPath'")
    $source = $source.Replace('Todoist 桌面小组件', 'Todoist 复制测试')
    $source = $source.Replace('Start-WidgetMessageLoop -Window $window', '$timer.Stop(); $poll.Stop()')
    Invoke-Expression $source
    Assert-Equal $dataDir $testDirectory 'Test settings are isolated'
    Assert-Equal $script:token '' 'Test did not read a real API token'

    $script:testRequests = [Collections.Generic.List[object]]::new()
    $script:failNext = $false
    function Start-Request($Kind, $Method, $Path, $Body, $Context) {
        $script:testRequests.Add(@{Kind=$Kind; Method=$Method; Path=$Path; Body=$Body})
        $worker = [PowerShell]::Create()
        $code = 'param($kind,$body,$snapshot,$fail) if ($kind -eq "Copy") { Start-Sleep -Milliseconds 220; if ($fail) { throw "Synthetic copy failure" }; [pscustomobject]@{id=("copy-" + $body.content);content=$body.content;due=@{date=$body.due_date};checked=$false} } elseif ($kind -eq "Load") { $snapshot }'
        $fail = $script:failNext -and $Kind -eq 'Copy'
        if ($fail) { $script:failNext = $false }
        $worker.AddScript($code).AddArgument($Kind).AddArgument($Body).AddArgument([object[]]@($script:cachedTasks)).AddArgument($fail) | Out-Null
        $handle = $worker.BeginInvoke()
        $script:jobs.Add(@{Worker=$worker; Handle=$handle; Kind=$Kind; Context=$Context})
    }

    $window.Topmost = $false
    $window.Show()
    $window.UpdateLayout()
    $script:token = 'synthetic-test-token'
    $past = [DateTime]::Today.AddDays(-2)
    $pastKey = $past.ToString('yyyy-MM-dd')
    $script:date = $past
    $script:cachedTasks = @(
        @{id='old-a';content='只复制第一条';due=@{date=$pastKey};checked=$false;order=1},
        @{id='old-b';content='稍后复制第二条';due=@{date=$pastKey};checked=$false;order=2},
        @{id='old-complete';content='不应再复制';due=@{date=$pastKey};checked=$true;order=3}
    )
    Render-Tasks
    Assert-Equal $ui.Tasks.Children.Count 2 'Past list excludes completed tasks and shows both incomplete tasks'
    $first = Find-CopyButton '只复制第一条'
    Assert-Equal $first.Content '复制到今天' 'Each row has its own copy control'
    Click-Copy $first
    Assert-Equal $script:copyPending.Count 1 'First task is pending without blocking UI'
    Assert-Equal $first.IsEnabled $false 'Pending copy button is disabled'
    Copy-TaskToToday $first
    Assert-Equal @($script:testRequests | Where-Object Kind -eq 'Copy').Count 1 'Repeated click did not enqueue duplicate creation'
    Assert-Equal $script:testRequests[0].Body.content '只复制第一条' 'Creation payload contains only selected task'
    Assert-Equal $script:testRequests[0].Body.due_date ([DateTime]::Today.ToString('yyyy-MM-dd')) 'Creation targets today'

    $script:date = [DateTime]::Today
    Render-Tasks
    Assert-Equal $ui.Tasks.Children.Count 0 'Today remains usable while copy runs'
    $script:date = $past
    Render-Tasks
    Assert-Equal (Find-CopyButton '只复制第一条').Content '复制中…' 'Pending state survives a view refresh'
    $poll.Start()
    Pump 850
    Assert-Equal $script:copyPending.Count 0 'Pending state clears after success'
    Assert-Equal (Find-CopyButton '只复制第一条').Content '已复制' 'Successful row shows durable feedback'
    Assert-Equal (Find-CopyButton '只复制第一条').IsEnabled $false 'Successful row cannot accidentally be copied again'
    Assert-Equal (Find-CopyButton '稍后复制第二条').Content '复制到今天' 'Other rows remain independently selectable'
    Assert-Equal @($script:cachedTasks | Where-Object id -eq 'old-a').Count 1 'Original task remains in cache'
    $script:date = [DateTime]::Today
    Render-Tasks
    Assert-Equal $ui.Tasks.Children.Count 1 'Only selected task appears on today after copying'

    $script:date = $past
    Render-Tasks
    $script:failNext = $true
    Click-Copy (Find-CopyButton '稍后复制第二条')
    Assert-Equal (Find-CopyButton '稍后复制第二条').IsEnabled $false 'Second row independently enters pending state'
    Pump 600
    Assert-Equal $script:copyPending.Count 0 'Failed copy clears pending state'
    Assert-Equal (Find-CopyButton '稍后复制第二条').IsEnabled $true 'Failed row becomes retryable'
    if ($ui.Status.Text -notlike '复制失败*') { throw 'Copy error feedback is missing.' }
    Click-Copy (Find-CopyButton '稍后复制第二条')
    Pump 850
    Assert-Equal (Find-CopyButton '稍后复制第二条').Content '已复制' 'Retry succeeds for second row'
    Assert-Equal @($script:testRequests | Where-Object Kind -eq 'Copy').Count 3 'Two selected tasks plus one retry issued exactly three create requests'
    Write-Output 'PASS: one-row copy, duplicate guard, async feedback, retained source, independent rows, and failure retry.'
}
finally {
    if ($window) { $window.Close() }
    $resolvedTarget = [IO.Path]::GetFullPath($testDirectory).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedTarget) -cne $root -or [IO.Path]::GetFileName($resolvedTarget) -cne $folderName -or $resolvedTarget -ceq $root) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}
