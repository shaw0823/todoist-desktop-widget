# The widget keeps one durable account cache and queue for all its views.
# OfflineTasks.ps1, Reminders.ps1 and ReminderPopup.ps1 are loaded first.
function Set-TaskWorkflowStatus {
    param([string]$Message)
    if ($script:viewMode -ne 'Notices') { $ui.Status.Text = $Message }
}
function Initialize-TaskWorkflow {
    if ($null -ne $script:reminderPopup) { Close-ReminderPopup $script:reminderPopup; $script:reminderPopup = $null }
    $script:offlineContext = $null
    $script:offlineStoreError = ''
    $script:reminderState = $null
    $script:reminderStatePath = ''
    $script:cachedTasks = @()
    $script:syncBusy = $false
    $script:nextSyncAttempt = [DateTime]::MinValue
    $script:lastLoadFailed = $false
    $script:copyPending = @{}
    $script:copiedToday = @{}
    $script:pending = @{}
    if ([string]::IsNullOrWhiteSpace([string]$script:token)) { return }
    try { $script:offlineContext = Open-OfflineTaskStore -DataDir $dataDir -Token $script:token }
    catch {
        $script:offlineStoreError = '本机离线数据无法读取，请保留原文件并检查存储。'
        Set-TaskWorkflowStatus $script:offlineStoreError
    }
    $accountKey = Get-OfflineTaskAccountKey -Token $script:token
    $script:reminderStatePath = Join-Path $dataDir ('reminders-' + $accountKey + '.json')
    $script:reminderState = Read-ReminderState -Path $script:reminderStatePath
    if ($null -ne $script:offlineContext) { Update-TaskProjection }
}

function Update-TaskProjection {
    if ($null -eq $script:offlineContext) { $script:cachedTasks = @(); return }
    $script:cachedTasks = @(Get-OfflineProjectedTasks -Context $script:offlineContext)
    $script:copyPending = @{}
    $script:copiedToday = @{}
    foreach ($operation in @($script:offlineContext.Store.Queue)) {
        if ($operation.Kind -ne 'Copy') { continue }
        $key = [string]$operation.TargetDate + ':' + [string]$operation.SourceId
        if ($operation.State -in @('Pending','InFlight')) { $script:copyPending[$key] = $true }
        if ($operation.State -eq 'Acknowledged') { $script:copiedToday[$key] = $true }
    }
    foreach ($receipt in @($script:offlineContext.Store.CopyReceipts.Keys)) {
        $parts = [string]$receipt -split '\|', 2
        if ($parts.Count -eq 2) { $script:copiedToday[$parts[1] + ':' + $parts[0]] = $true }
    }
}

function Get-TaskSyncStatusSuffix {
    if ($null -eq $script:offlineContext) {
        if ($script:offlineStoreError) { return ' · ' + $script:offlineStoreError }
        return ''
    }
    $queued = @($script:offlineContext.Store.Queue | Where-Object { $_.State -in @('Pending','InFlight') }).Count
    $failed = @($script:offlineContext.Store.Queue | Where-Object { $_.State -eq 'Failed' }).Count
    $parts = @()
    if ($script:lastLoadFailed -and $script:offlineContext.Store.SnapshotAt) { $parts += '离线缓存' }
    if ($queued) { $parts += "$queued 项待同步" }
    if ($failed) { $parts += "$failed 项同步失败" }
    if ($parts.Count) { return ' · ' + ($parts -join ' · ') }
    return ''
}

function Get-LocalPendingHistory {
    param([Parameter(Mandatory = $true)][DateTime]$Date)
    if ($null -eq $script:offlineContext) { return }
    $taskById = @{}
    foreach ($task in @($script:offlineContext.Store.Snapshot)) { $taskById[[string](Get-OfflineTaskValue $task 'id')] = $task }
    foreach ($operation in @($script:offlineContext.Store.Queue)) {
        if ($operation.Kind -ne 'Close' -or $operation.State -notin @('Pending','InFlight')) { continue }
        $when = [DateTimeOffset]::MinValue
        if (![DateTimeOffset]::TryParse([string]$operation.CreatedAt, [ref]$when)) { continue }
        if ($when.ToLocalTime().Date -ne $Date.Date) { continue }
        $task = $taskById[[string]$operation.TaskId]
        if ($null -eq $task) { continue }
        [pscustomobject]@{
            id = 'local-' + [string]$operation.Id
            content = [string](Get-OfflineTaskValue $task 'content')
            completed_at = [string]$operation.CreatedAt
            is_deleted = $false
        }
    }
}

function Start-NextOfflineSync {
    if ($null -eq $script:offlineContext -or $script:syncBusy -or [DateTime]::Now -lt $script:nextSyncAttempt) { return }
    $operation = Get-OfflinePendingOperation -Context $script:offlineContext
    if ($null -eq $operation) { return }
    try {
        $operation = Set-OfflineTaskOperationInFlight -Context $script:offlineContext -Id $operation.Id
        $command = ConvertTo-OfflineSyncCommand -Operation $operation
        $script:syncBusy = $true
        Start-Request 'Sync' 'Post' 'sync' @($command) @{Id=$operation.Id; AccountKey=$script:offlineContext.AccountKey}
    } catch {
        $script:syncBusy = $false
        if ($null -ne $operation -and $null -ne $script:offlineContext) {
            try { Reset-OfflineTaskOperation -Context $script:offlineContext -Id $operation.Id -ErrorMessage $_.Exception.Message | Out-Null } catch { }
        }
        $script:nextSyncAttempt = [DateTime]::Now.AddSeconds(30)
        Set-TaskWorkflowStatus '操作已保存在本机，将稍后重试同步。'
    }
}

function Complete-TaskSyncJob {
    param($Job, $Failure, [object[]]$Output)
    if ($null -eq $script:offlineContext -or $Job.Context.AccountKey -ne $script:offlineContext.AccountKey) { return }
    $script:syncBusy = $false
    if ($null -ne $Failure -or $null -eq $Output -or $Output.Count -eq 0) {
        $message = $(if ($null -ne $Failure) { $Failure.Exception.Message } else { 'Todoist 没有返回同步结果。' })
        try { Reset-OfflineTaskOperation -Context $script:offlineContext -Id $Job.Context.Id -ErrorMessage $message | Out-Null }
        catch { Set-TaskWorkflowStatus ('离线操作保存失败：' + $_.Exception.Message); return }
        $script:nextSyncAttempt = [DateTime]::Now.AddSeconds(30)
        Set-TaskWorkflowStatus '网络不可用，操作已保存在本机；恢复连接后会自动同步。'
        return
    }
    try {
        $result = Complete-OfflineTaskOperation -Context $script:offlineContext -Id $Job.Context.Id -Response $Output[-1]
        Update-TaskProjection
        Render-Tasks
        if ($result.State -eq 'Acknowledged') {
            $script:revision++
            Load-Tasks
        } elseif ($result.State -eq 'Failed') {
            Set-TaskWorkflowStatus ('一项操作被 Todoist 拒绝：' + $result.Error)
        } else {
            $script:nextSyncAttempt = [DateTime]::Now.AddSeconds(30)
        }
        if ($result.State -ne 'Pending') { Start-NextOfflineSync }
    } catch {
        try { Reset-OfflineTaskOperation -Context $script:offlineContext -Id $Job.Context.Id -ErrorMessage $_.Exception.Message | Out-Null } catch { }
        $script:nextSyncAttempt = [DateTime]::Now.AddSeconds(30)
        Set-TaskWorkflowStatus ('同步结果保存失败，请检查本机存储：' + $_.Exception.Message)
    }
}

function Check-TaskReminders {
    if ($null -eq $script:reminderState) { return }
    try {
        $pendingClose = @{}
        if ($null -ne $script:offlineContext) {
            foreach ($operation in @($script:offlineContext.Store.Queue)) {
                if ($operation.Kind -eq 'Close' -and $operation.State -ne 'Failed') { $pendingClose[[string]$operation.TaskId] = $true }
            }
        }
        $due = @(Get-DueReminders -Tasks $script:cachedTasks -State $script:reminderState -PendingIds $pendingClose -Now ([DateTimeOffset]::Now))
        if ($due.Count) {
            $script:reminderPopup = Show-ReminderPopup -Occurrences $due -State $script:reminderState -StatePath $script:reminderStatePath -Theme $script:theme -ExistingPopup $script:reminderPopup
        }
    } catch {
        Set-TaskWorkflowStatus ('提醒暂时无法显示：' + $_.Exception.Message)
    }
}
