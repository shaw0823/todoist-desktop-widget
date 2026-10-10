# Shared per-user names keep separate Windows accounts independent.
$widgetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$widgetMutexName = "Local\TodoistDesktopWidget-$widgetUserSid"
$watcherMutexName = "Local\TodoistDesktopWidgetWatcher-$widgetUserSid"
$watcherStopName = "Local\TodoistDesktopWidgetWatcherStop-$widgetUserSid"
if (-not ('TodoistWidget.NativeWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
namespace TodoistWidget {
    public sealed class TodoistWindowState {
        public bool Present;
        public bool Open;
    }
    public static class NativeWindow {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string className, string windowName);
        private delegate bool WindowCallback(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, StringBuilder value, int maximum);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr window);
        [DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr window, int index);
        [StructLayout(LayoutKind.Sequential)]
        private struct Rectangle { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetWindowRect(IntPtr window, out Rectangle rectangle);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
        public static int[] GetWidgetBounds(IntPtr window) {
            Rectangle rectangle;
            if (window == IntPtr.Zero || !GetWindowRect(window, out rectangle))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return new int[] { rectangle.Left, rectangle.Top, rectangle.Right - rectangle.Left, rectangle.Bottom - rectangle.Top };
        }
        public static void MoveWidget(IntPtr window, int left, int top) {
            // Keep the existing size, z-order and activation state.
            if (!SetWindowPos(window, IntPtr.Zero, left, top, 0, 0, 0x0015))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        [DllImport("dwmapi.dll")]
        private static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out int value, int size);
        public static TodoistWindowState GetMainWindowState(uint[] processIds) {
            var state = new TodoistWindowState();
            var ids = new HashSet<uint>(processIds);
            if (ids.Count == 0) return state;
            EnumWindows(delegate(IntPtr window, IntPtr ignored) {
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                if (!ids.Contains(processId) || !IsWindowVisible(window)) return true;
                var className = new StringBuilder(256);
                GetClassName(window, className, className.Capacity);
                if (className.ToString() != "Chrome_WidgetWin_1" || GetWindow(window, 4) != IntPtr.Zero
                    || (GetWindowLong(window, -20) & 0x80) != 0 || GetWindowTextLength(window) == 0) return true;
                if (IsIconic(window)) { state.Present = true; return true; }
                Rectangle rectangle;
                if (!GetWindowRect(window, out rectangle) || rectangle.Right - rectangle.Left < 240
                    || rectangle.Bottom - rectangle.Top < 200) return true;
                state.Present = true;
                int cloaked;
                // Cloaked/minimized windows preserve the session but cannot open the widget.
                if (DwmGetWindowAttribute(window, 14, out cloaked, sizeof(int)) != 0 || cloaked == 0) state.Open = true;
                return true;
            }, IntPtr.Zero);
            return state;
        }
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
function Get-TodoistState {
    $processes = @(Get-Process -Name 'Todoist' -ErrorAction SilentlyContinue)
    try {
        $ids = [uint32[]]@($processes | ForEach-Object { $_.Id })
        return [TodoistWidget.NativeWindow]::GetMainWindowState($ids)
    } finally { foreach ($process in $processes) { $process.Dispose() } }
}
