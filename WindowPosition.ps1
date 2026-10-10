# Coordinates are physical desktop pixels; these helpers never read account data.
function Get-WindowPositionValue {
    param([AllowNull()][object]$Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-WindowCoordinate {
    param([AllowNull()][object]$Value)
    $numeric = $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]
    if (!$numeric) { throw 'Window coordinates must be numbers.' }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        [Math]::Abs($number) -gt 1000000 -or [Math]::Truncate($number) -ne $number) {
        throw 'Window coordinates must be whole pixels between -1000000 and 1000000.'
    }
    return [int]$number
}

function ConvertTo-WindowDimension {
    param([AllowNull()][object]$Value)
    $numeric = $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]
    if (!$numeric) { throw 'Window dimensions must be numbers.' }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 100 -or $number -gt 10000) {
        throw 'Window dimensions must be between 100 and 10000.'
    }
    return $number
}

function Get-NormalizedWindowViews {
    param([AllowNull()][object]$Views)
    $normalized = @{}
    if ($null -eq $Views) { return $normalized }
    if ($Views -is [System.Collections.IDictionary]) {
        $names = @($Views.Keys)
    } elseif ($Views -is [pscustomobject]) {
        $names = @($Views.PSObject.Properties | ForEach-Object { $_.Name })
    } else { throw 'Window views must be an object.' }
    if ($names.Count -gt 8) { throw 'Too many window views.' }
    foreach ($name in $names) {
        if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,24}$') { throw 'Invalid window view name.' }
        $size = Get-WindowPositionValue $Views $name
        if ($size -isnot [System.Collections.IDictionary] -and $size -isnot [pscustomobject]) { throw 'Window view size must be an object.' }
        $normalized[$name] = @{
            Width = ConvertTo-WindowDimension (Get-WindowPositionValue $size 'Width')
            Height = ConvertTo-WindowDimension (Get-WindowPositionValue $size 'Height')
        }
    }
    return $normalized
}

function Get-NormalizedWindowPosition {
    param([AllowNull()][object]$Position)
    if ($Position -isnot [System.Collections.IDictionary] -and $Position -isnot [pscustomobject]) {
        throw 'Window position must contain Left and Top coordinates.'
    }
    return @{
        Left = ConvertTo-WindowCoordinate (Get-WindowPositionValue $Position 'Left')
        Top = ConvertTo-WindowCoordinate (Get-WindowPositionValue $Position 'Top')
        Views = Get-NormalizedWindowViews (Get-WindowPositionValue $Position 'Views')
    }
}

function Read-WindowPosition {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (![System.IO.File]::Exists($Path)) { return $null }
        $file = [System.IO.FileInfo]::new($Path)
        if ($file.Length -gt 4096) { return $null }
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $position = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        return Get-NormalizedWindowPosition $position
    }
    catch { return $null }
}

function Save-WindowPosition {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Position,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $normalized = Get-NormalizedWindowPosition $Position
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Window position file path is required.' }
    $target = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($target)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.window-position-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject ([ordered]@{ Left = $normalized.Left; Top = $normalized.Top; Views = $normalized.Views }) -Depth 4
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($true))
        if ([System.IO.File]::Exists($target)) {
            # Windows PowerShell requires NullString for File.Replace's optional backup path.
            [System.IO.File]::Replace($temporary, $target, [NullString]::Value)
        }
        else { [System.IO.File]::Move($temporary, $target) }
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Get-VisibleWindowPosition {
    param(
        [int]$Left,
        [int]$Top,
        [int]$Width,
        [int]$Height,
        [AllowNull()][AllowEmptyCollection()][object[]]$WorkingAreas
    )
    $leftPixel = ConvertTo-WindowCoordinate $Left
    $topPixel = ConvertTo-WindowCoordinate $Top
    if ($Width -le 0 -or $Height -le 0 -or $Width -gt 1000000 -or $Height -gt 1000000) {
        throw 'Window dimensions must be positive pixel counts no greater than 1000000.'
    }
    $rightPixel = [double]$Left + $Width
    $bottomPixel = [double]$Top + $Height
    $selected = $null
    $largestIntersection = -1.0
    $nearestDistance = [double]::PositiveInfinity
    foreach ($area in $WorkingAreas) {
        try {
            $areaLeft = ConvertTo-WindowCoordinate (Get-WindowPositionValue $area 'Left')
            $areaTop = ConvertTo-WindowCoordinate (Get-WindowPositionValue $area 'Top')
            $areaWidth = ConvertTo-WindowCoordinate (Get-WindowPositionValue $area 'Width')
            $areaHeight = ConvertTo-WindowCoordinate (Get-WindowPositionValue $area 'Height')
            if ($areaWidth -le 0 -or $areaHeight -le 0) { continue }
        }
        catch { continue }
        $areaRight = [double]$areaLeft + $areaWidth
        $areaBottom = [double]$areaTop + $areaHeight
        $overlapWidth = [Math]::Max(0.0, [Math]::Min($rightPixel, $areaRight) - [Math]::Max($Left, $areaLeft))
        $overlapHeight = [Math]::Max(0.0, [Math]::Min($bottomPixel, $areaBottom) - [Math]::Max($Top, $areaTop))
        $intersection = $overlapWidth * $overlapHeight
        # Distance between rectangle edges selects the nearest remaining screen after unplugging one.
        $gapX = [Math]::Max(0.0, [Math]::Max($areaLeft - $rightPixel, $Left - $areaRight))
        $gapY = [Math]::Max(0.0, [Math]::Max($areaTop - $bottomPixel, $Top - $areaBottom))
        $distance = $gapX * $gapX + $gapY * $gapY
        if ($intersection -gt $largestIntersection -or
            ($intersection -eq $largestIntersection -and $distance -lt $nearestDistance)) {
            $selected = @{ Left = $areaLeft; Top = $areaTop; Width = $areaWidth; Height = $areaHeight }
            $largestIntersection = $intersection
            $nearestDistance = $distance
        }
    }
    if ($null -eq $selected) { return @{ Left = $leftPixel; Top = $topPixel } }
    # An oversized window anchors to the work area's top-left so its drag handle remains reachable.
    $maximumLeft = [double]$selected.Left + [Math]::Max(0, $selected.Width - $Width)
    $maximumTop = [double]$selected.Top + [Math]::Max(0, $selected.Height - $Height)
    return @{
        Left = [int][Math]::Max($selected.Left, [Math]::Min($Left, $maximumLeft))
        Top = [int][Math]::Max($selected.Top, [Math]::Min($Top, $maximumTop))
    }
}
