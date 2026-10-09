# Calendar helpers do not change task dates or depend on the current culture.
function Get-CalendarDays {
    param([Parameter(Mandatory = $true)][DateTime]$Date)
    $first = [DateTime]::new($Date.Year, $Date.Month, 1)
    $leading = ([int]$first.DayOfWeek + 6) % 7
    $dayCount = [DateTime]::DaysInMonth($Date.Year, $Date.Month)
    $cellCount = [Math]::Max(35, [int]([Math]::Ceiling(($leading + $dayCount) / 7.0) * 7))
    $start = $first.AddDays(-$leading)
    for ($index = 0; $index -lt $cellCount; $index++) {
        $start.AddDays($index)
    }
}

function Get-CalendarObjectValue {
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

function Get-TaskDateKey {
    param([AllowNull()][object]$Task)
    $due = Get-CalendarObjectValue $Task 'due'
    $candidate = Get-CalendarObjectValue $due 'date'
    if ($null -eq $candidate -or ($candidate -is [string] -and [string]::IsNullOrWhiteSpace($candidate))) {
        $candidate = Get-CalendarObjectValue $due 'datetime'
    }
    if ($candidate -isnot [string] -or $candidate -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:$|T)') { return '' }
    $key = $candidate.Substring(0, 10)
    $parsed = [DateTime]::MinValue
    if (![DateTime]::TryParseExact($key, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return ''
    }
    # Keep Todoist's written date, including for timestamps carrying a UTC offset.
    return $key
}

function Get-CalendarTaskGroups {
    param([AllowNull()][object[]]$Tasks, [AllowNull()][System.Collections.IDictionary]$Pending = @{})
    $groups = @{}
    foreach ($task in $Tasks) {
        $key = Get-TaskDateKey $task
        if (!$key) { continue }
        $id = [string](Get-CalendarObjectValue $task 'id')
        if ($null -ne $Pending -and $Pending.Contains($id)) { continue }
        if (!$groups.ContainsKey($key)) { $groups[$key] = [System.Collections.Generic.List[object]]::new() }
        $groups[$key].Add($task)
    }
    foreach ($key in @($groups.Keys)) {
        $groups[$key] = [object[]]@($groups[$key] | Sort-Object @{
            Expression = {
                $due = Get-CalendarObjectValue $_ 'due'
                $date = Get-CalendarObjectValue $due 'date'
                if ($null -eq $date -or ($date -is [string] -and [string]::IsNullOrWhiteSpace($date))) {
                    $date = Get-CalendarObjectValue $due 'datetime'
                }
                [string]$date
            }
        }, @{ Expression = { Get-CalendarObjectValue $_ 'order' } })
    }
    return $groups
}
