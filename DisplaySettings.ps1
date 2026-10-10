# Local display preferences; each feature can be switched independently.
function Get-DisplaySettingValue {
    param([AllowNull()][object]$Settings, [string]$Name)
    if ($null -eq $Settings) { return $null }
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains($Name)) { return $Settings[$Name] }
        return $null
    }
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-NormalizedDisplaySettings {
    param([AllowNull()][object]$Settings)
    $normalized = @{ ShowClock = $true; ShowCalendar = $true; ShowList = $true }
    foreach ($name in @('ShowClock', 'ShowCalendar', 'ShowList')) {
        $value = Get-DisplaySettingValue $Settings $name
        if ($null -eq $value) { continue }
        if ($value -isnot [bool]) { throw "$name must be true or false." }
        $normalized[$name] = $value
    }
    return $normalized
}

function Read-DisplaySettings {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (![IO.File]::Exists($Path)) { return Get-NormalizedDisplaySettings $null }
        if (([IO.FileInfo]::new($Path)).Length -gt 4096) { throw 'Display settings file is too large.' }
        $saved = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        return Get-NormalizedDisplaySettings $saved
    } catch {
        return Get-NormalizedDisplaySettings $null
    }
}

function Save-DisplaySettings {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Settings,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $normalized = Get-NormalizedDisplaySettings $Settings
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Display settings path is required.' }
    $target = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($target)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.display-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = [ordered]@{
            ShowClock = $normalized.ShowClock
            ShowCalendar = $normalized.ShowCalendar
            ShowList = $normalized.ShowList
        } | ConvertTo-Json -Compress
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
