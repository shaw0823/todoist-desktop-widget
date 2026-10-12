# Durable Todoist task state. Keep the token in memory: only its SHA-256
# fingerprint is used to select an account-specific cache and operation queue.

function Get-OfflineTaskAccountKey {
    param([Parameter(Mandatory = $true)][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { throw '需要 Todoist API Token。' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Token))
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-OfflineTaskValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function New-OfflineTaskStoreData {
    param([string]$AccountKey)
    return @{
        Version = 1
        AccountKey = $AccountKey
        SnapshotAt = $null
        Snapshot = @()
        Queue = @()
        CopyReceipts = @{}
    }
}

function ConvertFrom-OfflineTaskStoreJson {
    param([string]$Json, [string]$AccountKey)
    $raw = $Json | ConvertFrom-Json
    if ($null -eq $raw -or [int](Get-OfflineTaskValue $raw 'Version') -ne 1) { throw '离线任务文件版本无效。' }
    if ([string](Get-OfflineTaskValue $raw 'AccountKey') -cne $AccountKey) { throw '离线任务文件不属于当前 Todoist 账号。' }
    $queue = @()
    $seen = @{}
    $rawQueue = Get-OfflineTaskValue $raw 'Queue'
    foreach ($item in $rawQueue) {
        if ($null -eq $item) { continue }
        $id = [string](Get-OfflineTaskValue $item 'Id')
        $kind = [string](Get-OfflineTaskValue $item 'Kind')
        $state = [string](Get-OfflineTaskValue $item 'State')
        $parsed = [guid]::Empty
        if (![guid]::TryParse($id, [ref]$parsed) -or $seen.ContainsKey($id)) { throw '离线任务队列含有无效或重复的操作 ID。' }
        if ($kind -notin @('Add', 'Copy', 'Close') -or $state -notin @('Pending', 'InFlight', 'Failed', 'Acknowledged')) { throw '离线任务队列含有无效操作。' }
        $seen[$id] = $true
        $queue += @{
            Id = $id; Kind = $kind; State = $state
            TempId = [string](Get-OfflineTaskValue $item 'TempId')
            ServerId = [string](Get-OfflineTaskValue $item 'ServerId')
            TaskId = [string](Get-OfflineTaskValue $item 'TaskId')
            OriginalDue = [string](Get-OfflineTaskValue $item 'OriginalDue')
            OriginalCompletedCount = $(if ($null -ne (Get-OfflineTaskValue $item 'OriginalCompletedCount')) { [int](Get-OfflineTaskValue $item 'OriginalCompletedCount') } else { $null })
            SourceId = [string](Get-OfflineTaskValue $item 'SourceId')
            TargetDate = [string](Get-OfflineTaskValue $item 'TargetDate')
            Payload = Get-OfflineTaskValue $item 'Payload'
            CreatedAt = [string](Get-OfflineTaskValue $item 'CreatedAt')
            Attempts = [int](Get-OfflineTaskValue $item 'Attempts')
            Error = [string](Get-OfflineTaskValue $item 'Error')
        }
    }
    $receipts = @{}
    $rawReceipts = Get-OfflineTaskValue $raw 'CopyReceipts'
    if ($null -ne $rawReceipts) {
        foreach ($entry in $rawReceipts.PSObject.Properties) { $receipts[[string]$entry.Name] = [string]$entry.Value }
    }
    return @{
        Version = 1
        AccountKey = $AccountKey
        SnapshotAt = Get-OfflineTaskValue $raw 'SnapshotAt'
        Snapshot = @((Get-OfflineTaskValue $raw 'Snapshot') | Where-Object { $null -ne $_ })
        Queue = $queue
        CopyReceipts = $receipts
    }
}

function Save-OfflineTaskStore {
    param([Parameter(Mandatory = $true)]$Context)
    $path = [string]$Context.Path
    $folder = [IO.Path]::GetDirectoryName($path)
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $json = $Context.Store | ConvertTo-Json -Depth 40 -Compress
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temporary, $path, $path + '.bak', $true)
        } else {
            [IO.File]::Move($temporary, $path)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Open-OfflineTaskStore {
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $accountKey = Get-OfflineTaskAccountKey -Token $Token
    $path = Join-Path $DataDir ('offline-' + $accountKey + '.json')
    $store = New-OfflineTaskStoreData -AccountKey $accountKey
    $recovery = ''
    if ([IO.File]::Exists($path)) {
        try {
            $store = ConvertFrom-OfflineTaskStoreJson -Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -AccountKey $accountKey
        } catch {
            $backup = $path + '.bak'
            if (![IO.File]::Exists($backup)) { throw "离线任务文件无法读取，原文件已保留：$path。$($_.Exception.Message)" }
            try {
                $store = ConvertFrom-OfflineTaskStoreJson -Json ([IO.File]::ReadAllText($backup, [Text.Encoding]::UTF8)) -AccountKey $accountKey
            } catch { throw "离线任务文件和备份均无法读取，文件已保留：$path。$($_.Exception.Message)" }
            $corrupt = $path + '.corrupt-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N')
            [IO.File]::Move($path, $corrupt)
            [IO.File]::Copy($backup, $path)
            $recovery = $corrupt
        }
    }
    $context = @{ Path = $path; AccountKey = $accountKey; Store = $store; RecoveredCorruptPath = $recovery }
    $changed = $false
    foreach ($operation in $store.Queue) {
        if ($operation.State -eq 'InFlight') { $operation.State = 'Pending'; $changed = $true }
    }
    if ($changed) { Save-OfflineTaskStore -Context $context }
    return $context
}

function Set-OfflineTaskSnapshot {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][object[]]$Tasks)
    $Context.Store.Snapshot = @($Tasks)
    $Context.Store.SnapshotAt = [DateTime]::UtcNow.ToString('o')
    $snapshotById = @{}
    foreach ($task in $Context.Store.Snapshot) {
        $id = [string](Get-OfflineTaskValue $task 'id')
        if ($id) { $snapshotById[$id] = $task }
    }
    # A write acknowledgement can precede an up-to-date task listing. Keep its
    # local projection until this particular change is visible in a fetch.
    $Context.Store.Queue = @($Context.Store.Queue | Where-Object {
        if ($_.State -ne 'Acknowledged') { return $true }
        if ($_.Kind -eq 'Close') {
            $taskId = [string]$_.TaskId
            if (!$snapshotById.ContainsKey($taskId)) { return $false }
            $serverTask = $snapshotById[$taskId]
            $due = Get-OfflineTaskValue $serverTask 'due'
            $currentDue = [string](Get-OfflineTaskValue $due 'date')
            if (!$currentDue) { $currentDue = [string](Get-OfflineTaskValue $due 'datetime') }
            if ($_.OriginalDue -and $currentDue -and $_.OriginalDue -cne $currentDue) { return $false }
            $currentCount = Get-OfflineTaskValue $serverTask 'completed_count'
            if ($null -ne $_.OriginalCompletedCount -and $null -ne $currentCount -and [int]$currentCount -gt [int]$_.OriginalCompletedCount) { return $false }
            return $true
        }
        return !$_.ServerId -or !$snapshotById.ContainsKey([string]$_.ServerId)
    })
    Save-OfflineTaskStore -Context $Context
}

function Get-OfflineCopyKey {
    param([string]$SourceId, [string]$TargetDate)
    return $SourceId + '|' + $TargetDate
}

function Add-OfflineTaskOperation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('Add', 'Copy', 'Close')][string]$Kind,
        $Payload = $null,
        [string]$TaskId = '',
        [string]$OriginalDue = '',
        [Nullable[int]]$OriginalCompletedCount = $null,
        [string]$SourceId = '',
        [string]$TargetDate = ''
    )
    if ($Kind -eq 'Close' -and [string]::IsNullOrWhiteSpace($TaskId)) { throw '完成待办需要任务 ID。' }
    if ($Kind -ne 'Close' -and [string]::IsNullOrWhiteSpace([string](Get-OfflineTaskValue $Payload 'content'))) { throw '新增待办需要标题。' }
    if ($Kind -eq 'Add' -and [string]::IsNullOrWhiteSpace($TargetDate)) {
        $dueDate = [string](Get-OfflineTaskValue $Payload 'due_date')
        if ($dueDate -match '^\d{4}-\d{2}-\d{2}$') { $TargetDate = $dueDate }
        else {
            $dueDateTime = [string](Get-OfflineTaskValue $Payload 'due_datetime')
            if (![string]::IsNullOrWhiteSpace($dueDateTime)) {
                $TargetDate = ([DateTimeOffset]::Parse($dueDateTime, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('yyyy-MM-dd')
            }
        }
    }
    if ($Kind -eq 'Copy') {
        if ([string]::IsNullOrWhiteSpace($SourceId) -or $TargetDate -notmatch '^\d{4}-\d{2}-\d{2}$') { throw '复制待办需要来源 ID 和目标日期。' }
        $copyKey = Get-OfflineCopyKey -SourceId $SourceId -TargetDate $TargetDate
        if ($Context.Store.CopyReceipts.ContainsKey($copyKey) -or @($Context.Store.Queue | Where-Object { $_.Kind -eq 'Copy' -and $_.SourceId -eq $SourceId -and $_.TargetDate -eq $TargetDate -and $_.State -ne 'Failed' }).Count) {
            throw '这条待办已经复制到指定日期，或正在等待同步。'
        }
    }
    if ($Kind -eq 'Close' -and @($Context.Store.Queue | Where-Object { $_.Kind -eq 'Close' -and $_.TaskId -eq $TaskId -and $_.State -ne 'Failed' }).Count) {
        throw '这条待办已经在等待完成同步。'
    }
    $id = [guid]::NewGuid().ToString()
    $operation = @{
        Id = $id; Kind = $Kind; State = 'Pending'
        TempId = $(if ($Kind -eq 'Close') { '' } else { [guid]::NewGuid().ToString() })
        ServerId = ''
        TaskId = $TaskId; OriginalDue = $OriginalDue; OriginalCompletedCount = $OriginalCompletedCount
        SourceId = $SourceId; TargetDate = $TargetDate
        Payload = $Payload; CreatedAt = [DateTime]::UtcNow.ToString('o')
        Attempts = 0; Error = ''
    }
    $Context.Store.Queue = @($Context.Store.Queue) + @($operation)
    try { Save-OfflineTaskStore -Context $Context }
    catch {
        $Context.Store.Queue = @($Context.Store.Queue | Where-Object { $_.Id -ne $id })
        throw
    }
    return $operation
}

function Get-OfflinePendingOperation {
    param([Parameter(Mandatory = $true)]$Context)
    return @($Context.Store.Queue | Where-Object { $_.State -eq 'Pending' } | Sort-Object { $_.CreatedAt } | Select-Object -First 1)[0]
}

function Get-OfflineTaskOperation {
    param($Context, [string]$Id)
    return @($Context.Store.Queue | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)[0]
}

function Set-OfflineTaskOperationInFlight {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Id)
    $operation = Get-OfflineTaskOperation -Context $Context -Id $Id
    if ($null -eq $operation -or $operation.State -ne 'Pending') { throw '待办操作未处于可同步状态。' }
    $operation.State = 'InFlight'
    $operation.Attempts = [int]$operation.Attempts + 1
    try { Save-OfflineTaskStore -Context $Context }
    catch { $operation.State = 'Pending'; $operation.Attempts--; throw }
    return $operation
}

function ConvertTo-OfflineSyncCommand {
    param([Parameter(Mandatory = $true)]$Operation)
    if ($Operation.Kind -eq 'Close') {
        return @{ type = 'item_close'; uuid = [string]$Operation.Id; args = @{ id = [string]$Operation.TaskId } }
    }
    if ($Operation.Kind -notin @('Add', 'Copy')) { throw '不支持的离线待办操作。' }
    $payload = $Operation.Payload
    $args = @{ content = [string](Get-OfflineTaskValue $payload 'content') }
    foreach ($name in @('description', 'project_id', 'section_id', 'parent_id', 'labels', 'priority')) {
        $value = Get-OfflineTaskValue $payload $name
        if ($null -ne $value) { $args[$name] = $value }
    }
    $dueDate = Get-OfflineTaskValue $payload 'due_date'
    $dueDateTime = Get-OfflineTaskValue $payload 'due_datetime'
    $due = Get-OfflineTaskValue $payload 'due'
    if ($null -ne $dueDate -and $null -ne $dueDateTime) { throw '待办不能同时设置全天日期和具体时间。' }
    if ($null -ne $dueDateTime) { $args.due = @{ date = [string]$dueDateTime } }
    elseif ($null -ne $dueDate) { $args.due = @{ date = [string]$dueDate } }
    elseif ($null -ne $due) { $args.due = $due }
    return @{ type = 'item_add'; uuid = [string]$Operation.Id; temp_id = [string]$Operation.TempId; args = $args }
}

function Reset-OfflineTaskOperation {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Id, [string]$ErrorMessage = '')
    $operation = Get-OfflineTaskOperation -Context $Context -Id $Id
    if ($null -eq $operation) { throw '找不到待办操作。' }
    $operation.State = 'Pending'
    $operation.Error = $ErrorMessage
    Save-OfflineTaskStore -Context $Context
    return $operation
}

function Complete-OfflineTaskOperation {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)]$Response)
    $operation = Get-OfflineTaskOperation -Context $Context -Id $Id
    if ($null -eq $operation) { throw '找不到待办操作。' }
    $statuses = Get-OfflineTaskValue $Response 'sync_status'
    $status = Get-OfflineTaskValue $statuses $Id
    if ($status -ceq 'ok') {
        $operation.State = 'Acknowledged'
        $operation.Error = ''
        if ($operation.Kind -ne 'Close') {
            $mapping = Get-OfflineTaskValue $Response 'temp_id_mapping'
            $operation.ServerId = [string](Get-OfflineTaskValue $mapping $operation.TempId)
        }
        if ($operation.Kind -eq 'Copy') {
            $copyKey = Get-OfflineCopyKey -SourceId $operation.SourceId -TargetDate $operation.TargetDate
            $Context.Store.CopyReceipts[$copyKey] = $operation.Id
        }
    } elseif ($null -eq $status) {
        # A missing outcome is indeterminate. Retry with the same UUID.
        $operation.State = 'Pending'
        $operation.Error = 'Todoist 未返回这条操作的结果，将使用原操作 ID 重试。'
    } else {
        $operation.State = 'Failed'
        $message = Get-OfflineTaskValue $status 'error'
        if ([string]::IsNullOrWhiteSpace([string]$message)) { $message = 'Todoist 拒绝了这条操作。' }
        $operation.Error = [string]$message
    }
    Save-OfflineTaskStore -Context $Context
    return $operation
}

function Get-OfflineProjectedTasks {
    param([Parameter(Mandatory = $true)]$Context)
    $closed = @{}
    $snapshotIds = @{}
    foreach ($task in @($Context.Store.Snapshot)) { $snapshotIds[[string](Get-OfflineTaskValue $task 'id')] = $true }
    $created = @()
    foreach ($operation in @($Context.Store.Queue)) {
        if ($operation.State -eq 'Failed') { continue }
        if ($operation.Kind -eq 'Close') { $closed[[string]$operation.TaskId] = $true; continue }
        if ($operation.ServerId -and $snapshotIds.ContainsKey([string]$operation.ServerId)) { continue }
        $payload = $operation.Payload
        $due = Get-OfflineTaskValue $payload 'due'
        if ($null -eq $due) {
            $date = Get-OfflineTaskValue $payload 'due_datetime'
            if ($null -eq $date) { $date = Get-OfflineTaskValue $payload 'due_date' }
            if ($null -ne $date) { $due = @{ date = [string]$date } }
        }
        if ($operation.TargetDate -match '^\d{4}-\d{2}-\d{2}$') {
            # Calendar.ps1 intentionally takes the written date of a due object.
            # A UTC timestamp can belong to tomorrow/ yesterday locally, so a
            # pending create uses its selected local date until Todoist replies.
            $due = @{ date = [string]$operation.TargetDate }
        }
        $created += [pscustomobject]@{
            id = $(if ($operation.ServerId) { [string]$operation.ServerId } else { 'offline-' + [string]$operation.Id })
            content = [string](Get-OfflineTaskValue $payload 'content')
            description = [string](Get-OfflineTaskValue $payload 'description')
            due = $due
            labels = Get-OfflineTaskValue $payload 'labels'
            priority = Get-OfflineTaskValue $payload 'priority'
            project_id = Get-OfflineTaskValue $payload 'project_id'
            section_id = Get-OfflineTaskValue $payload 'section_id'
            checked = $false
            is_completed = $false
            offline_state = [string]$operation.State
        }
    }
    $visible = @($Context.Store.Snapshot | Where-Object { !$closed.ContainsKey([string](Get-OfflineTaskValue $_ 'id')) })
    return @($visible) + @($created)
}
