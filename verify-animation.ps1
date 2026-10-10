$ErrorActionPreference='Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$testDirectory = Join-Path $root ('.animation-ui-test-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testDirectory)
$window = $null
try {
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start.ps1'))
$runtimePath=(Join-Path $PSScriptRoot 'Runtime.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Runtime.ps1')", ". '$runtimePath'")
$themeModulePath=(Join-Path $PSScriptRoot 'Theme.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Theme.ps1')", ". '$themeModulePath'")
$backgroundModulePath=(Join-Path $PSScriptRoot 'Background.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Background.ps1')", ". '$backgroundModulePath'")
$calendarModulePath=(Join-Path $PSScriptRoot 'Calendar.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'Calendar.ps1')", ". '$calendarModulePath'")
$followSettingsModulePath=(Join-Path $PSScriptRoot 'FollowSettings.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'FollowSettings.ps1')", ". '$followSettingsModulePath'")
$positionModulePath=(Join-Path $PSScriptRoot 'WindowPosition.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'WindowPosition.ps1')", ". '$positionModulePath'")
$clockModulePath=(Join-Path $PSScriptRoot 'ClockSettings.ps1').Replace("'", "''")
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'ClockSettings.ps1')", ". '$clockModulePath'")
$source=$source.Replace("`$backgroundPath = Join-Path `$dataDir 'background.json'", "`$backgroundPath = Join-Path `$dataDir 'animation-test-no-background.json'")
$source=$source.Replace("`$themePath = Join-Path `$dataDir 'theme.json'", "`$themePath = Join-Path `$dataDir 'animation-test-no-theme.json'")
$source=$source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-animation-test")')
$source=$source.Replace('if (Test-WidgetOpen) { return }', '')
$fixtureDataPath = $testDirectory.Replace("'", "''")
$fixtureTokenPath = (Join-Path $testDirectory 'token.dat').Replace("'", "''")
$source=$source.Replace("`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'", "`$dataDir = '$fixtureDataPath'")
$source=$source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$fixtureTokenPath'")
$source=$source.Replace('Todoist 桌面小组件', 'Todoist 动画测试')
Invoke-Expression ($source.Replace('$window.ShowDialog() | Out-Null','$timer.Stop(); $poll.Stop()'))
if ($dataDir -cne $testDirectory -or $tokenPath -cne (Join-Path $testDirectory 'token.dat') -or ![string]::IsNullOrEmpty($script:token)) { throw 'Animation fixture is not isolated.' }
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
} finally {
    if ($null -ne $window) { $window.Close() }
    $resolvedDirectory = [IO.Path]::GetFullPath($testDirectory)
    $expectedParent = $root + '\'
    if (!$resolvedDirectory.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolvedDirectory) { Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force }
}
