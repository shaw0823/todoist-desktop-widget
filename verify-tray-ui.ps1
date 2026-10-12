$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = Join-Path $root ('.tray-ui-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$script:traySignalNameOverride = 'Local\TodoistWidgetTrayTest-' + [Guid]::NewGuid().ToString('N')
$window = $null

try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start.ps1'), [Text.Encoding]::UTF8)
    $modules = @('Runtime.ps1','Tray.ps1','Theme.ps1','Background.ps1','Calendar.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1','DisplaySettings.ps1')
    foreach ($module in $modules) {
        $modulePath = (Join-Path $root $module).Replace("'", "''")
        $source = $source.Replace(". (Join-Path `$PSScriptRoot '$module')", ". '$modulePath'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-tray-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $source = $source.Replace("`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'", "`$dataDir = '$($fixture.Replace("'", "''"))'")
    $source = $source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$(Join-Path $fixture 'token.dat')'")
    $source = $source.Replace('$window.Add_ContentRendered({ Load-Tasks })', '')
    if (!$source.Contains('Start-WidgetMessageLoop -Window $window')) { throw 'Widget message loop entry point changed.' }
    $probe = @'
$window.Opacity = 0
$window.ShowActivated = $false
$window.Topmost = $false
$timer.Stop(); $poll.Stop()
$script:trayProbeStep = 0
$script:trayProbeAttempts = 0
$script:trayProbeError = $null
$trayProbe = [Windows.Threading.DispatcherTimer]::new()
$trayProbe.Interval = [TimeSpan]::FromMilliseconds(100)
$trayProbe.Add_Tick({
    try {
        switch ($script:trayProbeStep) {
            0 {
                if (!$script:trayIcon.Visible -or !$window.IsVisible) { throw 'Widget or tray icon did not open.' }
                $script:trayHintShown = $true
                $ui.Close.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                if ($window.IsVisible -or !$script:trayIcon.Visible) { throw 'Close button did not hide to tray.' }
                $script:trayProbeStep = 1
            }
            1 {
                $script:trayShowItem.PerformClick()
                if (!$window.IsVisible) { throw 'Tray Show did not restore the widget.' }
                $script:trayProbeStep = 2
            }
            2 {
                $script:trayHideItem.PerformClick()
                if ($window.IsVisible) { throw 'Tray Hide did not hide the widget.' }
                Request-WidgetShow
                $script:trayProbeStep = 3
            }
            3 {
                if ($window.IsVisible) { $script:trayProbeStep = 4 }
                else {
                    $script:trayProbeAttempts++
                    if ($script:trayProbeAttempts -gt 20) { throw 'Second shortcut launch did not restore the widget.' }
                }
            }
            4 {
                $this.Stop()
                $script:trayExitItem.PerformClick()
                $script:trayProbeStep = 5
            }
        }
    } catch {
        $script:trayProbeError = $_
        $this.Stop()
        Exit-WidgetFromTray
    }
})
$trayProbe.Start()
Start-WidgetMessageLoop -Window $window
'@
    $source = $source.Replace('Start-WidgetMessageLoop -Window $window', $probe)
    Invoke-Expression $source
    if ($script:trayProbeError) { throw $script:trayProbeError }
    if ($script:trayProbeStep -ne 5) { throw "Tray flow stopped at step $script:trayProbeStep." }
    if ($null -ne $script:trayIcon -or $null -ne $script:trayShowSignal) { throw 'Tray resources remained after exit.' }
    if ($clockTimer.IsEnabled) { throw 'Clock timer remained active after tray exit.' }
    if (![IO.File]::Exists((Join-Path $fixture 'window-position.json'))) { throw 'Hiding to tray did not save the window position.' }
    'PASS: close hides to tray, tray shows/hides, shortcut reopens, explicit exit releases resources, and position persists.'
} finally {
    $script:traySignalNameOverride = $null
    if ($window -and $window.IsVisible) { $window.Close() }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith($root + '\.tray-ui-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
