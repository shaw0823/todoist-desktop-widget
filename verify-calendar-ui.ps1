$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.calendar-ui-test-' + [Guid]::NewGuid().ToString('N')
$testDirectory = Join-Path $root $folderName
$null = [IO.Directory]::CreateDirectory($testDirectory)
$window = $null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Invoke-TestButton($Button) {
    if (!$Button -or !$Button.IsEnabled) { throw 'Test button is missing or disabled.' }
    $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
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
function New-FixtureTask([string]$Id, [string]$Title, [string]$Due, [int]$Order = 0) {
    @{ id = $Id; content = $Title; due = @{ date = $Due }; order = $Order }
}
function Find-DateCell([datetime]$Date) {
    $matches = @($ui.CalendarDays.Children | Where-Object { $_.Tag -is [datetime] -and $_.Tag.Date -eq $Date.Date })
    Assert-Equal $matches.Count 1 'Calendar has exactly one cell for requested date'
    $matches[0]
}
function Get-VisualText($Element) {
    if ($Element -is [Windows.Controls.TextBlock]) { $Element.Text }
    if ($Element -is [Windows.Media.Visual] -or $Element -is [Windows.Media.Media3D.Visual3D]) {
        $count = [Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
        for ($index = 0; $index -lt $count; $index++) {
            Get-VisualText ([Windows.Media.VisualTreeHelper]::GetChild($Element, $index))
        }
    }
}
function Assert-CalendarRange([datetime]$First, [datetime]$Last) {
    $cellCount = [int]($Last.Date - $First.Date).TotalDays + 1
    Assert-Equal $ui.CalendarDays.Children.Count $cellCount 'Month view has enough complete weeks to display all dates'
    Assert-Equal $ui.CalendarDays.Children[0].Tag.Date $First.Date 'First visible date aligns with Monday'
    Assert-Equal $ui.CalendarDays.Children[$cellCount - 1].Tag.Date $Last.Date 'Last visible date completes the month grid'
    for ($index = 1; $index -lt $cellCount; $index++) {
        Assert-Equal $ui.CalendarDays.Children[$index].Tag.Date $First.AddDays($index).Date 'Visible calendar dates are consecutive'
    }
}
function Assert-NoRequestsSince([int]$Count, [string]$Message) {
    Assert-Equal $script:testRequests.Count $Count $Message
}

try {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start.ps1'))
    foreach ($module in 'Runtime.ps1', 'Theme.ps1', 'Background.ps1', 'Calendar.ps1', 'FollowSettings.ps1') {
        $modulePath = (Join-Path $PSScriptRoot $module).Replace("'", "''")
        $source = $source.Replace(". (Join-Path `$PSScriptRoot '$module')", ". '$modulePath'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-calendar-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $realDataAssignment = "`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'"
    if (!$source.Contains($realDataAssignment)) { throw 'Cannot isolate widget settings directory.' }
    $source = $source.Replace($realDataAssignment, '$dataDir = $testDirectory')
    $source = $source.Replace('Todoist 桌面小组件', 'Todoist 日历测试')
    $source = $source.Replace('$window.ShowDialog() | Out-Null', '$timer.Stop(); $poll.Stop()')
    Invoke-Expression $source
    Assert-Equal $dataDir $testDirectory 'Fixture uses isolated settings directory'
    Assert-Equal $script:token '' 'Fixture never reads the real Todoist token'

    # The background worker serializes this function; it cannot access real APIs.
    function Api([string]$Method, [string]$Path, $Body = $null) {
        Start-Sleep -Milliseconds 450
        if ($Path -like '*failure*') { throw 'Simulated calendar completion failure' }
        if ($Method -eq 'Get') { @{ results = @(); next_cursor = $null } }
    }
    $script:testRequests = [Collections.Generic.List[object]]::new()
    $script:originalStartRequest = ${function:Start-Request}
    function Start-Request($Kind, $Method, $Path, $Body, $Context) {
        $script:testRequests.Add(@{ Kind = $Kind; Path = $Path })
        & $script:originalStartRequest $Kind $Method $Path $Body $Context
    }

    $window.Topmost = $false
    $window.Show()
    $window.UpdateLayout()
    $script:date = [datetime]'2026-08-20'
    $script:cachedTasks = @(
        (New-FixtureTask 'aug-1' 'Synthetic August first' '2026-08-01'),
        (New-FixtureTask 'aug-20-a' 'Synthetic preview A' '2026-08-20' 1),
        (New-FixtureTask 'aug-20-b' 'Synthetic preview B' '2026-08-20' 2),
        (New-FixtureTask 'aug-20-c' 'Synthetic preview C' '2026-08-20' 3),
        (New-FixtureTask 'aug-20-d' 'Synthetic preview D' '2026-08-20' 4),
        (New-FixtureTask 'next-month' 'Synthetic next month' '2026-09-01')
    )
    Render-Tasks
    Assert-Equal $script:viewMode 'List' 'Widget starts in original daily list view'
    Assert-Equal $ui.Tasks.Children.Count 4 'Daily list filters selected date'
    $window.Width = 430
    $window.Height = 510
    $requestCount = $script:testRequests.Count
    Invoke-TestButton $ui.ViewToggle
    $window.UpdateLayout()
    Assert-Equal $script:viewMode 'Calendar' 'Toolbar switches to calendar'
    Assert-Equal $ui.ListView.Visibility ([Windows.Visibility]::Collapsed) 'Calendar hides daily list'
    Assert-Equal $ui.CalendarView.Visibility ([Windows.Visibility]::Visible) 'Calendar view is visible'
    Assert-Equal $ui.Input.Visibility ([Windows.Visibility]::Collapsed) 'Month overview hides daily task input'
    Assert-Equal $ui.ViewToggle.Content '列表' 'Calendar offers return to list'
    if ($window.Width -lt 760 -or $window.Height -lt 580) { throw 'Calendar does not grow enough to display month cells.' }
    Assert-CalendarRange ([datetime]'2026-07-27') ([datetime]'2026-09-06')
    Assert-NoRequestsSince $requestCount 'Switching views reuses cached tasks without network requests'

    $previewCell = Find-DateCell ([datetime]'2026-08-20')
    $texts = @(Get-VisualText $previewCell)
    foreach ($title in 'Synthetic preview A', 'Synthetic preview B', 'Synthetic preview C') {
        if ($texts -notcontains $title) { throw "Month cell is missing task preview: $title" }
    }
    if ($texts -contains 'Synthetic preview D') { throw 'Overflow task should not occupy a fourth preview row.' }
    if ($texts -notcontains '另有 1 项') { throw 'Month cell does not indicate additional task count.' }
    if ([string]$previewCell.ToolTip -notlike '*Synthetic preview D*') { throw 'Tooltip does not expose overflow task title.' }
    if ([string](Find-DateCell ([datetime]'2026-09-01')).ToolTip -notlike '*Synthetic next month*') { throw 'Adjacent month tasks are missing.' }

    # Calendar strips react to live theme preview without requiring a rerender.
    $originalTheme = Get-NormalizedTheme $script:theme
    $ordinaryStrip = $previewCell.Content.Tag.Preview.Children[0]
    $originalStripColor = $ordinaryStrip.Background.Color.ToString()
    $changedTheme = Get-NormalizedTheme $originalTheme
    $changedTheme.Accent = '#FF00FF'
    Apply-Theme $changedTheme
    $window.UpdateLayout()
    if ($ordinaryStrip.Background.Color.ToString() -eq $originalStripColor) { throw 'Existing calendar task strip did not update during theme preview.' }
    Apply-Theme $originalTheme
    $window.UpdateLayout()
    Assert-Equal $ordinaryStrip.Background.Color.ToString() $originalStripColor 'Calendar strip restores original color after theme rollback'

    # Short six-week calendars hide rows and reserve a visible overflow footer.
    $window.Height = 440
    $window.UpdateLayout()
    $content = $previewCell.Content
    $cellState = $content.Tag
    $visibleStrips = @($cellState.Preview.Children | Where-Object { $_.Visibility -eq [Windows.Visibility]::Visible })
    if ($visibleStrips.Count -ge 3) { throw 'Small calendar still shows all previews instead of adapting to available cell height.' }
    Assert-Equal $cellState.More.Visibility ([Windows.Visibility]::Visible) 'Small cell exposes overflow footer'
    Assert-Equal $cellState.More.Text "另有 $($cellState.Count - $visibleStrips.Count) 项" 'Overflow count includes previews hidden by resize'
    $footerOrigin = $cellState.More.TransformToAncestor($content).Transform([Windows.Point]::new(0, 0))
    if ($footerOrigin.Y -lt -0.1 -or $footerOrigin.Y + $cellState.More.ActualHeight -gt $content.ActualHeight + 0.1) {
        throw 'Overflow footer is clipped outside the resized calendar cell.'
    }
    $window.Height = 720
    $window.UpdateLayout()
    Assert-Equal @($cellState.Preview.Children | Where-Object { $_.Visibility -eq [Windows.Visibility]::Visible }).Count 3 'Expanded calendar restores three task previews'
    Assert-Equal $cellState.More.Text '另有 1 项' 'Expanded calendar restores ordinary overflow count'

    # Rendering uses the latest shared task cache, including new and removed tasks.
    $script:cachedTasks = @((New-FixtureTask 'changed' 'Synthetic changed task' '2026-08-20'))
    Render-Tasks
    $window.UpdateLayout()
    $changedTexts = @(Get-VisualText (Find-DateCell ([datetime]'2026-08-20')))
    if ($changedTexts -notcontains 'Synthetic changed task' -or $changedTexts -contains 'Synthetic preview A') { throw 'Calendar did not refresh task previews from changed cache.' }
    Invoke-TestButton $ui.ViewToggle
    Assert-Equal $script:viewMode 'List' 'Toolbar restores daily list'
    Assert-Equal $window.Width 430.0 'Daily view restores customized width'
    Assert-Equal $window.Height 510.0 'Daily view restores customized height'
    Assert-Equal $ui.Input.Visibility ([Windows.Visibility]::Visible) 'Daily task input is restored'
    Assert-Equal $ui.ViewToggle.Content '月历' 'Daily view offers calendar toggle'
    Assert-Equal $ui.Tasks.Children.Count 1 'Daily view uses refreshed task cache'
    Assert-NoRequestsSince $requestCount 'View roundtrip does not reload tasks'

    Set-WidgetView 'Calendar'
    $script:date = [datetime]'2026-01-15'
    Render-Tasks
    Invoke-TestButton $ui.Previous
    Assert-Equal $script:date.ToString('yyyy-MM') '2025-12' 'Calendar previous navigates across year boundary'
    Assert-CalendarRange ([datetime]'2025-12-01') ([datetime]'2026-01-04')
    Invoke-TestButton $ui.Next
    Assert-Equal $script:date.ToString('yyyy-MM') '2026-01' 'Calendar next returns across year boundary'

    $script:date = [datetime]'2026-08-20'
    $script:cachedTasks = @((New-FixtureTask 'adjacent' 'Synthetic adjacent date task' '2026-07-27'))
    Render-Tasks
    Invoke-TestButton (Find-DateCell ([datetime]'2026-07-27'))
    Assert-Equal $script:date.Date ([datetime]'2026-07-27') 'Clicking adjacent day selects its actual date'
    Assert-Equal $script:viewMode 'List' 'Clicking a day opens daily list'
    Assert-Equal $ui.Tasks.Children.Count 1 'Clicked adjacent day displays its own tasks'
    Invoke-TestButton $ui.Next
    Assert-Equal $script:date.Date ([datetime]'2026-07-28') 'Daily next still advances one day'
    Invoke-TestButton $ui.Previous
    Assert-Equal $script:date.Date ([datetime]'2026-07-27') 'Daily previous still advances one day'

    # Completion remains one asynchronous request when views change before it finishes.
    $script:token = 'synthetic-test-token'
    $script:date = [datetime]'2026-08-20'
    $script:cachedTasks = @((New-FixtureTask 'completion-success' 'Synthetic completion success' '2026-08-20'))
    Render-Tasks
    $window.UpdateLayout()
    $state = $ui.Tasks.Children[0].Child.Children[0].Tag
    $state.Check.IsChecked = $true
    Animate-Complete $state.Check
    $requestCount = $script:testRequests.Count
    Set-WidgetView 'Calendar'
    $window.UpdateLayout()
    if ([string](Find-DateCell $script:date).ToolTip -like '*Synthetic completion success*') { throw 'Calendar still previews a pending completed task.' }
    Set-WidgetView 'List'
    $window.UpdateLayout()
    Assert-Equal $script:pending.Count 1 'Pending completion survives view roundtrip'
    Assert-Equal $ui.Tasks.Children.Count 1 'Daily view preserves pending animated row'
    if (![object]::ReferenceEquals($ui.Tasks.Children[0], $state.Border)) { throw 'Pending row was recreated, losing completion state.' }
    Assert-Equal $state.Check.IsEnabled $false 'Pending task stays disabled after view roundtrip'
    Assert-Equal $state.Check.IsChecked $true 'Pending task keeps its check mark after view roundtrip'
    Animate-Complete $state.Check
    Assert-NoRequestsSince $requestCount 'Pending task cannot issue duplicate completion request'
    $poll.Start()
    Pump 1700
    Assert-Equal $script:pending.Count 0 'Successful completion finishes after switching views'
    Assert-Equal $ui.Tasks.Children.Count 0 'Completed row is removed'
    Assert-Equal @($script:testRequests | Where-Object { $_.Kind -eq 'Close' -and $_.Path -like '*completion-success*' }).Count 1 'Exactly one successful completion request was made'

    $script:cachedTasks = @((New-FixtureTask 'completion-failure' 'Synthetic completion failure' '2026-08-20'))
    Render-Tasks
    $window.UpdateLayout()
    $state = $ui.Tasks.Children[0].Child.Children[0].Tag
    $state.Check.IsChecked = $true
    Animate-Complete $state.Check
    $requestCount = $script:testRequests.Count
    Set-WidgetView 'Calendar'
    Set-WidgetView 'List'
    Assert-NoRequestsSince $requestCount 'Failure roundtrip does not issue another API request'
    Pump 850
    Assert-Equal $script:pending.Count 0 'Failed completion rolls back pending state'
    Assert-Equal $ui.Tasks.Children.Count 1 'Failed completion restores daily task'
    $restoredCheck = $ui.Tasks.Children[0].Child.Children[0]
    Assert-Equal $restoredCheck.IsEnabled $true 'Rolled back task can be completed again'
    Assert-Equal $restoredCheck.IsChecked $false 'Rolled back task is unchecked'
    Set-WidgetView 'Calendar'
    if ([string](Find-DateCell $script:date).ToolTip -notlike '*Synthetic completion failure*') { throw 'Rolled back task did not return to calendar.' }

    Write-Output 'PASS: month grid, adaptive task previews, live theme colors, date navigation, view size roundtrip, and asynchronous completion during view switches.'
}
finally {
    if ($window) { $window.Close() }
    $resolvedTarget = [IO.Path]::GetFullPath($testDirectory).TrimEnd('\')
    $resolvedParent = [IO.Path]::GetDirectoryName($resolvedTarget)
    if ($resolvedParent -cne $root -or [IO.Path]::GetFileName($resolvedTarget) -cne $folderName -or $resolvedTarget -ceq $root) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}
