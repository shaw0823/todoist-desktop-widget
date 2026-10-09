$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Calendar.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}

function Assert-MonthGrid([DateTime]$Month, [int]$ExpectedCount, [string]$ExpectedStart, [string]$ExpectedEnd) {
    $days = @(Get-CalendarDays $Month)
    Assert-Equal $days.Count $ExpectedCount 'Full calendar week count'
    Assert-Equal $days[0].ToString('yyyy-MM-dd') $ExpectedStart 'First calendar date'
    Assert-Equal $days[-1].ToString('yyyy-MM-dd') $ExpectedEnd 'Last calendar date'
    Assert-Equal $days[0].DayOfWeek ([DayOfWeek]::Monday) 'Calendar begins on Monday'
    Assert-Equal $days[-1].DayOfWeek ([DayOfWeek]::Sunday) 'Calendar ends on Sunday'
    for ($index = 0; $index -lt $days.Count; $index++) {
        if ($days[$index] -isnot [DateTime]) { throw 'Calendar dates must be DateTime values' }
        Assert-Equal $days[$index].TimeOfDay.Ticks 0 'Calendar dates have no time component'
        if ($index) { Assert-Equal ($days[$index] - $days[$index - 1]).Days 1 'No skipped or duplicate calendar dates' }
    }
    $inMonth = @($days | Where-Object { $_.Month -eq $Month.Month -and $_.Year -eq $Month.Year })
    Assert-Equal $inMonth.Count ([DateTime]::DaysInMonth($Month.Year, $Month.Month)) 'Every date in the month is present'
}

Assert-MonthGrid ([DateTime]::new(2026, 10, 9, 23, 15, 0)) 35 '2026-09-28' '2026-11-01'
Assert-MonthGrid ([DateTime]::new(2026, 8, 1)) 42 '2026-07-27' '2026-09-06'
Assert-MonthGrid ([DateTime]::new(2021, 2, 15)) 35 '2021-02-01' '2021-03-07'
Assert-MonthGrid ([DateTime]::new(2024, 2, 1)) 35 '2024-01-29' '2024-03-03'
Assert-MonthGrid ([DateTime]::new(2025, 12, 15)) 35 '2025-12-01' '2026-01-04'
Assert-MonthGrid ([DateTime]::new(2023, 1, 15)) 42 '2022-12-26' '2023-02-05'

$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('ar-SA')
    Assert-Equal (Get-TaskDateKey @{ due = @{ date = '2024-02-29' } }) '2024-02-29' 'Leap date under a non-Gregorian current culture'
    Assert-Equal (Get-TaskDateKey ([pscustomobject]@{ due = [pscustomobject]@{ date = '2026-10-09T23:30:00-12:00'; datetime = '2026-10-10T11:30:00Z' } })) '2026-10-09' 'Due date takes priority without a timezone shift'
    Assert-Equal (Get-TaskDateKey @{ due = @{ datetime = '2026-10-09T00:30:00+14:00' } }) '2026-10-09' 'Datetime fallback preserves its date prefix'
    foreach ($invalid in @($null, @{}, @{ due = $null }, @{ due = @{} }, @{ due = @{ date = '2023-02-29' } }, @{ due = @{ date = '2026-13-01' } }, @{ due = @{ date = '2026-04-31' } }, @{ due = @{ date = '10/09/2026' } }, @{ due = @{ date = '2026-10-09 trailing text' } }, @{ due = @{ date = 20261009 } })) {
        Assert-Equal (Get-TaskDateKey $invalid) '' 'Missing or invalid due dates are safely ignored'
    }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }

$tasks = @(
    [pscustomobject]@{ id = 'late'; content = 'Evening task'; due = @{ date = '2026-10-09T20:00:00' }; order = 0 },
    [pscustomobject]@{ id = 'day-b'; content = 'Second all-day task'; due = @{ date = '2026-10-09' }; order = 9 },
    [pscustomobject]@{ id = 'single'; content = 'Single task'; due = @{ date = '2026-10-10' }; order = 0 },
    [pscustomobject]@{ id = 'pending'; content = 'Completing task'; due = @{ date = '2026-10-09' }; order = 1 },
    [pscustomobject]@{ id = 'early'; content = 'Morning task'; due = @{ date = '2026-10-09T08:00:00' }; order = 20 },
    [pscustomobject]@{ id = 'day-a'; content = 'First all-day task'; due = @{ date = '2026-10-09' }; order = 2 },
    [pscustomobject]@{ id = 'undated'; content = 'Undated task'; due = $null; order = 0 },
    [pscustomobject]@{ id = 'bad'; content = 'Invalid due date'; due = @{ date = '2026-02-30' }; order = 0 },
    [pscustomobject]@{ id = 'fallback'; content = 'Datetime-only task'; due = @{ datetime = '2026-10-11T12:00:00Z' }; order = 0 }
)
$groups = Get-CalendarTaskGroups $tasks @{ pending = $true }
if ($groups -isnot [hashtable]) { throw 'Grouped tasks must return a hashtable' }
Assert-Equal $groups.Count 3 'Only valid, dated and non-pending tasks are grouped'
Assert-Equal ($groups['2026-10-09'].id -join ',') 'day-a,day-b,early,late' 'Task order follows written due date, then Todoist order'
foreach ($key in $groups.Keys) {
    if ($groups[$key] -isnot [object[]]) { throw 'Every date group must remain an array, including single task groups' }
}
Assert-Equal $groups['2026-10-10'].Count 1 'Single task group is not unwrapped'
Assert-Equal $groups['2026-10-11'][0].id 'fallback' 'Datetime-only tasks are included'
Assert-Equal (Get-CalendarTaskGroups $tasks $null)['2026-10-09'].Count 5 'Null pending set is accepted'
Assert-Equal (Get-CalendarTaskGroups @() @{}).Count 0 'Empty task collection returns an empty hashtable'
Assert-Equal $tasks.Count 9 'Grouping does not change the task collection'

Write-Output 'PASS: Monday-first month grids, leap/year boundaries, invariant Todoist date keys, and pending-aware ordered task groups.'
