# Portable background helpers. Only the selected path is saved; images are never copied or changed.
function Get-DefaultBackground {
    return @{
        Mode = 'Color'
        ImagePath = ''
        Opacity = 1.0
        Overlay = 0.45
    }
}

function ConvertTo-BackgroundAmount {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Value, [string]$Name)
    $numericTypes = @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32],
        [int64], [uint64], [single], [double], [decimal]
    )
    if ($null -eq $Value -or $numericTypes -notcontains $Value.GetType()) {
        throw "$Name must be a number between 0 and 1."
    }
    $amount = [double]$Value
    if ([double]::IsNaN($amount) -or [double]::IsInfinity($amount) -or $amount -lt 0 -or $amount -gt 1) {
        throw "$Name must be a finite number between 0 and 1."
    }
    return $amount
}

function Get-NormalizedBackground {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Settings)
    if ($null -eq $Settings) { throw 'Background settings are required.' }
    $keys = @('Mode', 'ImagePath', 'Opacity', 'Overlay')
    $values = @{}
    if ($Settings -is [System.Collections.IDictionary]) {
        $givenKeys = @($Settings.Keys)
        if ($givenKeys.Count -ne $keys.Count) { throw 'Background settings must contain Mode, ImagePath, Opacity and Overlay only.' }
        foreach ($key in $givenKeys) {
            if ($key -isnot [string] -or $keys -cnotcontains $key) { throw 'Background settings contain an unknown field.' }
        }
        foreach ($key in $keys) {
            if (!$Settings.Contains($key)) { throw "Background settings are missing $key." }
            $values[$key] = $Settings[$key]
        }
    }
    elseif ($Settings -is [pscustomobject]) {
        $properties = @($Settings.PSObject.Properties)
        if ($properties.Count -ne $keys.Count) { throw 'Background settings must contain Mode, ImagePath, Opacity and Overlay only.' }
        foreach ($property in $properties) {
            if ($keys -cnotcontains $property.Name) { throw 'Background settings contain an unknown field.' }
        }
        foreach ($key in $keys) {
            $property = $Settings.PSObject.Properties[$key]
            if ($null -eq $property) { throw "Background settings are missing $key." }
            $values[$key] = $property.Value
        }
    }
    else { throw 'Background settings must be an object with four fields.' }

    if ($values.Mode -isnot [string] -or @('Color', 'Image') -cnotcontains $values.Mode) {
        throw 'Background mode must be Color or Image.'
    }
    if ($values.ImagePath -isnot [string]) { throw 'ImagePath must be a string.' }
    if ($values.Mode -ceq 'Image') {
        if ([string]::IsNullOrWhiteSpace($values.ImagePath)) { throw 'Image mode requires a local image path.' }
        $windowsPath = $values.ImagePath.Replace('/', '\')
        $isDriveAbsolute = $windowsPath -match '^[A-Za-z]:\\'
        $isUnc = $windowsPath -match '^\\\\[^\\/:*?"<>|\x00-\x1f]+\\[^\\/:*?"<>|\x00-\x1f]+(?:\\|$)'
        if (!$isDriveAbsolute -and !$isUnc) { throw 'ImagePath must be a drive-absolute or UNC filesystem path.' }
        try { [System.IO.Path]::GetFullPath($values.ImagePath) | Out-Null }
        catch { throw 'ImagePath is not a valid filesystem path.' }
    }
    return @{
        Mode = $values.Mode
        ImagePath = $values.ImagePath
        Opacity = ConvertTo-BackgroundAmount $values.Opacity 'Opacity'
        Overlay = ConvertTo-BackgroundAmount $values.Overlay 'Overlay'
    }
}

function Read-BackgroundSettings {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (![System.IO.File]::Exists($Path)) { return Get-DefaultBackground }
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $settings = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        return Get-NormalizedBackground $settings
    }
    catch { return Get-DefaultBackground }
}

function Save-BackgroundSettings {
    param(
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $normalized = Get-NormalizedBackground $Settings
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Background settings file path is required.' }
    $target = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($target)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.background-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $orderedSettings = [ordered]@{
            Mode = $normalized.Mode
            ImagePath = $normalized.ImagePath
            Opacity = $normalized.Opacity
            Overlay = $normalized.Overlay
        }
        $json = ConvertTo-Json -InputObject $orderedSettings
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
