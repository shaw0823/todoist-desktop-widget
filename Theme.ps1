# Portable theme helpers. These functions do not read account credentials.
function Get-DefaultTheme {
    return @{
        Background = '#263F43'
        Foreground = '#E2ECEC'
        Accent = '#70D7C3'
    }
}

function ConvertTo-ThemeColor {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Color)
    if ($Color -isnot [string]) { throw 'Color must be a hexadecimal color string.' }
    $value = $Color.Trim()
    if ($value -notmatch '^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$') {
        throw 'Use a color in #RGB or #RRGGBB format.'
    }
    $hex = $Matches[1].ToUpperInvariant()
    if ($hex.Length -eq 3) {
        $hex = '{0}{0}{1}{1}{2}{2}' -f $hex[0], $hex[1], $hex[2]
    }
    return '#' + $hex
}

function Get-NormalizedTheme {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Theme)
    if ($null -eq $Theme) { throw 'Theme is required.' }
    $keys = @('Background', 'Foreground', 'Accent')
    if ($Theme -is [System.Collections.IDictionary]) {
        $givenKeys = @($Theme.Keys)
        if ($givenKeys.Count -ne $keys.Count) { throw 'Theme must contain Background, Foreground and Accent only.' }
        foreach ($key in $givenKeys) {
            if ($key -isnot [string] -or $keys -notcontains $key) { throw 'Theme contains an unknown color.' }
        }
        $normalized = @{}
        foreach ($key in $keys) {
            if (!$Theme.Contains($key)) { throw "Theme is missing $key." }
            $normalized[$key] = ConvertTo-ThemeColor $Theme[$key]
        }
        return $normalized
    }
    if ($Theme -isnot [pscustomobject]) { throw 'Theme must be an object with three colors.' }
    $properties = @($Theme.PSObject.Properties)
    if ($properties.Count -ne $keys.Count) { throw 'Theme must contain Background, Foreground and Accent only.' }
    foreach ($property in $properties) {
        if ($keys -notcontains $property.Name) { throw 'Theme contains an unknown color.' }
    }
    $normalized = @{}
    foreach ($key in $keys) {
        $property = $Theme.PSObject.Properties[$key]
        if ($null -eq $property) { throw "Theme is missing $key." }
        $normalized[$key] = ConvertTo-ThemeColor $property.Value
    }
    return $normalized
}

function Read-Theme {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (![System.IO.File]::Exists($Path)) { return Get-DefaultTheme }
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $theme = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        return Get-NormalizedTheme $theme
    }
    catch { return Get-DefaultTheme }
}

function Save-Theme {
    param(
        [Parameter(Mandatory = $true)][object]$Theme,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $normalized = Get-NormalizedTheme $Theme
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Theme file path is required.' }
    $target = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($target)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.theme-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $orderedTheme = [ordered]@{
            Background = $normalized.Background
            Foreground = $normalized.Foreground
            Accent = $normalized.Accent
        }
        $json = ConvertTo-Json -InputObject $orderedTheme
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($true))
        if ([System.IO.File]::Exists($target)) {
            # Windows PowerShell binds $null to an empty string for this .NET overload.
            [System.IO.File]::Replace($temporary, $target, [NullString]::Value)
        }
        else { [System.IO.File]::Move($temporary, $target) }
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Blend-ThemeColor {
    param([string]$Background, [string]$Foreground, [double]$Amount)
    $channels = foreach ($offset in @(1, 3, 5)) {
        $start = [Convert]::ToInt32($Background.Substring($offset, 2), 16)
        $end = [Convert]::ToInt32($Foreground.Substring($offset, 2), 16)
        [int][Math]::Round($start + (($end - $start) * $Amount), [MidpointRounding]::AwayFromZero)
    }
    return '#{0:X2}{1:X2}{2:X2}' -f $channels[0], $channels[1], $channels[2]
}

function Get-ThemePalette {
    param([Parameter(Mandatory = $true)][object]$Theme)
    $normalized = Get-NormalizedTheme $Theme
    return @{
        Background = $normalized.Background
        Foreground = $normalized.Foreground
        Accent = $normalized.Accent
        Surface = Blend-ThemeColor $normalized.Background $normalized.Foreground 0.10
        Border = Blend-ThemeColor $normalized.Background $normalized.Foreground 0.24
        Divider = Blend-ThemeColor $normalized.Background $normalized.Foreground 0.14
        Muted = Blend-ThemeColor $normalized.Background $normalized.Foreground 0.65
    }
}
