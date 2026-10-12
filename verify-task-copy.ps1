$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Calendar.ps1')
. (Join-Path $PSScriptRoot 'TaskCopy.ps1')

function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

$today = [datetime]'2026-10-12'
$source = @{
    id = 'source-1'; content = '写实验记录'; description = '记录测量条件'
    project_id = 'project-1'; section_id = 'section-1'; parent_id = 'old-parent'
    labels = @('研究', '本周'); priority = 3; checked = $false
    due = @{ date = '2026-10-10'; string = 'every day'; is_recurring = $true }
}
$body = New-TodayCopyRequestBody -Task $source -Today $today
Assert ($body.content -ceq $source.content) 'Copy lost task title.'
Assert ($body.description -ceq $source.description) 'Copy lost description.'
Assert ($body.project_id -ceq $source.project_id -and $body.section_id -ceq $source.section_id) 'Copy lost project or section.'
Assert (($body.labels -join '|') -ceq ($source.labels -join '|') -and $body.priority -eq 3) 'Copy lost labels or priority.'
Assert ($body.due_date -ceq '2026-10-12') 'All-day task was not copied to today.'
foreach ($name in 'id','parent_id','due_string','due','is_recurring','due_datetime') {
    Assert (!$body.ContainsKey($name)) "Copy incorrectly reused $name."
}
Assert ($source.due.date -ceq '2026-10-10' -and $source.due.is_recurring) 'Building a copy mutated the source task.'

$floating = @{ content = '下午核对'; due = @{ date = '2026-10-10T14:05:07.000000'; timezone = $null } }
$body = New-TodayCopyRequestBody -Task $floating -Today $today
$expectedUtc = [TimeZoneInfo]::ConvertTimeToUtc([datetime]'2026-10-12T14:05:07', [TimeZoneInfo]::Local)
Assert ($body.due_datetime -ceq $expectedUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)) 'Floating due time was not kept at the same local clock time.'
Assert (!$body.ContainsKey('due_date')) 'Timed copy must not also set all-day date.'

$fixed = @{ content = '固定时区'; due = @{ date = '2026-10-10T01:30:00Z'; timezone = 'Asia/Shanghai' } }
$body = New-TodayCopyRequestBody -Task $fixed -Today $today
$localClock = ([DateTimeOffset]::Parse($fixed.due.date, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime()
$expectedUtc = [TimeZoneInfo]::ConvertTimeToUtc($today.Date.AddHours($localClock.Hour).AddMinutes($localClock.Minute), [TimeZoneInfo]::Local)
Assert ($body.due_datetime -ceq $expectedUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)) 'Timezone due time was not kept at the same computer-local clock time.'

$separateTimestamp = @{ content = '单独时间字段'; due = @{ date = '2026-10-10'; datetime = '2026-10-10T06:30:00Z' } }
$body = New-TodayCopyRequestBody -Task $separateTimestamp -Today $today
Assert ($body.ContainsKey('due_datetime') -and !$body.ContainsKey('due_date')) 'Separate due.datetime must retain its clock time.'

$completed = @{ content = '已经完成'; checked = $true; due = @{date='2026-10-10'} }
$rejected = $false
try { New-TodayCopyRequestBody -Task $completed -Today $today | Out-Null } catch { $rejected = $true }
Assert $rejected 'Completed task was accepted for copying.'

Write-Output 'PASS: individual copy payload preserves metadata, keeps local due time, excludes recurrence/parent, and rejects completed tasks.'
