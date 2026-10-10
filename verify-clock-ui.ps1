$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = Join-Path $root ('.clock-ui-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$window = $null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Pump-Dispatcher([int]$Milliseconds) {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $stop = [Windows.Threading.DispatcherTimer]::new()
    $stop.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $stop.Tag = $frame
    $stop.Add_Tick({ $this.Tag.Continue = $false; $this.Stop() })
    $stop.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Get-HeaderBounds($Element) {
    $point = $Element.TranslatePoint([Windows.Point]::new(0, 0), $ui.Header)
    return @{ Left = $point.X; Right = $point.X + $Element.ActualWidth }
}
function Test-HeaderLayout([double]$Width, [string]$Format) {
    $window.Width = $Width
    $ui.Clock.Text = Format-WidgetClock -DateTime ([DateTime]::new(2026, 10, 10, 13, 59, 59)) -Format $Format
    $window.UpdateLayout()
    $title = Get-HeaderBounds $ui.Header.Children[0]
    $buttons = Get-HeaderBounds $ui.MenuButton.Parent
    if ($title.Right -gt $buttons.Left + 1 -or $buttons.Right -gt $ui.Header.ActualWidth + 1) {
        throw "Header controls overlap or overflow at $Width px in $Format format."
    }
    $clockOrigin = $ui.ClockSurface.TranslatePoint([Windows.Point]::new(0, 0), $ui.Header.Parent)
    if ($clockOrigin.X -lt -1 -or $clockOrigin.X + $ui.ClockSurface.ActualWidth -gt $ui.Header.ActualWidth + 1) {
        throw "Clock surface overflows at $Width px in $Format format."
    }
    if ($ui.Clock.ActualWidth + 1 -lt $ui.Clock.DesiredSize.Width) {
        throw "Clock text is clipped at $Width px in $Format format (actual $($ui.Clock.ActualWidth), desired $($ui.Clock.DesiredSize.Width))."
    }
    if ($ui.Clock.FontSize -le $ui.ViewToggle.FontSize) { throw 'Clock must be larger than the view button labels.' }
    if ($ui.Clock.FontWeight -lt [Windows.FontWeights]::SemiBold) { throw 'Clock font weight is too light.' }
    if ($ui.ClockSurface.Background.Opacity -lt 0.9) { throw 'Clock surface is too transparent to read over a wallpaper.' }
}
function Test-ClockFormatDialog([int]$ExpectedIndex, [int]$NewIndex) {
    $script:clockDialogState = @{ Expected = $ExpectedIndex; New = $NewIndex; Completed = $false; Failure = $null }
    $probe = [Windows.Threading.DispatcherTimer]::new()
    $probe.Interval = [TimeSpan]::FromMilliseconds(30)
    $probe.Add_Tick({
        $dialog = @($window.OwnedWindows | Where-Object { $_.Title -eq '显示内容' }) | Select-Object -First 1
        if (!$dialog) { return }
        try {
            $choice = $dialog.FindName('ClockFormat')
            if (!$choice) { throw 'Clock format selector is missing.' }
            Assert-Equal $choice.SelectedIndex $script:clockDialogState.Expected 'Display dialog loads the saved clock format'
            if ($script:clockDialogState.New -ge 0) {
                $choice.SelectedIndex = $script:clockDialogState.New
                $expectedFormat = $(if ($script:clockDialogState.New -eq 1) { '12h' } else { '24h' })
                Assert-Equal $script:clockFormat $expectedFormat 'Clock format switches immediately'
                Assert-Equal (Read-ClockSettings -Path $clockSettingsPath).Format $expectedFormat 'Clock format persists locally'
                Assert-Equal $ui.Clock.Text (Format-WidgetClock -DateTime ([DateTime]::Now) -Format $expectedFormat) 'Visible clock switches immediately'
            }
            $script:clockDialogState.Completed = $true
        } catch {
            $script:clockDialogState.Failure = $_
        } finally {
            $this.Stop()
            $dialog.DialogResult = $false
        }
    })
    $probe.Start()
    try { Configure-Display } finally { $probe.Stop() }
    if ($script:clockDialogState.Failure) { throw $script:clockDialogState.Failure }
    if (!$script:clockDialogState.Completed) { throw 'Clock format dialog did not finish.' }
}

try {
    $fakeFollowPath = Join-Path $fixture 'FollowSettings.ps1'
    [IO.File]::WriteAllText($fakeFollowPath, 'function Get-FollowEnabled { return $false }', [Text.UTF8Encoding]::new($true))
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start.ps1'), [Text.Encoding]::UTF8)
    foreach ($module in 'Runtime.ps1','Theme.ps1','Background.ps1','Calendar.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1','DisplaySettings.ps1') {
        $modulePath = $(if ($module -eq 'FollowSettings.ps1') { $fakeFollowPath } else { Join-Path $root $module }).Replace("'", "''")
        $source = $source.Replace("(Join-Path `$PSScriptRoot '$module')", "'$modulePath'")
        $source = $source.Replace("Join-Path `$PSScriptRoot '$module'", "'$modulePath'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-clock-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $dataAssignment = "`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'"
    if (!$source.Contains($dataAssignment)) { throw 'Cannot isolate clock settings directory.' }
    $source = $source.Replace($dataAssignment, "`$dataDir = '$($fixture.Replace("'", "''"))'")
    $source = $source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$(Join-Path $fixture 'token.dat')'")
    $source = $source.Replace('$window.Add_ContentRendered({ Load-Tasks })', '')
    $source = $source.Replace('$window.ShowDialog() | Out-Null', '$timer.Stop(); $poll.Stop()')
    Invoke-Expression $source
    Assert-Equal $dataDir $fixture 'UI test stores settings only in the fixture directory'
    Assert-Equal $script:clockFormat '24h' 'Widget starts with a 24-hour clock'
    if ([IO.File]::Exists($clockSettingsPath) -or [IO.File]::Exists($tokenPath)) { throw 'Startup created a saved clock preference or token unexpectedly.' }

    $window.Topmost = $false
    $window.ShowActivated = $false
    $window.Opacity = 0
    $window.Show()
    $window.UpdateLayout()
    $clockTimer.Stop()
    Test-HeaderLayout 400 '24h'
    Test-HeaderLayout 400 '12h'
    Test-HeaderLayout 340 '24h'
    Test-HeaderLayout 340 '12h'
    if (!(Test-HeaderDragSource $ui.Clock)) { throw 'Clock surface cannot be used to move the widget.' }
    if (Test-HeaderDragSource $ui.MenuButton) { throw 'Menu button was mistaken for a drag handle.' }
    Apply-Background @{ Mode='Color'; ImagePath=''; Opacity=0.0; Overlay=0.5 }
    Test-HeaderLayout 340 '12h'
    $ui.MenuButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    if (!$ui.MenuButton.ContextMenu.IsOpen) { throw 'Menu cannot open over a transparent background.' }
    if ($ui.MenuButton.ContextMenu.Background.Opacity -lt 0.9) { throw 'Menu surface is too transparent to read over a wallpaper.' }
    foreach ($item in @($ui.MenuButton.ContextMenu.Items)) {
        if ($item.Foreground.Color -ne $window.Resources['WidgetForeground'].Color) { throw 'Menu item text does not use the readable theme foreground.' }
    }
    $ui.MenuButton.ContextMenu.IsOpen = $false
    $window.Width = 400
    Update-ClockDisplay

    Test-ClockFormatDialog 0 1
    Test-ClockFormatDialog 1 -1
    Test-ClockFormatDialog 1 0
    $first = $ui.Clock.Text
    $clockTimer.Start()
    Pump-Dispatcher 1400
    if ($ui.Clock.Text -ceq $first) { throw 'Clock seconds did not refresh while the window was open.' }
    Assert-Equal (Read-ClockSettings -Path $clockSettingsPath).Format '24h' 'Last selection survives settings reopening'
    $window.Close()
    Assert-Equal $clockTimer.IsEnabled $false 'Closing the widget stops the clock timer'
    'PASS: readable large clock, 340/400 px layout, transparent background, immediate 12/24-hour switch, and local persistence.'
} finally {
    if ($window -and $window.IsVisible) { $window.Close() }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
