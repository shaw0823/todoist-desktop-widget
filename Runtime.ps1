# Shared per-user names keep separate Windows accounts independent.
$widgetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$widgetMutexName = "Local\TodoistDesktopWidget-$widgetUserSid"
$watcherMutexName = "Local\TodoistDesktopWidgetWatcher-$widgetUserSid"
$watcherStopName = "Local\TodoistDesktopWidgetWatcherStop-$widgetUserSid"
if (-not ('TodoistWidget.NativeWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace TodoistWidget {
    public static class NativeWindow {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string className, string windowName);
    }
}
'@
}
function Enter-WidgetMutex([string]$name) {
    $mutex = [Threading.Mutex]::new($false, $name)
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (!$acquired) { $mutex.Dispose(); return $null }
    return $mutex
}
function Test-WidgetOpen {
    # Also detects a window running an older version without the mutex.
    return [TodoistWidget.NativeWindow]::FindWindow($null, 'Todoist 桌面小组件') -ne [IntPtr]::Zero
}
function Start-Widget {
    if (Test-WidgetOpen) { return }
    $scriptFile = Join-Path $PSScriptRoot 'Start.ps1'
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershellExe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptFile`"" -WindowStyle Hidden | Out-Null
}
