$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClockSettings.ps1')
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = Join-Path $root ('.clock-test-' + [Guid]::NewGuid().ToString('N'))
$path = Join-Path $fixture 'clock.json'
[IO.Directory]::CreateDirectory($fixture) | Out-Null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}

try {
    Assert-Equal (Read-ClockSettings -Path $path).Format '24h' 'Missing preference defaults to 24 hours'
    if ([IO.File]::Exists($path)) { throw 'Reading created a preference file.' }

    Save-ClockSettings -Format '12h' -Path $path
    Assert-Equal (Read-ClockSettings -Path $path).Format '12h' 'Saved 12-hour format survives reload'
    Assert-Equal (([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json).Format) '12h' 'Saved format has the expected schema'

    $morning = [DateTime]::new(2026, 10, 10, 0, 4, 5)
    $afternoon = [DateTime]::new(2026, 10, 10, 13, 4, 5)
    Assert-Equal (Format-WidgetClock -DateTime $morning -Format '24h') '00:04:05' '24-hour clock includes seconds'
    Assert-Equal (Format-WidgetClock -DateTime $afternoon -Format '24h') '13:04:05' '24-hour clock does not use AM/PM'
    Assert-Equal (Format-WidgetClock -DateTime $morning -Format '12h') '上午 12:04:05' '12-hour clock labels the morning'
    Assert-Equal (Format-WidgetClock -DateTime $afternoon -Format '12h') '下午 01:04:05' '12-hour clock labels the afternoon'

    $saved = [IO.File]::ReadAllBytes($path)
    $invalidFailed = $false
    try { Save-ClockSettings -Format '24-hour' -Path $path } catch { $invalidFailed = $true }
    if (!$invalidFailed) { throw 'Invalid clock format was accepted.' }
    if ([Convert]::ToBase64String($saved) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) {
        throw 'Invalid clock format changed the saved preference.'
    }

    Save-ClockSettings -Format '24h' -Path $path
    Assert-Equal (Read-ClockSettings -Path $path).Format '24h' 'Saved 24-hour format survives reload'
    [IO.File]::WriteAllText($path, '{ broken json', [Text.UTF8Encoding]::new($true))
    Assert-Equal (Read-ClockSettings -Path $path).Format '24h' 'Corrupt preference falls back safely'
    [IO.File]::WriteAllText($path, '{"Format":"other"}', [Text.UTF8Encoding]::new($true))
    Assert-Equal (Read-ClockSettings -Path $path).Format '24h' 'Unknown format falls back safely'
    'PASS: clock defaults, 12/24-hour formatting, persistence, and invalid data handling.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
