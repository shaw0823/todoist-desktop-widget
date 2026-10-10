$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = Join-Path $root ('.display-ui-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$window = $null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Click($Control) {
    $event = $(if ($Control -is [Windows.Controls.MenuItem]) { [Windows.Controls.MenuItem]::ClickEvent } else { [Windows.Controls.Primitives.ButtonBase]::ClickEvent })
    $Control.RaiseEvent([Windows.RoutedEventArgs]::new($event))
}
function Set-Check($Check, [bool]$Enabled) {
    $Check.IsChecked = $Enabled
    Click $Check
}
function Test-DisplayDialog([string]$Phase) {
    $script:dialogProbe = @{Phase=$Phase; Finished=$false; Error=$null; Attempts=0}
    $probe = [Windows.Threading.DispatcherTimer]::new()
    $probe.Interval = [TimeSpan]::FromMilliseconds(40)
    $probe.Add_Tick({
        $script:dialogProbe.Attempts++
        $dialog = @($window.OwnedWindows | Where-Object { $_.Title -eq '显示内容' }) | Select-Object -First 1
        if (!$dialog) {
            if ($script:dialogProbe.Attempts -gt 100) { throw 'Display dialog did not appear.' }
            return
        }
        try {
            $clock = $dialog.FindName('ShowClock')
            $calendar = $dialog.FindName('ShowCalendar')
            $list = $dialog.FindName('ShowList')
            if (!$clock -or !$calendar -or !$list) { throw 'Display controls are missing.' }
            if ($script:dialogProbe.Phase -eq 'all-off') {
                Assert-Equal ([bool]$clock.IsChecked) $true 'Clock defaults on'
                Assert-Equal ([bool]$calendar.IsChecked) $true 'Calendar defaults on'
                Assert-Equal ([bool]$list.IsChecked) $true 'List defaults on'

                Set-Check $clock $false
                Assert-Equal $ui.ClockSurface.Visibility ([Windows.Visibility]::Collapsed) 'Clock can be hidden'
                Assert-Equal $clockTimer.IsEnabled $false 'Hidden clock stops timer'
                Assert-Equal $ui.MenuButton.Visibility ([Windows.Visibility]::Visible) 'Menu remains accessible'

                Set-Check $calendar $false
                Assert-Equal $script:viewMode 'List' 'List stays active if calendar is disabled'
                Assert-Equal $ui.ViewToggle.Visibility ([Windows.Visibility]::Collapsed) 'No switch when only list is enabled'
                Assert-Equal $ui.DateNavigation.Visibility ([Windows.Visibility]::Visible) 'Date navigation stays with list'

                Set-Check $list $false
                Assert-Equal $script:viewMode 'Minimal' 'Both disabled use compact view'
                Assert-Equal $ui.DateNavigation.Visibility ([Windows.Visibility]::Collapsed) 'Compact view hides date navigation'
                Assert-Equal $ui.Input.Visibility ([Windows.Visibility]::Collapsed) 'Compact view hides task input'
                Assert-Equal $ui.ListView.Visibility ([Windows.Visibility]::Collapsed) 'Compact view hides list'
                Assert-Equal $ui.CalendarView.Visibility ([Windows.Visibility]::Collapsed) 'Compact view hides calendar'
                Assert-Equal $ui.Status.Visibility ([Windows.Visibility]::Collapsed) 'Compact view hides task status'
                Assert-Equal $ui.NoViewsHint.Visibility ([Windows.Visibility]::Visible) 'Compact view offers recovery hint'
                Assert-Equal $window.Height 140.0 'Compact view has its own size'
                Assert-Equal $ui.SettingsMenuItem.IsEnabled $true 'Settings remain accessible in the menu'

                Set-Check $clock $true
                Assert-Equal $ui.ClockSurface.Visibility ([Windows.Visibility]::Visible) 'Clock can be restored independently'
                Assert-Equal $clockTimer.IsEnabled $true 'Restored clock resumes timer'
                $saved = Read-DisplaySettings -Path $displaySettingsPath
                Assert-Equal $saved.ShowClock $true 'Clock toggle persists'
                Assert-Equal $saved.ShowCalendar $false 'Calendar toggle persists'
                Assert-Equal $saved.ShowList $false 'List toggle persists'
            } elseif ($script:dialogProbe.Phase -eq 'restore') {
                Assert-Equal ([bool]$clock.IsChecked) $true 'Clock checkbox reloads'
                Assert-Equal ([bool]$calendar.IsChecked) $false 'Calendar checkbox reloads'
                Assert-Equal ([bool]$list.IsChecked) $false 'List checkbox reloads'
                Set-Check $list $true
                Assert-Equal $script:viewMode 'List' 'List returns from compact view'
                Assert-Equal $ui.NoViewsHint.Visibility ([Windows.Visibility]::Collapsed) 'Hint disappears after restoring list'
                Assert-Equal $ui.DateNavigation.Visibility ([Windows.Visibility]::Visible) 'Navigation returns with list'
                Set-Check $calendar $true
                Assert-Equal $ui.ViewToggle.Visibility ([Windows.Visibility]::Visible) 'View switch returns when both views are enabled'
            } elseif ($script:dialogProbe.Phase -eq 'calendar-only') {
                Set-Check $list $false
                Assert-Equal $script:viewMode 'Calendar' 'Calendar remains active when list is disabled'
                Assert-Equal $ui.ViewToggle.Visibility ([Windows.Visibility]::Collapsed) 'Calendar-only has no view switch'
            }
            $script:dialogProbe.Finished = $true
        } catch { $script:dialogProbe.Error = $_ }
        finally {
            $this.Stop()
            $dialog.DialogResult = $false
        }
    })
    $probe.Start()
    try {
        Click $ui.MenuButton
        Assert-Equal $ui.MenuButton.ContextMenu.IsOpen $true 'Menu opens from the header'
        Click $ui.DisplayMenuItem
        Assert-Equal $ui.MenuButton.ContextMenu.IsOpen $false 'Menu closes before displaying the dialog'
    } finally { $probe.Stop() }
    if ($script:dialogProbe.Error) { throw $script:dialogProbe.Error }
    if (!$script:dialogProbe.Finished) { throw 'Display dialog probe did not complete.' }
}

try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start.ps1'), [Text.Encoding]::UTF8)
    foreach ($module in 'Runtime.ps1','Theme.ps1','Background.ps1','Calendar.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1','DisplaySettings.ps1') {
        $modulePath = (Join-Path $root $module).Replace("'", "''")
        $source = $source.Replace(". (Join-Path `$PSScriptRoot '$module')", ". '$modulePath'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-display-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $dataAssignment = "`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'"
    if (!$source.Contains($dataAssignment)) { throw 'Cannot isolate display settings directory.' }
    $source = $source.Replace($dataAssignment, "`$dataDir = '$($fixture.Replace("'", "''"))'")
    $source = $source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$(Join-Path $fixture 'token.dat')'")
    $source = $source.Replace('$window.Add_ContentRendered({ Load-Tasks })', '')
    $source = $source.Replace('$window.ShowDialog() | Out-Null', '$timer.Stop(); $poll.Stop()')
    Invoke-Expression $source
    Assert-Equal $dataDir $fixture 'UI test uses isolated settings'
    if ([IO.File]::Exists($displaySettingsPath) -or [IO.File]::Exists($tokenPath)) { throw 'Startup wrote display settings or token unexpectedly.' }
    $window.Topmost = $false
    $window.ShowActivated = $false
    $window.Opacity = 0
    $window.Show()
    $window.UpdateLayout()

    Assert-Equal (@($ui.MenuButton.ContextMenu.Items | ForEach-Object { $_.Header }) -join ',') '外观,显示内容,设置' 'Menu entries and order'
    Test-DisplayDialog 'all-off'
    $window.Close()
    Invoke-Expression $source
    Assert-Equal $dataDir $fixture 'Restart still uses isolated settings'
    Assert-Equal $script:token '' 'Restart never reads a real API token'
    $window.Topmost = $false
    $window.ShowActivated = $false
    $window.Opacity = 0
    $window.Show()
    $window.UpdateLayout()
    Assert-Equal $script:viewMode 'Minimal' 'Restart restores compact view from saved switches'
    Assert-Equal $ui.DateNavigation.Visibility ([Windows.Visibility]::Collapsed) 'Restart keeps both task views hidden'
    Assert-Equal $ui.ClockSurface.Visibility ([Windows.Visibility]::Visible) 'Restart preserves independent clock state'
    Test-DisplayDialog 'restore'
    Click $ui.ViewToggle
    Assert-Equal $script:viewMode 'Calendar' 'Calendar still selectable after restoring both views'
    Test-DisplayDialog 'calendar-only'
    $script:date = [DateTime]::new(2026, 10, 10)
    Render-Tasks
    $cell = @($ui.CalendarDays.Children | Where-Object { $_.Tag -is [DateTime] -and $_.Tag.Date -eq $script:date.Date }) | Select-Object -First 1
    if (!$cell) { throw 'Calendar test date is missing.' }
    Click $cell
    Assert-Equal $script:viewMode 'Calendar' 'Calendar date cannot open a disabled list'
    Assert-Equal (Read-DisplaySettings -Path $displaySettingsPath).ShowList $false 'Final calendar-only choice persists'
    $window.Close()
    'PASS: themed settings menu, independent clock/calendar/list toggles, compact view, recovery, persistence, and guarded calendar clicks.'
} finally {
    if ($window -and $window.IsVisible) { $window.Close() }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
