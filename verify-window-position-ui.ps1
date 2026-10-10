$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.window-position-ui-test-' + [Guid]::NewGuid().ToString('N')
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
function Get-TestBounds {
    [TodoistWidget.NativeWindow]::GetWidgetBounds([Windows.Interop.WindowInteropHelper]::new($window).Handle)
}
function Move-TestWindow([int]$Left, [int]$Top) {
    [TodoistWidget.NativeWindow]::MoveWidget([Windows.Interop.WindowInteropHelper]::new($window).Handle, $Left, $Top)
    $window.UpdateLayout()
}
function Assert-Persisted([int]$Left, [int]$Top, [string]$Message) {
    $saved = Read-WindowPosition -Path $windowPositionPath
    if ($null -eq $saved) { throw "$Message (position was not saved)" }
    Assert-Equal $saved.Left $Left "$Message, horizontal position"
    Assert-Equal $saved.Top $Top "$Message, vertical position"
}
function Assert-ViewSize([string]$Mode, [double]$Width, [double]$Height, [string]$Message) {
    $saved = Read-WindowPosition -Path $windowPositionPath
    if ($null -eq $saved -or !$saved.Views.ContainsKey($Mode)) { throw "$Message (view size was not saved)" }
    Assert-Equal $saved.Views[$Mode].Width $Width "$Message, width"
    Assert-Equal $saved.Views[$Mode].Height $Height "$Message, height"
}
function Assert-Reachable {
    $bounds = Get-TestBounds
    $reachable = @([Windows.Forms.Screen]::AllScreens | Where-Object {
        $area = $_.WorkingArea
        $bounds[0] -ge $area.Left -and $bounds[1] -ge $area.Top -and
        $bounds[0] + [Math]::Min($bounds[2], $area.Width) -le $area.Right -and
        $bounds[1] + [Math]::Min($bounds[3], $area.Height) -le $area.Bottom
    })
    if (!$reachable.Count) { throw 'Restored window is not reachable in a current screen work area.' }
}

try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start.ps1'))
    foreach ($module in 'Runtime.ps1','Theme.ps1','Background.ps1','Calendar.ps1','FollowSettings.ps1','WindowPosition.ps1') {
        $modulePath = (Join-Path $root $module).Replace("'", "''")
        $source = $source.Replace(". (Join-Path `$PSScriptRoot '$module')", ". '$modulePath'")
    }
    $fixtureDataPath = $testDirectory.Replace("'", "''")
    $fixtureTokenPath = (Join-Path $testDirectory 'token.dat').Replace("'", "''")
    $dataAssignment = "`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'"
    $tokenAssignment = "`$tokenPath = Join-Path `$dataDir 'token.dat'"
    if (!$source.Contains($dataAssignment) -or !$source.Contains($tokenAssignment)) { throw 'Unable to isolate account and settings paths.' }
    $source = $source.Replace($dataAssignment, "`$dataDir = '$fixtureDataPath'")
    $source = $source.Replace($tokenAssignment, "`$tokenPath = '$fixtureTokenPath'")
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-window-position-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $source = $source.Replace('Todoist 桌面小组件', 'Todoist 位置隔离测试')
    # Keep the real Loaded/Closing/Closed events. Disable automatic data fetching.
    $source = [regex]::Replace($source, '(?m)^\$window\.Add_ContentRendered\(\{[^\r\n]*\}\)\r?\n', '')
    $source = [regex]::Replace($source, '(?ms)^\$window\.Add_ContentRendered\(\{\r?\n.*?^\}\)\r?\n', '')
    $source = $source.Replace('$window.ShowDialog() | Out-Null', '$timer.Stop(); $poll.Stop()')

    foreach ($scenario in 'MoveAndClose','Reopen','Corrupt','Offscreen') {
        if ($scenario -eq 'Corrupt') {
            [IO.File]::WriteAllText((Join-Path $testDirectory 'window-position.json'), '{invalid-json', [Text.UTF8Encoding]::new($true))
        } elseif ($scenario -eq 'Offscreen') {
            [IO.File]::WriteAllText((Join-Path $testDirectory 'window-position.json'), '{"Left":900000,"Top":900000,"Views":{"List":{"Width":4000,"Height":2200}}}', [Text.UTF8Encoding]::new($true))
        }
        Invoke-Expression $source
        Assert-Equal $dataDir $testDirectory 'Data directory is isolated'
        Assert-Equal $tokenPath (Join-Path $testDirectory 'token.dat') 'Token path is isolated'
        Assert-Equal $windowPositionPath (Join-Path $testDirectory 'window-position.json') 'Position file is isolated'
        if (![string]::IsNullOrEmpty($script:token)) { throw 'Fixture unexpectedly loaded a token.' }
        function Api([string]$Method, [string]$Path, $Body = $null) {
            if ($Method -eq 'Get') { return @{ results = @(); next_cursor = $null } }
            throw 'Position test must not mutate tasks.'
        }
        # Exercise real HWND movement without covering or activating the user's desktop.
        $window.Opacity = 0
        $window.ShowActivated = $false
        $window.Topmost = $false
        $window.Show()
        $window.UpdateLayout()
        Pump 150
        Assert-Equal $script:positionReady $true 'Loaded enables position persistence'
        Add-Type -AssemblyName System.Windows.Forms

        if ($scenario -eq 'MoveAndClose') {
            $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $bounds = Get-TestBounds
            $baseLeft = $area.Left + [Math]::Max(0, [Math]::Min(40, $area.Width - $bounds[2] - 60))
            $baseTop = $area.Top + [Math]::Max(0, [Math]::Min(40, $area.Height - $bounds[3] - 60))
            Move-TestWindow $baseLeft $baseTop
            Pump 550
            Assert-Persisted $baseLeft $baseTop 'Normal movement is saved automatically'
            Move-TestWindow ($baseLeft + 10) ($baseTop + 10)
            Pump 160
            Assert-Persisted $baseLeft $baseTop 'No write before the debounce delay'
            Move-TestWindow ($baseLeft + 20) ($baseTop + 20)
            Pump 260
            Assert-Persisted $baseLeft $baseTop 'A second move restarts the debounce delay'
            Pump 260
            Assert-Persisted ($baseLeft + 20) ($baseTop + 20) 'The final location is saved after dragging settles'
            Assert-Equal $positionSaveTimer.IsEnabled $false 'Save timer stops after flushing'
            $listWidth = 440.0; $listHeight = 520.0
            $calendarWidth = 820.0; $calendarHeight = 745.0
            $window.Width = $listWidth; $window.Height = $listHeight
            Pump 550
            Assert-ViewSize 'List' $listWidth $listHeight 'Resizing the list saves its size without moving'
            Set-WidgetView 'Calendar'
            $window.Width = $calendarWidth; $window.Height = $calendarHeight
            Pump 550
            Assert-ViewSize 'Calendar' $calendarWidth $calendarHeight 'Calendar size is saved separately'
            Set-WidgetView 'List'
            Assert-Equal $window.Width $listWidth 'Returning to list restores its width'
            Assert-Equal $window.Height $listHeight 'Returning to list restores its height'
            $lastLeft = $baseLeft + 30
            $lastTop = $baseTop + 30
            Move-TestWindow $lastLeft $lastTop
            $window.Close()
            Assert-Persisted $lastLeft $lastTop 'Closing immediately flushes a pending location'
        } elseif ($scenario -eq 'Reopen') {
            $bounds = Get-TestBounds
            Assert-Equal $bounds[0] $lastLeft 'New instance restores saved horizontal location on Loaded'
            Assert-Equal $bounds[1] $lastTop 'New instance restores saved vertical location on Loaded'
            Assert-Equal $window.Width $listWidth 'New instance restores list width'
            Assert-Equal $window.Height $listHeight 'New instance restores list height'
            Assert-ViewSize 'Calendar' $calendarWidth $calendarHeight 'New instance retains calendar size'
            Set-WidgetView 'Calendar'
            Assert-Equal $window.Width $calendarWidth 'Calendar width restores after reopening'
            Assert-Equal $window.Height $calendarHeight 'Calendar height restores after reopening'
            Set-WidgetView 'List'
            Assert-Equal $window.Topmost $false 'Restoring position preserves stacking preference'
            $width = $window.Width
            $height = $window.Height
            Pump 550
            $bounds = Get-TestBounds
            Assert-Equal $bounds[0] $lastLeft 'Later layout does not overwrite restored horizontal location'
            Assert-Equal $bounds[1] $lastTop 'Later layout does not overwrite restored vertical location'
            Assert-Equal $window.Width $width 'Restoring location preserves width'
            Assert-Equal $window.Height $height 'Restoring location preserves height'
            $window.WindowState = [Windows.WindowState]::Minimized
            Pump 550
            Assert-Persisted $lastLeft $lastTop 'Minimizing never saves Windows sentinel coordinates'
            $window.Close()
            Assert-Persisted $lastLeft $lastTop 'Closing while minimized preserves last normal position'
        } else {
            Assert-Reachable
            $bounds = Get-TestBounds
            if ($scenario -eq 'Offscreen') {
                $area = [Windows.Forms.Screen]::FromHandle([Windows.Interop.WindowInteropHelper]::new($window).Handle).WorkingArea
                if ($area.Width -ge $window.MinWidth -and $bounds[2] -gt $area.Width + 1) { throw 'An oversized restored window extends beyond its current display width.' }
                if ($area.Height -ge $window.MinHeight -and $bounds[3] -gt $area.Height + 1) { throw 'An oversized restored window extends beyond its current display height.' }
            }
            $window.Close()
            Assert-Persisted $bounds[0] $bounds[1] 'Invalid or missing-display cache recovers on close'
        }
        Assert-Equal $positionSaveTimer.IsEnabled $false 'Closing stops the position timer'
        Assert-Equal $timer.IsEnabled $false 'Closing stops the refresh timer'
        Assert-Equal $poll.IsEnabled $false 'Closing stops the worker poll timer'
        Assert-Equal $script:positionReady $false 'Closed window cannot schedule another position write'
        Pump 450
    }
    if (Test-Path -LiteralPath $tokenPath) { throw 'Position persistence must not create a token.' }
    Write-Output 'PASS: isolated WPF movement and resize debounce, per-view sizes after reopening, minimized state, corrupt/offscreen recovery, and timer cleanup.'
} finally {
    if ($window) { $window.Close() }
    $resolvedTarget = [IO.Path]::GetFullPath($testDirectory).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedTarget) -cne $root -or [IO.Path]::GetFileName($resolvedTarget) -cne $folderName) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}
