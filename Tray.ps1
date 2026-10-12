# The notification icon keeps the WPF dispatcher alive while the widget is hidden.
function Get-WidgetTraySignalName {
    if ($script:traySignalNameOverride) { return $script:traySignalNameOverride }
    return "Local\TodoistDesktopWidgetShow-$widgetUserSid"
}

function Request-WidgetShow {
    try {
        $signal = [Threading.EventWaitHandle]::OpenExisting((Get-WidgetTraySignalName))
        try { [void]$signal.Set() } finally { $signal.Dispose() }
    } catch [Threading.WaitHandleCannotBeOpenedException] {
        # The first instance has not created its notification icon yet.
    }
}

function Get-WidgetTrayIcon {
    Add-Type -AssemblyName System.Drawing
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add((Join-Path $env:LOCALAPPDATA 'Programs\todoist\Todoist.exe'))
    foreach ($process in @(Get-Process -Name Todoist -ErrorAction SilentlyContinue)) {
        try { if ($process.Path) { $paths.Add($process.Path) } }
        catch { }
        finally { $process.Dispose() }
    }
    foreach ($path in $paths) {
        if (![IO.File]::Exists($path)) { continue }
        try {
            $icon = [Drawing.Icon]::ExtractAssociatedIcon($path)
            if ($null -ne $icon) { return $icon }
        } catch { }
    }
    return [Drawing.Icon][Drawing.SystemIcons]::Application.Clone()
}

function Show-WidgetFromTray {
    if (!$window.IsVisible) { $window.Show() }
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
        $window.WindowState = [Windows.WindowState]::Normal
    }
    [void]$window.Activate()
}

function Hide-WidgetToTray {
    if ($null -eq $script:trayIcon -or !$script:trayIcon.Visible) {
        $window.Close()
        return
    }
    $positionSaveTimer.Stop()
    Save-WidgetPosition
    $window.Hide()
    if (!$script:trayHintShown) {
        $script:trayHintShown = $true
        $script:trayIcon.ShowBalloonTip(2500, 'Todoist Widget', '已隐藏到系统托盘。双击图标重新打开，右键可退出。', [Windows.Forms.ToolTipIcon]::Info)
    }
}

function Exit-WidgetFromTray {
    if ($script:trayExitRequested) { return }
    $script:trayExitRequested = $true
    $window.Close()
}

function Initialize-WidgetTray {
    param([string]$SignalName = (Get-WidgetTraySignalName))
    if ($null -ne $script:trayIcon) { return }
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    $script:trayIconResource = Get-WidgetTrayIcon
    $script:trayMenu = [Windows.Forms.ContextMenuStrip]::new()
    $script:trayShowItem = [Windows.Forms.ToolStripMenuItem]::new('显示小组件')
    $script:trayHideItem = [Windows.Forms.ToolStripMenuItem]::new('隐藏小组件')
    $script:trayExitItem = [Windows.Forms.ToolStripMenuItem]::new('退出程序')
    [void]$script:trayMenu.Items.Add($script:trayShowItem)
    [void]$script:trayMenu.Items.Add($script:trayHideItem)
    [void]$script:trayMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    [void]$script:trayMenu.Items.Add($script:trayExitItem)
    $script:trayShowItem.Add_Click({ Show-WidgetFromTray })
    $script:trayHideItem.Add_Click({ Hide-WidgetToTray })
    $script:trayExitItem.Add_Click({ Exit-WidgetFromTray })
    $script:trayMenu.Add_Opening({ $script:trayHideItem.Enabled = $window.IsVisible })
    $script:trayIcon = [Windows.Forms.NotifyIcon]::new()
    $script:trayIcon.Icon = $script:trayIconResource
    $script:trayIcon.Text = 'Todoist Widget'
    $script:trayIcon.ContextMenuStrip = $script:trayMenu
    $script:trayIcon.Add_MouseDoubleClick({
        if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-WidgetFromTray }
    })
    $script:trayIcon.Visible = $true
    $script:trayShowSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, $SignalName)
    $script:traySignalTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:traySignalTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:traySignalTimer.Add_Tick({
        if ($null -ne $script:trayShowSignal -and $script:trayShowSignal.WaitOne(0)) {
            Show-WidgetFromTray
        }
    })
    $script:traySignalTimer.Start()
}

function Dispose-WidgetTray {
    if ($null -ne $script:traySignalTimer) {
        $script:traySignalTimer.Stop()
        $script:traySignalTimer = $null
    }
    if ($null -ne $script:trayShowSignal) {
        $script:trayShowSignal.Dispose()
        $script:trayShowSignal = $null
    }
    if ($null -ne $script:trayIcon) {
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
        $script:trayIcon = $null
    }
    if ($null -ne $script:trayMenu) {
        $script:trayMenu.Dispose()
        $script:trayMenu = $null
    }
    if ($null -ne $script:trayIconResource) {
        $script:trayIconResource.Dispose()
        $script:trayIconResource = $null
    }
}

function Start-WidgetMessageLoop {
    param([Parameter(Mandatory = $true)][Windows.Window]$Window)
    Initialize-WidgetTray
    $window.Show()
    $script:trayLoopRunning = $true
    try { [Windows.Threading.Dispatcher]::Run() }
    finally {
        $script:trayLoopRunning = $false
        Dispose-WidgetTray
    }
}
