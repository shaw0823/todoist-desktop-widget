$ErrorActionPreference = 'Stop'
$testDirectory = Join-Path $PSScriptRoot ('.theme-ui-test-' + [Guid]::NewGuid().ToString('N'))
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start.ps1'))
foreach ($module in 'Runtime.ps1','Theme.ps1','Background.ps1','Calendar.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1') {
    $modulePath = (Join-Path $PSScriptRoot $module).Replace("'", "''")
    $source = $source.Replace(". (Join-Path `$PSScriptRoot '$module')", ". '$modulePath'")
}
$source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-theme-ui-test")')
$source = $source.Replace('if (Test-WidgetOpen) { return }', '')
$fixtureDataPath = $testDirectory.Replace("'", "''")
$fixtureTokenPath = (Join-Path $testDirectory 'token.dat').Replace("'", "''")
$source = $source.Replace("`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'", "`$dataDir = '$fixtureDataPath'")
$source = $source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$fixtureTokenPath'")
$source = $source.Replace('Todoist 桌面小组件', 'Todoist 配色测试')
$source = $source.Replace('$window.ShowDialog() | Out-Null', '$timer.Stop(); $poll.Stop()')
Invoke-Expression $source
if ($dataDir -cne $testDirectory -or $tokenPath -cne (Join-Path $testDirectory 'token.dat') -or ![string]::IsNullOrEmpty($script:token)) { throw 'Theme fixture is not isolated.' }
$window.Show()

function Test-ThemeDialog([string]$mode) {
    $testTimer = [Windows.Threading.DispatcherTimer]::new()
    $testTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $testTimer.Tag = @{Mode=$mode; Failure=$null; Completed=$false; Attempts=0}
    $testTimer.Add_Tick({
        $state = $this.Tag
        $state.Attempts++
        $dialog = @($window.OwnedWindows | Where-Object { $_.Title -eq '外观设置' }) | Select-Object -First 1
        if (!$dialog) {
            if ($state.Attempts -gt 30) { $this.Stop(); throw 'Theme dialog did not open' }
            return
        }
        $this.Stop()
        try {
            $dialog.FindName('BackgroundColor').Text = '#123456'
            if ($script:theme.Background -ne '#123456') { throw 'Live preview did not apply' }
            $dialog.FindName('AccentColor').Text = 'bad-hex'
            if ($dialog.FindName('SaveColors').IsEnabled) { throw 'Invalid color can be saved' }
            $dialog.FindName('AccentColor').Text = '#ABC'
            if (!$dialog.FindName('SaveColors').IsEnabled) { throw 'Valid short color cannot be saved' }
            if ($state.Mode -eq 'Cancel') {
                $dialog.DialogResult = $false
            } else {
                $dialog.FindName('Preset').SelectedItem = '浅色'
                if ($script:theme.Background -ne '#F4F6F8') { throw 'Preset preview failed' }
                $dialog.FindName('SaveColors').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($dialog.IsVisible) { throw 'Save did not close the theme dialog' }
            }
            $state.Completed = $true
        } catch {
            $state.Failure = $_
            $dialog.Close()
        }
    })
    $testTimer.Start()
    try { Configure-Theme } finally { $testTimer.Stop() }
    if ($testTimer.Tag.Failure) { throw $testTimer.Tag.Failure }
    if (!$testTimer.Tag.Completed) { throw 'Theme dialog action did not run' }
}
try {
    Test-ThemeDialog 'Cancel'
    if ($script:theme.Background -ne '#263F43' -or (Test-Path -LiteralPath $themePath)) { throw 'Cancel did not restore the original theme' }
    Test-ThemeDialog 'Save'
    $persisted = Read-Theme $themePath
    if ($persisted.Background -ne '#F4F6F8' -or $script:theme.Background -ne '#F4F6F8') { throw 'Save did not persist the theme' }
    if ($ui.BackgroundFill.Background.Color.ToString() -ne '#FFF4F6F8') { throw 'Widget background did not update' }
    'PASS: live preview, input validation, cancel rollback, presets, UI save and reload'
} finally {
    $window.Close()
    $resolvedDirectory = [IO.Path]::GetFullPath($testDirectory)
    $expectedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (!$resolvedDirectory.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $resolvedDirectory) { Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force }
}
