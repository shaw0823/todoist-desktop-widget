$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DisplaySettings.ps1')
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = Join-Path $root ('.display-test-' + [Guid]::NewGuid().ToString('N'))
$path = Join-Path $fixture 'display.json'
[IO.Directory]::CreateDirectory($fixture) | Out-Null

function Assert-Setting($Settings, [string]$Name, [bool]$Expected) {
    if ($Settings[$Name] -cne $Expected) { throw "$Name expected $Expected, got $($Settings[$Name])." }
}

try {
    $defaults = Read-DisplaySettings -Path $path
    foreach ($name in @('ShowClock', 'ShowCalendar', 'ShowList')) { Assert-Setting $defaults $name $true }
    if ($defaults.ViewExpansionDirection -cne 'LeftToRight') { throw 'Default view expansion direction must preserve left anchoring.' }
    if ([IO.File]::Exists($path)) { throw 'Reading missing display settings created a file.' }

    $choice = @{ShowClock=$false; ShowCalendar=$false; ShowList=$false; ViewExpansionDirection='RightToLeft'}
    Save-DisplaySettings -Settings $choice -Path $path
    $loaded = Read-DisplaySettings -Path $path
    foreach ($name in @('ShowClock', 'ShowCalendar', 'ShowList')) { Assert-Setting $loaded $name $false }
    if ($loaded.ViewExpansionDirection -cne 'RightToLeft') { throw 'Right-to-left choice did not persist.' }

    $choice.ShowClock = $true
    $choice.ShowList = $true
    Save-DisplaySettings -Settings $choice -Path $path
    $loaded = Read-DisplaySettings -Path $path
    Assert-Setting $loaded 'ShowClock' $true
    Assert-Setting $loaded 'ShowCalendar' $false
    Assert-Setting $loaded 'ShowList' $true
    if ($loaded.ViewExpansionDirection -cne 'RightToLeft') { throw 'Unrelated display changes reset the expansion direction.' }

    $saved = [IO.File]::ReadAllBytes($path)
    $failed = $false
    try { Save-DisplaySettings -Settings @{ShowClock='false';ShowCalendar=$true;ShowList=$true} -Path $path } catch { $failed = $true }
    if (!$failed) { throw 'String value was accepted as a boolean.' }
    if ([Convert]::ToBase64String($saved) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) {
        throw 'Invalid value changed saved settings.'
    }
    $failed = $false
    try { Save-DisplaySettings -Settings @{ShowClock=$true;ShowCalendar=$true;ShowList=$true;ViewExpansionDirection='Outside'} -Path $path } catch { $failed = $true }
    if (!$failed) { throw 'Invalid view expansion direction was accepted.' }
    if ([Convert]::ToBase64String($saved) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) {
        throw 'Invalid direction changed saved settings.'
    }

    [IO.File]::WriteAllText($path, '{"ShowClock":false}', [Text.UTF8Encoding]::new($true))
    $partial = Read-DisplaySettings -Path $path
    Assert-Setting $partial 'ShowClock' $false
    Assert-Setting $partial 'ShowCalendar' $true
    Assert-Setting $partial 'ShowList' $true
    if ($partial.ViewExpansionDirection -cne 'LeftToRight') { throw 'Legacy settings did not receive the default expansion direction.' }

    [IO.File]::WriteAllText($path, '{ broken', [Text.UTF8Encoding]::new($true))
    $fallback = Read-DisplaySettings -Path $path
    foreach ($name in @('ShowClock', 'ShowCalendar', 'ShowList')) { Assert-Setting $fallback $name $true }
    if ($fallback.ViewExpansionDirection -cne 'LeftToRight') { throw 'Corrupt preferences did not restore the default direction.' }
    'PASS: independent display defaults, expansion direction persistence and validation, legacy preferences, and corrupt-data fallback.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
