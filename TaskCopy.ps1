# Build one new, independent task from an unfinished Todoist task.
# The source task and its recurrence rule are never modified or reused.
function New-TodayCopyRequestBody {
    param(
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][DateTime]$Today
    )

    $content = [string](Get-CalendarObjectValue $Task 'content')
    if ([string]::IsNullOrWhiteSpace($content)) { throw '无法复制没有标题的待办。' }
    if ((Get-CalendarObjectValue $Task 'checked') -eq $true -or
        (Get-CalendarObjectValue $Task 'is_completed') -eq $true -or
        $null -ne (Get-CalendarObjectValue $Task 'completed_at')) {
        throw '已完成的待办不会被复制。'
    }

    $body = @{ content = $content }
    foreach ($name in 'description', 'project_id', 'section_id') {
        $value = Get-CalendarObjectValue $Task $name
        if ($null -ne $value -and ![string]::IsNullOrWhiteSpace([string]$value)) { $body[$name] = $value }
    }
    $labels = Get-CalendarObjectValue $Task 'labels'
    if ($null -ne $labels) { $body.labels = [string[]]@($labels) }
    $priority = Get-CalendarObjectValue $Task 'priority'
    if ($null -ne $priority -and [int]$priority -ge 1 -and [int]$priority -le 4) {
        $body.priority = [int]$priority
    }

    $due = Get-CalendarObjectValue $Task 'due'
    $sourceDate = Get-CalendarObjectValue $due 'date'
    if ([string]$sourceDate -notmatch '^\d{4}-\d{2}-\d{2}T') {
        $timestamp = Get-CalendarObjectValue $due 'datetime'
        if (![string]::IsNullOrWhiteSpace([string]$timestamp)) { $sourceDate = $timestamp }
    }
    $todayDate = $Today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if ([string]$sourceDate -match '^\d{4}-\d{2}-\d{2}T(?<hour>\d{2}):(?<minute>\d{2})(?::(?<second>\d{2}))?') {
        if ([string]$sourceDate -match '(?:Z|[+-]\d{2}:?\d{2})$') {
            $sourceTime = [DateTimeOffset]::Parse([string]$sourceDate, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime()
            $hour = $sourceTime.Hour; $minute = $sourceTime.Minute; $second = $sourceTime.Second
        } else {
            $hour = [int]$Matches.hour; $minute = [int]$Matches.minute
            $second = $(if ($Matches.second) { [int]$Matches.second } else { 0 })
        }
        $localTime = [DateTime]::SpecifyKind($Today.Date.AddHours($hour).AddMinutes($minute).AddSeconds($second), [DateTimeKind]::Unspecified)
        $utcTime = [TimeZoneInfo]::ConvertTimeToUtc($localTime, [TimeZoneInfo]::Local)
        $body.due_datetime = $utcTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    } else {
        $body.due_date = $todayDate
    }
    return $body
}
