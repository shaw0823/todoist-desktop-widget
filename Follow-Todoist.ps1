param([switch]$SkipInitialOpen)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')
$watcherMutex = Enter-WidgetMutex $watcherMutexName
if ($null -eq $watcherMutex) { return }
$stopSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $watcherStopName)
$stopSignal.Reset() | Out-Null
$sessionOpen = $false
$openSamples = 0
$absentSamples = 0
$firstSample = $true
try {
    do {
        $state = Get-TodoistState
        if ($firstSample) {
            if ($SkipInitialOpen -and $state.Present) { $sessionOpen = $true }
            $firstSample = $false
        }
        if ($state.Present) {
            $absentSamples = 0
            if ($state.Open -and !$sessionOpen) {
                $openSamples++
                if ($openSamples -ge 3) {
                    try { Start-Widget; $sessionOpen = $true }
                    catch { $openSamples = 0 }
                }
            } else { $openSamples = 0 }
        } else {
            $openSamples = 0
            $absentSamples++
            # Ignore short handle gaps during Electron closing/window recreation.
            if ($absentSamples -ge 4) { $sessionOpen = $false }
        }
    } while (!$stopSignal.WaitOne(500))
} finally {
    $stopSignal.Dispose()
    $watcherMutex.ReleaseMutex()
    $watcherMutex.Dispose()
}
