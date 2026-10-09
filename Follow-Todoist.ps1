$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')
$watcherMutex = Enter-WidgetMutex $watcherMutexName
if ($null -eq $watcherMutex) { return }
$stopSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $watcherStopName)
$stopSignal.Reset() | Out-Null
$wasRunning = $false
$wasVisible = $false
try {
    do {
        $processes = @(Get-Process -Name 'Todoist' -ErrorAction SilentlyContinue)
        $running = $processes.Count -gt 0
        $visible = @($processes | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }).Count -gt 0
        # Once per launch/open, so closing the widget does not repeatedly reopen it.
        if (($running -and !$wasRunning) -or ($visible -and !$wasVisible)) {
            Start-Widget
        }
        $wasRunning = $running
        $wasVisible = $visible
        foreach ($process in $processes) { $process.Dispose() }
    } while (!$stopSignal.WaitOne(1000))
} finally {
    $stopSignal.Dispose()
    $watcherMutex.ReleaseMutex()
    $watcherMutex.Dispose()
}
