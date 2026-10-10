$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$testDirectory = Join-Path $root ('.follow-settings-ui-test-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testDirectory)
$window = $null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Write-TestFollowState([bool]$Enabled) {
    [IO.File]::WriteAllText((Join-Path $testDirectory 'follow-state.json'), ($Enabled | ConvertTo-Json -Compress))
}
function Read-TestFollowState {
    return [bool]([IO.File]::ReadAllText((Join-Path $testDirectory 'follow-state.json')) | ConvertFrom-Json)
}
function Get-TestFollowCallCount {
    $path = Join-Path $testDirectory 'follow-calls.txt'
    if (!(Test-Path -LiteralPath $path)) { return 0 }
    return [IO.File]::ReadAllLines($path).Count
}
function Invoke-TestControl($Dialog, [string]$Name) {
    $control = $Dialog.FindName($Name)
    if (!$control -or !$control.IsEnabled) { throw "Control $Name is missing or disabled." }
    $control.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
}
function Close-TestSettings($Dialog) {
    $button = $Dialog.FindName('CloseSettings')
    if (!$button -or !$button.IsEnabled -or !$button.IsCancel) { throw 'Settings close button is missing or unavailable.' }
    # Raising Click alone does not execute WPF Button.OnClick's IsCancel logic.
    $Dialog.DialogResult = $false
}
function Test-FollowDialog([bool]$Initial, $Desired, [bool]$Fail = $false, [bool]$EmptyTokenSave = $false, [bool]$CloseEarly = $false, [bool]$ReopenPending = $false) {
    if (!$ReopenPending) { Write-TestFollowState $Initial }
    $failurePath = Join-Path $testDirectory 'fail-update'
    if ($Fail) { [IO.File]::WriteAllText($failurePath, 'fail') }
    elseif (Test-Path -LiteralPath $failurePath) { Remove-Item -LiteralPath $failurePath -Force }
    $testTimer = [Windows.Threading.DispatcherTimer]::new()
    $testTimer.Interval = [TimeSpan]::FromMilliseconds(40)
    $testTimer.Tag = @{
        Initial=$Initial; Desired=$Desired; Fail=$Fail; EmptyTokenSave=$EmptyTokenSave
        CloseEarly=$CloseEarly; ReopenPending=$ReopenPending
        Failure=$null; Completed=$false; Stage='Open'; Ticks=0
        Deadline=[DateTime]::UtcNow.AddSeconds(12); DuringUpdateTicks=0
    }
    $testTimer.Add_Tick({
        $state = $this.Tag
        $state.Ticks++
        $dialog = @($window.OwnedWindows | Where-Object { $_.Title -eq '设置' }) | Select-Object -First 1
        try {
            if ([DateTime]::UtcNow -gt $state.Deadline) { throw 'Settings dialog operation timed out.' }
            if (!$dialog) { return }
            $toggle = $dialog.FindName('FollowStartup')
            $status = $dialog.FindName('FollowStatus')
            if (!$toggle -or !$status) { throw 'Follow controls are missing from settings.' }
            switch ($state.Stage) {
                'Open' {
                    if ($state.ReopenPending) {
                        Assert-Equal @($script:jobs | Where-Object { $_.Kind -eq 'Follow' }).Count 1 'Reopening preserves the single pending follow job'
                        Assert-Equal ([bool]$toggle.IsChecked) ([bool]$state.Desired) 'Reopened settings shows the requested pending state'
                        Assert-Equal $toggle.IsEnabled $false 'Reopened follow control stays disabled while saving'
                        if ([string]::IsNullOrWhiteSpace($status.Text)) { throw 'Reopened follow update status is empty.' }
                        $state.Stage = 'Wait'
                        return
                    }
                    Assert-Equal ([bool]$toggle.IsChecked) $state.Initial 'Settings reads the current follow state'
                    Assert-Equal $toggle.IsEnabled $true 'Initial follow control is available'
                    if (![string]::IsNullOrEmpty($dialog.FindName('ApiToken').Password)) { throw 'Test token is unexpectedly nonempty.' }
                    if ([string]::IsNullOrWhiteSpace($status.Text)) { throw 'Initial follow status is empty.' }
                    if ($state.EmptyTokenSave) {
                        Assert-Equal $dialog.FindName('SaveConnection').IsEnabled $false 'An empty token cannot connect an account'
                        Assert-Equal $dialog.IsVisible $true 'Settings remains available without a token'
                        if (![string]::IsNullOrEmpty($script:token)) { throw 'An empty token unexpectedly connects an account.' }
                    }
                    if ($null -eq $state.Desired) {
                        Close-TestSettings $dialog
                        $state.Completed = $true
                        $this.Stop()
                        return
                    }
                    $toggle.IsChecked = [bool]$state.Desired
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    Invoke-TestControl $dialog 'FollowStartup'
                    $clock.Stop()
                    if ($clock.ElapsedMilliseconds -gt 350) { throw 'Saving follow startup blocks the settings UI.' }
                    Assert-Equal $toggle.IsEnabled $false 'Repeated follow changes are disabled during a write'
                    Assert-Equal @($script:jobs | Where-Object { $_.Kind -eq 'Follow' }).Count 1 'Follow changes run as a background job'
                    if ($state.CloseEarly) {
                        Close-TestSettings $dialog
                        $state.Completed = $true
                        $this.Stop()
                        return
                    }
                    $state.Stage = 'Wait'
                }
                'Wait' {
                    $state.DuringUpdateTicks++
                    if (@($script:jobs | Where-Object { $_.Kind -eq 'Follow' }).Count) { return }
                    $expected = $(if ($state.Fail) { $state.Initial } else { [bool]$state.Desired })
                    Assert-Equal (Read-TestFollowState) $expected 'The follow backend stores the expected state'
                    Assert-Equal ([bool]$toggle.IsChecked) $expected 'The checkbox reflects persisted state after completion'
                    Assert-Equal $toggle.IsEnabled $true 'Follow changes are re-enabled after completion'
                    if ($state.DuringUpdateTicks -lt 2) { throw 'The dialog dispatcher did not stay responsive during the follow update.' }
                    if ([string]::IsNullOrWhiteSpace($status.Text)) { throw 'Follow completion status is empty.' }
                    if (![string]::IsNullOrEmpty($script:token)) { throw 'Follow settings unexpectedly connect an account.' }
                    if (Test-Path -LiteralPath $tokenPath) { throw 'Follow settings created a token file.' }
                    Close-TestSettings $dialog
                    $state.Completed = $true
                    $this.Stop()
                }
            }
        } catch {
            $state.Failure = $_
            $this.Stop()
            if ($dialog) { $dialog.Close() }
            else { foreach ($owned in @($window.OwnedWindows)) { $owned.Close() } }
        }
    })
    $testTimer.Start()
    try { Configure } finally { $testTimer.Stop() }
    if ($testTimer.Tag.Failure) { throw $testTimer.Tag.Failure }
    if (!$testTimer.Tag.Completed) { throw 'Settings test did not complete its dialog operation.' }
}

try {
    # This backend writes only inside the test fixture. It never creates a
    # Startup shortcut, signals the real watcher, or launches any process.
    $fakeModulePath = Join-Path $testDirectory 'FollowSettings.ps1'
    $fakeModule = @'
$script:followTestRoot = $PSScriptRoot
function Get-FollowEnabled {
    return [bool]([IO.File]::ReadAllText((Join-Path $script:followTestRoot 'follow-state.json')) | ConvertFrom-Json)
}
function Set-FollowEnabled([bool]$Enabled, [switch]$SkipInitialOpen) {
    [IO.File]::AppendAllText((Join-Path $script:followTestRoot 'follow-calls.txt'), "call`n")
    $delayPath = Join-Path $script:followTestRoot 'update-delay-ms'
    $delay = $(if (Test-Path -LiteralPath $delayPath) { [int][IO.File]::ReadAllText($delayPath) } else { 450 })
    Start-Sleep -Milliseconds $delay
    if (Test-Path -LiteralPath (Join-Path $script:followTestRoot 'fail-update')) { throw 'Simulated follow update failure.' }
    [IO.File]::WriteAllText((Join-Path $script:followTestRoot 'follow-state.json'), ($Enabled | ConvertTo-Json -Compress))
}
'@
    [IO.File]::WriteAllText($fakeModulePath, $fakeModule, [Text.UTF8Encoding]::new($true))
    Write-TestFollowState $false
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start.ps1'))
    foreach ($module in 'Runtime.ps1','Theme.ps1','Background.ps1','Calendar.ps1','FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1') {
        $modulePath = $(if ($module -eq 'FollowSettings.ps1') { $fakeModulePath } else { Join-Path $root $module }).Replace("'", "''")
        # Replace imports and worker AddArgument paths together so the async
        # runspace receives the fixture backend as well as the UI thread.
        $source = $source.Replace("(Join-Path `$PSScriptRoot '$module')", "'$modulePath'")
        $source = $source.Replace("Join-Path `$PSScriptRoot '$module'", "'$modulePath'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-follow-settings-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $fixtureDataPath = $testDirectory.Replace("'", "''")
    $source = $source.Replace("`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'", "`$dataDir = '$fixtureDataPath'")
    $fixtureTokenPath = (Join-Path $testDirectory 'token.dat').Replace("'", "''")
    $source = $source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$fixtureTokenPath'")
    $source = $source.Replace('Todoist 桌面小组件', 'Todoist 设置测试')
    $source = $source.Replace('$window.ShowDialog() | Out-Null', '$timer.Stop(); $poll.Stop()')
    Invoke-Expression $source
    Assert-Equal $dataDir $testDirectory 'Test data stays inside the fixture directory'
    Assert-Equal $tokenPath (Join-Path $testDirectory 'token.dat') 'Test token stays inside the fixture directory'
    if (![string]::IsNullOrEmpty($script:token)) { throw 'Isolated fixture unexpectedly contains a token.' }
    $window.Show()
    $poll.Start()

    Test-FollowDialog -Initial $false -Desired $true -EmptyTokenSave $true
    Test-FollowDialog -Initial $true -Desired $null
    Test-FollowDialog -Initial $true -Desired $false
    Test-FollowDialog -Initial $false -Desired $true -Fail $true
    Test-FollowDialog -Initial $true -Desired $false -Fail $true
    Test-FollowDialog -Initial $true -Desired $null
    $callsBeforeReopen = Get-TestFollowCallCount
    [IO.File]::WriteAllText((Join-Path $testDirectory 'update-delay-ms'), '1500')
    Test-FollowDialog -Initial $false -Desired $true -CloseEarly $true
    Assert-Equal @($script:jobs | Where-Object { $_.Kind -eq 'Follow' }).Count 1 'Closing settings leaves its follow update pending'
    Test-FollowDialog -Initial $false -Desired $true -ReopenPending $true
    Assert-Equal (Get-TestFollowCallCount) ($callsBeforeReopen + 1) 'Closing and reopening does not duplicate the backend write'
    'PASS: follow settings load/reopen, responsive enable/disable, failure rollback, no-token operation, and reopen during a pending write.'
} finally {
    if ($null -ne $window) { $window.Close() }
    $resolvedDirectory = [IO.Path]::GetFullPath($testDirectory)
    $expectedParent = $root + '\'
    if (!$resolvedDirectory.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolvedDirectory) { Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force }
}
