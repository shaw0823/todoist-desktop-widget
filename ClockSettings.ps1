# Local clock preferences; no account data is stored here.
function Get-NormalizedClockFormat {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Format)
    if ($Format -isnot [string] -or $Format -cnotin @('24h', '12h')) {
        throw 'Clock format must be 24h or 12h.'
    }
    return $Format
}

function Read-ClockSettings {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (![IO.File]::Exists($Path)) { return @{ Format = '24h' } }
        $file = [IO.FileInfo]::new($Path)
        if ($file.Length -gt 4096) { throw 'Clock settings file is too large.' }
        $settings = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        return @{ Format = (Get-NormalizedClockFormat $settings.Format) }
    } catch {
        return @{ Format = '24h' }
    }
}

function Save-ClockSettings {
    param(
        [Parameter(Mandatory = $true)][object]$Format,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $normalized = Get-NormalizedClockFormat $Format
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Clock settings path is required.' }
    $target = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($target)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.clock-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = [ordered]@{ Format = $normalized } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($target)) {
            [IO.File]::Replace($temporary, $target, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $target)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Format-WidgetClock {
    param(
        [Parameter(Mandatory = $true)][DateTime]$DateTime,
        [Parameter(Mandatory = $true)][object]$Format
    )
    $normalized = Get-NormalizedClockFormat $Format
    if ($normalized -eq '12h') {
        return $DateTime.ToString('tt hh:mm:ss', [Globalization.CultureInfo]::GetCultureInfo('zh-CN'))
    }
    return $DateTime.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
}
