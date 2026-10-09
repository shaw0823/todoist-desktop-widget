$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start.ps1'))
$runtimePath=(Join-Path $PSScriptRoot 'Runtime.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Runtime.ps1')", ". '$runtimePath'")
$themeModulePath=(Join-Path $PSScriptRoot 'Theme.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Theme.ps1')", ". '$themeModulePath'")
$backgroundModulePath=(Join-Path $PSScriptRoot 'Background.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Background.ps1')", ". '$backgroundModulePath'")
$calendarModulePath=(Join-Path $PSScriptRoot 'Calendar.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Calendar.ps1')", ". '$calendarModulePath'")
$source=$source.Replace("`$backgroundPath = Join-Path `$dataDir 'background.json'", "`$backgroundPath = Join-Path `$dataDir 'animation-test-no-background.json'")
$source=$source.Replace("`$themePath = Join-Path `$dataDir 'theme.json'", "`$themePath = Join-Path `$dataDir 'animation-test-no-theme.json'")
$source=$source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-animation-test")')
$source=$source.Replace('if (Test-WidgetOpen) { return }', '')
$source=$source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = Join-Path `$dataDir 'animation-test-no-token.dat'")
$source=$source.Replace('Todoist 桌面小组件', 'Todoist 动画测试')
Invoke-Expression ($source.Replace('$window.ShowDialog() | Out-Null','$timer.Stop(); $poll.Stop()'))
$script:token='test-only'
function Api([string]$method,[string]$path,$body=$null) {
    Start-Sleep -Milliseconds 450
    if ($path -like '*fail*') { throw 'Simulated network failure' }
    if ($method -eq 'Get') { @{results=@();next_cursor=$null} }
}
function Pump([int]$milliseconds) {
    $frame=[Windows.Threading.DispatcherFrame]::new()
    $end=[Windows.Threading.DispatcherTimer]::new()
    $end.Interval=[TimeSpan]::FromMilliseconds($milliseconds)
    $end.Tag=$frame
    $end.Add_Tick({$this.Tag.Continue=$false; $this.Stop()})
    $end.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function FakeTask($id) { @{id=$id;content='Animation test';due=@{date=[DateTime]::Today.ToString('yyyy-MM-dd')};order=1} }
$script:cachedTasks=@((FakeTask 'success')); Render-Tasks
$window.Show(); $window.UpdateLayout()
$state=$ui.Tasks.Children[0].Child.Children[0].Tag
$clock=[Diagnostics.Stopwatch]::StartNew(); $state.Check.IsChecked=$true; Animate-Complete $state.Check; $clock.Stop()
if ($clock.ElapsedMilliseconds -gt 350) { throw 'Click blocked on network' }
$poll.Start(); Pump 1300
if ($script:pending.Count -or $script:cachedTasks.Count) { throw 'Successful task not removed' }
$script:cachedTasks=@((FakeTask 'fail')); Render-Tasks; $window.UpdateLayout()
$state=$ui.Tasks.Children[0].Child.Children[0].Tag
$state.Check.IsChecked=$true; Animate-Complete $state.Check; Pump 800
if ($script:pending.Count -or $ui.Tasks.Children.Count -ne 1 -or !$ui.Tasks.Children[0].Child.Children[0].IsEnabled -or $ui.Tasks.Children[0].Child.Children[0].IsChecked) { throw 'Failure rollback failed' }
$window.Close()
'PASS: nonblocking click, success animation/removal, failure rollback'
