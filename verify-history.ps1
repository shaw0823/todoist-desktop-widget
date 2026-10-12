$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'History.ps1')

function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Get-QueryValue([string]$Path, [string]$Name) {
    $parts = $Path.Split('?', 2)
    if ($parts.Count -ne 2) { return $null }
    foreach ($pair in $parts[1].Split('&')) {
        $keyValue = $pair.Split('=', 2)
        if ($keyValue[0] -ceq $Name) { return [Uri]::UnescapeDataString($keyValue[1]) }
    }
    return $null
}

$china = [TimeZoneInfo]::CreateCustomTimeZone('HistoryTestUTC+08', [TimeSpan]::FromHours(8), 'UTC+08', 'UTC+08')
$day = [datetime]'2026-10-12'
$path = Get-CompletedHistoryRequestPath -Date $day -TimeZone $china
Assert $path.StartsWith('tasks/completed/by_completion_date?') 'History endpoint is wrong.'
Assert ((Get-QueryValue $path 'since') -ceq '2026-10-11T16:00:00Z') 'Start must be selected local midnight in UTC.'
Assert ((Get-QueryValue $path 'until') -ceq '2026-10-12T16:00:00Z') 'End must be next local midnight in UTC.'
Assert ((Get-QueryValue $path 'limit') -ceq '200') 'Page size is wrong.'
Assert ($null -eq (Get-QueryValue $path 'cursor')) 'First page must have no cursor.'

$cursorPath = Get-CompletedHistoryRequestPath -Date $day -TimeZone $china -Cursor 'a+b/=?' -Limit 50
Assert ((Get-QueryValue $cursorPath 'cursor') -ceq 'a+b/=?') 'Opaque cursor was not preserved.'
Assert ((Get-QueryValue $cursorPath 'limit') -ceq '50') 'Explicit page size was lost.'
Assert ($cursorPath.Contains('cursor=a%2Bb%2F%3D%3F')) 'Cursor was not URL encoded.'

# US DST changes make the local day 23 or 25 hours long. An independently
# converted following midnight must be used for the exclusive upper boundary.
try { $eastern = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time') }
catch { $eastern = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York') }
$spring = Get-CompletedHistoryRequestPath -Date ([datetime]'2026-03-08') -TimeZone $eastern
Assert ((Get-QueryValue $spring 'since') -ceq '2026-03-08T05:00:00Z') 'Spring DST start is wrong.'
Assert ((Get-QueryValue $spring 'until') -ceq '2026-03-09T04:00:00Z') 'Spring DST end is wrong.'
$fall = Get-CompletedHistoryRequestPath -Date ([datetime]'2026-11-01') -TimeZone $eastern
Assert ((Get-QueryValue $fall 'since') -ceq '2026-11-01T04:00:00Z') 'Fall DST start is wrong.'
Assert ((Get-QueryValue $fall 'until') -ceq '2026-11-02T05:00:00Z') 'Fall DST end is wrong.'

$overdueCompletedToday = [pscustomobject]@{
    id = 'a'; content = 'Overdue but completed today'; completed_at = '2026-10-11T16:00:00Z'
    due = [pscustomobject]@{ date = '2026-10-10' }; is_deleted = $false
}
$completedYesterday = @{ id = 'b'; content = 'Earlier'; completed_at = '2026-10-11T15:59:59Z'; is_deleted = $false }
$deleted = @{ id = 'c'; content = 'Deleted'; completed_at = '2026-10-12T00:00:00Z'; is_deleted = $true }
$later = @{ id = 'd'; content = 'After midnight'; completed_at = '2026-10-12T16:00:00Z'; is_deleted = $false }
Assert ((Get-CompletedHistoryDateKey -Task $overdueCompletedToday -TimeZone $china) -ceq '2026-10-12') 'Completion date was confused with due date.'
Assert ((Get-CompletedHistoryDateKey -Task $completedYesterday -TimeZone $china) -ceq '2026-10-11') 'Lower day boundary is wrong.'
Assert ((Get-CompletedHistoryDateKey -Task $later -TimeZone $china) -ceq '2026-10-13') 'Upper day boundary is wrong.'
Assert ((Get-CompletedHistoryDateKey -Task @{ completed_at = 'not a date' } -TimeZone $china) -ceq '') 'Invalid completion timestamp should be ignored.'

$response = [pscustomobject]@{ items = @($overdueCompletedToday, $completedYesterday); next_cursor = 'opaque-next' }
$page = Read-CompletedHistoryPage -Response $response
Assert ($page.Items.Count -eq 2 -and $page.Items[0].id -ceq 'a') 'Completed page items were not read.'
Assert ($page.NextCursor -ceq 'opaque-next') 'Pagination cursor was lost.'
$last = Read-CompletedHistoryPage -Response @{ items = @($deleted, $later); next_cursor = $null }
Assert ($last.Items.Count -eq 2 -and $null -eq $last.NextCursor) 'Last page was parsed incorrectly.'
$selected = @(Select-CompletedHistoryForDate -Items @($page.Items + $last.Items) -Date $day -TimeZone $china)
Assert ($selected.Count -eq 1 -and $selected[0].id -ceq 'a') 'Selected day included deleted or other-day tasks.'
Assert ($overdueCompletedToday.due.date -ceq '2026-10-10') 'Reading history mutated the source task.'

$wrongShapeRejected = $false
try { Read-CompletedHistoryPage -Response @{ results = @() } | Out-Null }
catch { $wrongShapeRejected = $true }
Assert $wrongShapeRejected 'A regular active-task response must not silently pass as completed history.'

Write-Output 'PASS: completed history UTC day boundaries, DST, cursor pagination, and completion-date filtering.'
