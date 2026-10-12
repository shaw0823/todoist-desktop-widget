$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Reminders.ps1')

function Assert-Reminder($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = Join-Path $root ('.reminders-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    $today = [DateTime]::Today
    $todayKey = $today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $tomorrowKey = $today.AddDays(1).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $now = [DateTimeOffset]::new([DateTime]::SpecifyKind($today.AddHours(9), [DateTimeKind]::Local))
    $allDay = @{ id = 'all-day'; content = '全天事项'; due = @{ date = $todayKey } }
    $floating = @{ id = 'floating'; content = '浮动时间'; due = @{ date = $todayKey + 'T09:00:00.000000' } }
    $fixed = @{ id = 'fixed'; content = '固定时间'; due = @{ date = $now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } }
    $offset = @{ id = 'offset'; content = '偏移时间'; due = @{ date = $now.ToOffset([TimeSpan]::FromHours(-4)).ToString("yyyy-MM-dd'T'HH:mm:sszzz") } }
    $legacy = @{ id = 'legacy'; content = '旧格式'; due = @{ date = $todayKey; datetime = $now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } }
    $invalid = @{ id = 'invalid'; content = '无效时间'; due = @{ date = '2026-13-99' } }

    foreach ($task in @($allDay, $floating, $fixed, $offset, $legacy)) {
        $occurrence = Get-ReminderOccurrence $task
        Assert-Reminder ($null -ne $occurrence) "No occurrence for $($task.id)."
        Assert-Reminder ($occurrence.At -eq $now) "Wrong local trigger instant for $($task.id): $($occurrence.At)."
        Assert-Reminder ($occurrence.Key.StartsWith($task.id + '|')) "Unstable occurrence key for $($task.id)."
    }
    Assert-Reminder ($null -eq (Get-ReminderOccurrence $invalid)) 'Invalid due date was accepted.'
    Assert-Reminder ($null -eq (Get-ReminderOccurrence @{ id = 'no-due'; content = '无到期时间' })) 'Undated task was accepted.'

    $state = Get-NormalizedReminderState $null -Now $now
    $completed = @{ id = 'completed'; content = '完成'; due = @{ date = $todayKey }; checked = $true }
    $completedAt = @{ id = 'completed-at'; content = '完成时间'; due = @{ date = $todayKey }; completed_at = $now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $tasks = @($allDay, $floating, $fixed, $offset, $legacy, $completed, $completedAt, $invalid)
    $due = @(Get-DueReminders -Tasks $tasks -State $state -PendingIds @{ fixed = $true } -Now $now)
    Assert-Reminder ($due.Count -eq 4) "Expected four due tasks after pending/completed exclusion, got $($due.Count)."
    Assert-Reminder (@($due | Where-Object TaskId -eq 'fixed').Count -eq 0) 'Pending completion was reminded.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $state -Now $now.AddMinutes(-1)).Count -eq 0) 'All-day reminder triggered before 09:00.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $state -Now $now.AddMinutes(60)).Count -eq 1) 'Catch-up missed a recent due task.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $state -Now $now.AddHours(14).AddMinutes(59)).Count -eq 1) 'All-day reminder disappeared before local midnight.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $state -Now $now.AddHours(15)).Count -eq 0) 'Previous-day all-day reminder appeared after midnight.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($floating) -State $state -Now $now.AddMinutes(121)).Count -eq 0) 'Stale timed task caused a delayed popup.'

    $lateState = Get-NormalizedReminderState $null -Now $now
    $lateNight = $now.AddHours(14).AddMinutes(55)
    Snooze-ReminderOccurrence -State $lateState -Occurrence (Get-ReminderOccurrence $allDay) -Minutes 10 -Now $lateNight
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $lateState -Now $lateNight.AddMinutes(9)).Count -eq 0) 'Snoozed all-day reminder appeared before midnight trigger.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $lateState -Now $lateNight.AddMinutes(10)).Count -eq 1) 'Snoozed all-day reminder was lost across midnight.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $lateState -Now $lateNight.AddMinutes(131)).Count -eq 0) 'Stale snoozed reminder exceeded catch-up window.'

    $occurrence = Get-ReminderOccurrence $allDay
    Mark-ReminderShown -State $state -Occurrence $occurrence -Now $now
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $state -Now $now).Count -eq 0) 'Shown reminder appeared twice.'
    Snooze-ReminderOccurrence -State $state -Occurrence $occurrence -Minutes 10 -Now $now
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $state -Now $now.AddMinutes(9)).Count -eq 0) 'Snoozed reminder appeared too early.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $state -Now $now.AddMinutes(10)).Count -eq 1) 'Snoozed reminder did not return.'

    $path = Join-Path $fixture 'reminders.json'
    Save-ReminderState -State $state -Path $path
    $loaded = Read-ReminderState -Path $path
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $loaded -Now $now.AddMinutes(10)).Count -eq 1) 'Snooze did not survive restart.'
    Dismiss-ReminderOccurrence -State $loaded -Occurrence $occurrence -Now $now.AddMinutes(10)
    Save-ReminderState -State $loaded -Path $path
    $loaded = Read-ReminderState -Path $path
    Assert-Reminder (@(Get-DueReminders -Tasks @($allDay) -State $loaded -Now $now.AddMinutes(11)).Count -eq 0) 'Dismissed reminder returned after restart.'

    $tomorrow = @{ id = 'all-day'; content = '循环任务'; due = @{ date = $tomorrowKey } }
    Assert-Reminder ((Get-ReminderOccurrence $tomorrow).Key -ne $occurrence.Key) 'Recurring occurrence reused the previous key.'
    Assert-Reminder (@(Get-DueReminders -Tasks @($tomorrow) -State $loaded -Now $now.AddDays(1)).Count -eq 1) 'Next recurring due date was suppressed.'

    [IO.File]::WriteAllText($path, '{broken json', [Text.Encoding]::UTF8)
    Assert-Reminder ((Read-ReminderState -Path $path).Entries.Count -eq 0) 'Corrupt state did not recover safely.'
    'PASS: all-day 09:00 through due-date midnight, timed catch-up, cross-midnight snooze, completion exclusion, dedup, dismiss, recurrence, and persistence.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith($root + '\.reminders-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe reminder test cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
