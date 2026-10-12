# Completed history is grouped by when a task was completed, not by its due date.
# The Todoist API accepts a UTC half-open interval and returns cursor-based pages.
function Get-HistoryProperty {
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

function Test-HistoryProperty {
    param([AllowNull()][object]$Value, [string]$Name)
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Contains($Name) }
    return $null -ne $Value.PSObject.Properties[$Name]
}

function Get-CompletedHistoryRequestPath {
    param(
        [Parameter(Mandatory = $true)][DateTime]$Date,
        [AllowNull()][string]$Cursor,
        [ValidateRange(1, 200)][int]$Limit = 200,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    # Construct both civil midnights independently. A DST change can make the
    # UTC interval 23 or 25 hours, so adding 24 hours to the first UTC instant
    # would return the wrong day's history.
    $start = [DateTime]::SpecifyKind($Date.Date, [DateTimeKind]::Unspecified)
    $end = [DateTime]::SpecifyKind($Date.Date.AddDays(1), [DateTimeKind]::Unspecified)
    $sinceUtc = [TimeZoneInfo]::ConvertTimeToUtc($start, $TimeZone)
    $untilUtc = [TimeZoneInfo]::ConvertTimeToUtc($end, $TimeZone)
    $format = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    $since = [Uri]::EscapeDataString($sinceUtc.ToString($format, [Globalization.CultureInfo]::InvariantCulture))
    $until = [Uri]::EscapeDataString($untilUtc.ToString($format, [Globalization.CultureInfo]::InvariantCulture))
    $path = "tasks/completed/by_completion_date?since=$since&until=$until&limit=$Limit"
    if (![string]::IsNullOrWhiteSpace($Cursor)) {
        $path += '&cursor=' + [Uri]::EscapeDataString($Cursor)
    }
    return $path
}

function Read-CompletedHistoryPage {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Response)

    # The completed-history endpoint uses `items`, unlike the active-task
    # endpoint's `results`. Detect a wrong response shape instead of silently
    # treating a failed integration as an empty day.
    if (!(Test-HistoryProperty $Response 'items')) {
        throw 'Todoist 的已完成历史响应缺少 items 字段。'
    }
    $rawItems = Get-HistoryProperty $Response 'items'
    if ($null -ne $rawItems -and
        ($rawItems -is [string] -or $rawItems -isnot [System.Collections.IEnumerable])) {
        throw 'Todoist 的已完成历史 items 字段不是列表。'
    }
    $items = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $rawItems) {
        foreach ($item in $rawItems) {
            if ($null -ne $item) { $items.Add($item) }
        }
    }
    $cursor = Get-HistoryProperty $Response 'next_cursor'
    if ([string]::IsNullOrWhiteSpace([string]$cursor)) { $cursor = $null }
    return [pscustomobject]@{ Items = [object[]]$items.ToArray(); NextCursor = $cursor }
}

function Get-CompletedHistoryDateKey {
    param(
        [AllowNull()][object]$Task,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $completedAt = Get-HistoryProperty $Task 'completed_at'
    if ($completedAt -isnot [string] -or [string]::IsNullOrWhiteSpace($completedAt)) { return '' }
    $instant = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (![DateTimeOffset]::TryParse($completedAt, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$instant)) {
        return ''
    }
    return [TimeZoneInfo]::ConvertTime($instant, $TimeZone).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Select-CompletedHistoryForDate {
    param(
        [AllowNull()][object[]]$Items,
        [Parameter(Mandatory = $true)][DateTime]$Date,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $selected = $Date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($item in $Items) {
        if ($null -eq $item -or (Get-HistoryProperty $item 'is_deleted') -eq $true) { continue }
        if ((Get-CompletedHistoryDateKey -Task $item -TimeZone $TimeZone) -ceq $selected) { $item }
    }
}
