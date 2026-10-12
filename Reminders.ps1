# Local reminder scheduling. Todoist tasks are never changed by these helpers.
function Get-ReminderValue {
    param([AllowNull()][object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-ReminderInstant {
    param([AllowNull()][string]$DueDate)
    if ([string]::IsNullOrWhiteSpace($DueDate)) { return $null }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $styles = [Globalization.DateTimeStyles]::None
    $localDate = [DateTime]::MinValue

    if ($DueDate -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
        if (![DateTime]::TryParseExact($DueDate, 'yyyy-MM-dd', $culture, $styles, [ref]$localDate)) { return $null }
        # An all-day task is announced at 09:00 on its due date in local time.
        $localDate = [DateTime]::SpecifyKind($localDate.AddHours(9), [DateTimeKind]::Local)
        return [DateTimeOffset]::new($localDate)
    }

    $timePattern = '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]{1,7})?)?'
    if ($DueDate -match ('^' + $timePattern + '(?:Z|[+-][0-9]{2}:[0-9]{2})$')) {
        $fixedTime = [DateTimeOffset]::MinValue
        if (![DateTimeOffset]::TryParse($DueDate, $culture, $styles, [ref]$fixedTime)) { return $null }
        return $fixedTime.ToLocalTime()
    }
    if ($DueDate -match ('^' + $timePattern + '$')) {
        $formats = [string[]]@("yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF")
        if (![DateTime]::TryParseExact($DueDate, $formats, $culture, $styles, [ref]$localDate)) { return $null }
        $localDate = [DateTime]::SpecifyKind($localDate, [DateTimeKind]::Local)
        if ([TimeZoneInfo]::Local.IsInvalidTime($localDate)) { return $null }
        return [DateTimeOffset]::new($localDate)
    }
    return $null
}

function Get-ReminderOccurrence {
    param([AllowNull()][object]$Task)
    $id = Get-ReminderValue $Task 'id'
    if ($null -eq $id -or [string]::IsNullOrWhiteSpace([string]$id)) { return $null }
    $due = Get-ReminderValue $Task 'due'
    $dueDate = Get-ReminderValue $due 'datetime'
    if ([string]::IsNullOrWhiteSpace([string]$dueDate)) { $dueDate = Get-ReminderValue $due 'date' }
    if ($dueDate -isnot [string]) { return $null }
    $instant = ConvertTo-ReminderInstant $dueDate
    if ($null -eq $instant) { return $null }
    $taskId = [string]$id
    return [pscustomobject]@{
        Key = $taskId + '|' + $dueDate
        TaskId = $taskId
        DueDate = $dueDate
        At = $instant
        Task = $Task
        Title = [string](Get-ReminderValue $Task 'content')
    }
}

function ConvertTo-ReminderStateTime {
    param([AllowNull()][object]$Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if (![DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $null }
    return $parsed
}

function Get-NormalizedReminderState {
    param([AllowNull()][object]$State, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $normalized = @{ Version = 1; Entries = @{} }
    $source = Get-ReminderValue $State 'Entries'
    $pairs = @()
    if ($source -is [Collections.IDictionary]) {
        $pairs = @($source.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Value = $_.Value } })
    } elseif ($source -is [pscustomobject]) {
        $pairs = @($source.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Value = $_.Value } })
    }
    foreach ($pair in $pairs) {
        $key = [string]$pair.Key
        if ([string]::IsNullOrWhiteSpace($key) -or $key.Length -gt 256) { continue }
        $status = Get-ReminderValue $pair.Value 'Status'
        if ($status -cnotin @('Shown', 'Snoozed', 'Dismissed')) { continue }
        $updatedAt = ConvertTo-ReminderStateTime (Get-ReminderValue $pair.Value 'UpdatedAt')
        if ($null -eq $updatedAt) { continue }
        if ($updatedAt -lt $Now.AddDays(-90) -or $updatedAt -gt $Now.AddDays(1)) { continue }
        $nextAt = $null
        if ($status -eq 'Snoozed') {
            $nextAt = ConvertTo-ReminderStateTime (Get-ReminderValue $pair.Value 'NextAt')
            if ($null -eq $nextAt) { continue }
        }
        $normalized.Entries[$key] = @{
            Status = [string]$status
            NextAt = $(if ($null -ne $nextAt) { $nextAt.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
            UpdatedAt = $updatedAt.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    if ($normalized.Entries.Count -gt 1200) {
        $keep = @($normalized.Entries.GetEnumerator() |
            Sort-Object { [DateTimeOffset]::Parse($_.Value.UpdatedAt, [Globalization.CultureInfo]::InvariantCulture) } -Descending |
            Select-Object -First 1200)
        $bounded = @{}
        foreach ($entry in $keep) { $bounded[$entry.Key] = $entry.Value }
        $normalized.Entries = $bounded
    }
    return $normalized
}

function Read-ReminderState {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (![IO.File]::Exists($Path)) { return Get-NormalizedReminderState $null }
        if (([IO.FileInfo]::new($Path)).Length -gt 262144) { throw 'Reminder state is too large.' }
        $saved = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        return Get-NormalizedReminderState $saved
    } catch {
        return Get-NormalizedReminderState $null
    }
}

function Save-ReminderState {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$State,
          [Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Reminder state path is required.' }
    $normalized = Get-NormalizedReminderState $State
    $target = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($target)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.reminders-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $normalized | ConvertTo-Json -Compress -Depth 5
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($target)) {
            [IO.File]::Replace($temporary, $target, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $target)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-DueReminders {
    param([AllowNull()][object[]]$Tasks,
          [AllowNull()][object]$State,
          [AllowNull()][object]$PendingIds = $null,
          [DateTimeOffset]$Now = [DateTimeOffset]::Now,
          [ValidateRange(1, 1440)][int]$CatchUpMinutes = 120)
    $entries = Get-ReminderValue $State 'Entries'
    $seen = @{}
    foreach ($task in $Tasks) {
        if ((Get-ReminderValue $task 'checked') -eq $true -or
            (Get-ReminderValue $task 'is_completed') -eq $true -or
            $null -ne (Get-ReminderValue $task 'completed_at')) { continue }
        $occurrence = Get-ReminderOccurrence $task
        if ($null -eq $occurrence -or $seen.ContainsKey($occurrence.Key)) { continue }
        $seen[$occurrence.Key] = $true
        if ($PendingIds -is [Collections.IDictionary] -and $PendingIds.Contains($occurrence.TaskId)) { continue }
        if ($PendingIds -isnot [Collections.IDictionary] -and $null -ne $PendingIds -and @($PendingIds) -contains $occurrence.TaskId) { continue }
        $entry = Get-ReminderValue $entries $occurrence.Key
        $status = Get-ReminderValue $entry 'Status'
        if ($status -in @('Shown', 'Dismissed')) { continue }
        $triggerAt = $occurrence.At
        if ($status -eq 'Snoozed') {
            $triggerAt = ConvertTo-ReminderStateTime (Get-ReminderValue $entry 'NextAt')
            if ($null -eq $triggerAt) { continue }
        }
        $elapsed = ($Now - $triggerAt).TotalMinutes
        if ($elapsed -lt 0) { continue }
        $isAllDay = $occurrence.DueDate -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        if ($isAllDay -and $status -ne 'Snoozed') {
            # The 09:00 reminder remains eligible until midnight of its due date.
            # An overdue all-day task must not suddenly remind on a later day.
            if ($Now.ToLocalTime().Date -ne $triggerAt.ToLocalTime().Date) { continue }
        } elseif ($elapsed -gt $CatchUpMinutes) {
            # Timed and snoozed reminders have a bounded catch-up window.
            continue
        }
        $occurrence | Add-Member -NotePropertyName TriggerAt -NotePropertyValue $triggerAt
        $occurrence
    }
}

function Set-ReminderOccurrenceState {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$State,
          [Parameter(Mandatory = $true)][object]$Occurrence,
          [ValidateSet('Shown', 'Snoozed', 'Dismissed')][string]$Status,
          [AllowNull()][object]$NextAt = $null,
          [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $State['Entries'] -or $State['Entries'] -isnot [Collections.IDictionary]) { $State['Entries'] = @{} }
    $key = [string](Get-ReminderValue $Occurrence 'Key')
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Reminder occurrence key is required.' }
    $State['Entries'][$key] = @{
        Status = $Status
        NextAt = $(if ($null -ne $NextAt) { ([DateTimeOffset]$NextAt).ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
        UpdatedAt = $Now.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Mark-ReminderShown {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$State,
          [Parameter(Mandatory = $true)][object]$Occurrence,
          [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    Set-ReminderOccurrenceState -State $State -Occurrence $Occurrence -Status Shown -Now $Now
}

function Snooze-ReminderOccurrence {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$State,
          [Parameter(Mandatory = $true)][object]$Occurrence,
          [ValidateRange(1, 1440)][int]$Minutes = 10,
          [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    Set-ReminderOccurrenceState -State $State -Occurrence $Occurrence -Status Snoozed -NextAt $Now.AddMinutes($Minutes) -Now $Now
}

function Dismiss-ReminderOccurrence {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$State,
          [Parameter(Mandatory = $true)][object]$Occurrence,
          [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    Set-ReminderOccurrenceState -State $State -Occurrence $Occurrence -Status Dismissed -Now $Now
}
