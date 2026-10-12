$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OfflineTasks.ps1')

function Assert([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

$fixture = Join-Path $PSScriptRoot ('.offline-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    $token = 'isolated-fake-token-' + [guid]::NewGuid().ToString('N')
    $context = Open-OfflineTaskStore -DataDir $fixture -Token $token
    Assert ($context.Store.Queue.Count -eq 0 -and $context.Store.Snapshot.Count -eq 0) 'A new store was not empty.'
    Assert (!$context.Path.Contains($token)) 'The token leaked into the file name.'

    $source = [pscustomobject]@{ id = 'server-old'; content = '旧任务'; due = [pscustomobject]@{ date = '2026-10-10' } }
    Set-OfflineTaskSnapshot -Context $context -Tasks @($source)
    $add = Add-OfflineTaskOperation -Context $context -Kind Add -Payload @{ content = '离线新任务'; due_date = '2026-10-12' }
    $copy = Add-OfflineTaskOperation -Context $context -Kind Copy -Payload @{ content = '离线复制'; description = '保留说明'; due_datetime = '2026-10-12T06:05:00Z'; project_id = 'project-1'; labels = @('研究') } -SourceId 'source-1' -TargetDate '2026-10-12'
    $close = Add-OfflineTaskOperation -Context $context -Kind Close -TaskId 'server-old'
    Assert ($context.Store.Queue.Count -eq 3) 'Operations were not queued.'
    Assert ($add.Id -ne $copy.Id -and $add.TempId -ne $copy.TempId) 'Create command IDs were not unique.'
    Assert ((Get-OfflinePendingOperation -Context $context).Id -eq $add.Id) 'Operations were not ordered.'
    $projected = @(Get-OfflineProjectedTasks -Context $context)
    Assert ($projected.Count -eq 2 -and !(@($projected | Where-Object { $_.id -eq 'server-old' }).Count)) 'Pending operations were not projected over the snapshot.'
    Assert (@($projected | Where-Object { $_.offline_state -eq 'Pending' }).Count -eq 2) 'Projected tasks lack pending state.'
    Assert (@($projected | Where-Object { $_.content -eq '离线复制' -and $_.due.date -eq '2026-10-12' }).Count -eq 1) 'A UTC copy was not projected on the selected local date.'

    $addCommand = ConvertTo-OfflineSyncCommand -Operation $add
    Assert ($addCommand.type -eq 'item_add' -and $addCommand.uuid -eq $add.Id -and $addCommand.temp_id -eq $add.TempId) 'Add command lost persistent identifiers.'
    Assert ($addCommand.args.due.date -eq '2026-10-12' -and !$addCommand.args.ContainsKey('due_date')) 'REST date was not translated to Sync due object.'
    $copyCommand = ConvertTo-OfflineSyncCommand -Operation $copy
    Assert ($copyCommand.args.due.date -eq '2026-10-12T06:05:00Z') 'Copy command lost due time.'
    Assert ($copyCommand.args.project_id -eq 'project-1') 'Copy command lost project.'
    Assert ($copyCommand.args.labels[0] -eq '研究') 'Copy command lost labels.'
    $closeCommand = ConvertTo-OfflineSyncCommand -Operation $close
    Assert ($closeCommand.type -eq 'item_close' -and $closeCommand.args.id -eq 'server-old') 'Close command was malformed.'

    $duplicateRejected = $false
    try { Add-OfflineTaskOperation -Context $context -Kind Copy -Payload @{ content = '重复复制' } -SourceId 'source-1' -TargetDate '2026-10-12' | Out-Null }
    catch { $duplicateRejected = $true }
    Assert $duplicateRejected 'A duplicate copy was accepted while pending.'

    Set-OfflineTaskOperationInFlight -Context $context -Id $add.Id | Out-Null
    $reopened = Open-OfflineTaskStore -DataDir $fixture -Token $token
    $restoredAdd = Get-OfflineTaskOperation -Context $reopened -Id $add.Id
    Assert ($restoredAdd.Id -eq $add.Id -and $restoredAdd.TempId -eq $add.TempId -and $restoredAdd.State -eq 'Pending' -and $restoredAdd.Attempts -eq 1) 'Restart did not preserve and reset an in-flight operation.'
    Assert ((ConvertTo-OfflineSyncCommand -Operation $restoredAdd).uuid -eq $add.Id) 'Retry changed the idempotency UUID.'

    Set-OfflineTaskOperationInFlight -Context $reopened -Id $add.Id | Out-Null
    $unknown = Complete-OfflineTaskOperation -Context $reopened -Id $add.Id -Response @{ sync_status = @{} }
    Assert ($unknown.State -eq 'Pending') 'Missing server outcome must remain retryable.'
    $failed = Complete-OfflineTaskOperation -Context $reopened -Id $close.Id -Response @{ sync_status = @{ $($close.Id) = @{ error = 'invalid id' } } }
    Assert ($failed.State -eq 'Failed' -and $failed.Error -eq 'invalid id') 'Server rejection was not classified.'
    $ackAdd = Complete-OfflineTaskOperation -Context $reopened -Id $add.Id -Response @{ sync_status = @{ $($add.Id) = 'ok' }; temp_id_mapping = @{ $($add.TempId) = 'server-new' } }
    Assert ($ackAdd.State -eq 'Acknowledged' -and $ackAdd.ServerId -eq 'server-new') 'Successful add was not acknowledged or mapped to its server ID.'
    $ackCopy = Complete-OfflineTaskOperation -Context $reopened -Id $copy.Id -Response @{ sync_status = @{ $($copy.Id) = 'ok' }; temp_id_mapping = @{ $($copy.TempId) = 'server-copy' } }
    Assert ($ackCopy.State -eq 'Acknowledged' -and $ackCopy.ServerId -eq 'server-copy') 'Successful copy was not acknowledged.'
    Assert ($reopened.Store.CopyReceipts.ContainsKey('source-1|2026-10-12')) 'Copy receipt was not persisted.'
    $duplicateRejected = $false
    try { Add-OfflineTaskOperation -Context $reopened -Kind Copy -Payload @{ content = '重复复制' } -SourceId 'source-1' -TargetDate '2026-10-12' | Out-Null }
    catch { $duplicateRejected = $true }
    Assert $duplicateRejected 'A duplicate copy was accepted after acknowledgement.'
    $afterAck = Open-OfflineTaskStore -DataDir $fixture -Token $token
    Assert ($afterAck.Store.CopyReceipts.ContainsKey('source-1|2026-10-12')) 'Copy receipt was lost on restart.'
    Assert ((Get-OfflineTaskOperation -Context $afterAck -Id $add.Id).ServerId -eq 'server-new') 'Server ID mapping was lost on restart.'
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($source)
    Assert ($afterAck.Store.Queue.Count -eq 3) 'A stale server snapshot prematurely cleared acknowledged operations.'
    $before = @(Get-OfflineProjectedTasks -Context $afterAck)
    $again = @(Get-OfflineProjectedTasks -Context $afterAck)
    Assert ($before.Count -eq $again.Count -and ($before.id -join '|') -eq ($again.id -join '|')) 'Repeated projection changed the displayed task set.'
    $serverNew = [pscustomobject]@{ id = 'server-new'; content = '离线新任务'; due = [pscustomobject]@{ date = '2026-10-12' } }
    $serverCopy = [pscustomobject]@{ id = 'server-copy'; content = '离线复制'; due = [pscustomobject]@{ date = '2026-10-12' } }
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($source, $serverNew)
    Assert ($afterAck.Store.Queue.Count -eq 2 -and $null -eq (Get-OfflineTaskOperation -Context $afterAck -Id $add.Id)) 'Confirmed add was not cleared or unconfirmed copy was cleared.'
    $projectedWithOneServerTask = @(Get-OfflineProjectedTasks -Context $afterAck)
    Assert (@($projectedWithOneServerTask | Where-Object { $_.id -eq 'server-new' }).Count -eq 1) 'Server-backed task was projected twice.'
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($source, $serverNew, $serverCopy)
    Assert ($afterAck.Store.Queue.Count -eq 1 -and $afterAck.Store.Queue[0].State -eq 'Failed') 'Confirmed copy was not cleared.'

    $completed = Add-OfflineTaskOperation -Context $afterAck -Kind Close -TaskId 'server-new' -OriginalDue '2026-10-12' -OriginalCompletedCount 0
    $afterAck = Open-OfflineTaskStore -DataDir $fixture -Token $token
    $restoredClose = Get-OfflineTaskOperation -Context $afterAck -Id $completed.Id
    Assert ($restoredClose.OriginalDue -eq '2026-10-12' -and $restoredClose.OriginalCompletedCount -eq 0) 'Recurring close baseline was lost on restart.'
    Complete-OfflineTaskOperation -Context $afterAck -Id $completed.Id -Response @{ sync_status = @{ $($completed.Id) = 'ok' } } | Out-Null
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($serverNew, $serverCopy)
    Assert ($null -ne (Get-OfflineTaskOperation -Context $afterAck -Id $completed.Id)) 'Close acknowledgement was cleared while the task was still listed.'
    Assert (@(Get-OfflineProjectedTasks -Context $afterAck | Where-Object { $_.id -eq 'server-new' }).Count -eq 0) 'Acknowledged close reappeared before server snapshot reflected it.'
    $advanced = [pscustomobject]@{ id = 'server-new'; content = '离线新任务'; completed_count = 1; due = [pscustomobject]@{ date = '2026-10-13' } }
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($advanced, $serverCopy)
    Assert ($null -eq (Get-OfflineTaskOperation -Context $afterAck -Id $completed.Id)) 'Recurring close was not cleared after its due date advanced.'

    $completedByCount = Add-OfflineTaskOperation -Context $afterAck -Kind Close -TaskId 'server-new' -OriginalDue '2026-10-13' -OriginalCompletedCount 1
    Complete-OfflineTaskOperation -Context $afterAck -Id $completedByCount.Id -Response @{ sync_status = @{ $($completedByCount.Id) = 'ok' } } | Out-Null
    $advancedCount = [pscustomobject]@{ id = 'server-new'; content = '离线新任务'; completed_count = 2; due = [pscustomobject]@{ date = '2026-10-13' } }
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($advancedCount, $serverCopy)
    Assert ($null -eq (Get-OfflineTaskOperation -Context $afterAck -Id $completedByCount.Id)) 'Recurring close was not cleared after completed_count increased.'

    $completedGone = Add-OfflineTaskOperation -Context $afterAck -Kind Close -TaskId 'server-new' -OriginalDue '2026-10-13' -OriginalCompletedCount 2
    Complete-OfflineTaskOperation -Context $afterAck -Id $completedGone.Id -Response @{ sync_status = @{ $($completedGone.Id) = 'ok' } } | Out-Null
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($serverCopy)
    Assert ($null -eq (Get-OfflineTaskOperation -Context $afterAck -Id $completedGone.Id)) 'Close acknowledgement was not cleared after the task disappeared.'
    $unmapped = Add-OfflineTaskOperation -Context $afterAck -Kind Add -Payload @{ content = '无法确认映射'; due_date = '2026-10-12' }
    Complete-OfflineTaskOperation -Context $afterAck -Id $unmapped.Id -Response @{ sync_status = @{ $($unmapped.Id) = 'ok' } } | Out-Null
    Set-OfflineTaskSnapshot -Context $afterAck -Tasks @($serverCopy, [pscustomobject]@{ id = 'some-server-id'; content = '无法确认映射'; due = [pscustomobject]@{ date = '2026-10-12' } })
    Assert ($null -ne (Get-OfflineTaskOperation -Context $afterAck -Id $unmapped.Id)) 'Unmapped add was incorrectly matched by content.'

    $rejectedCopy = Add-OfflineTaskOperation -Context $afterAck -Kind Copy -Payload @{ content = '第一次被拒绝'; due_date = '2026-10-12' } -SourceId 'source-rejected' -TargetDate '2026-10-12'
    Complete-OfflineTaskOperation -Context $afterAck -Id $rejectedCopy.Id -Response @{ sync_status = @{ $($rejectedCopy.Id) = @{ error = 'rejected' } } } | Out-Null
    $retryCopy = Add-OfflineTaskOperation -Context $afterAck -Kind Copy -Payload @{ content = '再次复制'; due_date = '2026-10-12' } -SourceId 'source-rejected' -TargetDate '2026-10-12'
    Assert ($retryCopy.Id -ne $rejectedCopy.Id -and (Get-OfflineTaskOperation -Context $afterAck -Id $rejectedCopy.Id).State -eq 'Failed') 'A rejected copy blocked an explicit retry or was erased.'

    $secondToken = 'another-isolated-fake-token-' + [guid]::NewGuid().ToString('N')
    $second = Open-OfflineTaskStore -DataDir $fixture -Token $secondToken
    Assert ($second.Path -ne $afterAck.Path -and $second.Store.Queue.Count -eq 0) 'Different Todoist tokens shared a queue.'
    $raw = [IO.File]::ReadAllText($afterAck.Path, [Text.Encoding]::UTF8)
    Assert (!$raw.Contains($token) -and !$raw.Contains($secondToken)) 'A token was persisted in the task store.'
    Assert ([IO.File]::Exists($afterAck.Path + '.bak')) 'Atomic writer did not keep a backup.'

    # A damaged current file recovers from a valid backup without destroying it.
    [IO.File]::WriteAllText($afterAck.Path, '{broken', [Text.Encoding]::UTF8)
    $recovered = Open-OfflineTaskStore -DataDir $fixture -Token $token
    Assert (![string]::IsNullOrWhiteSpace($recovered.RecoveredCorruptPath)) 'Corruption recovery was not reported.'
    Assert ([IO.File]::Exists($recovered.RecoveredCorruptPath) -and ([IO.File]::ReadAllText($recovered.RecoveredCorruptPath)).Contains('{broken')) 'Corrupt source was not preserved.'
    Assert ($recovered.Store.AccountKey -eq $context.AccountKey) 'Backup recovery loaded a different account.'

    # Without a backup, fail visibly and preserve the corrupted file.
    $thirdToken = 'third-fake-token-' + [guid]::NewGuid().ToString('N')
    $fresh = Open-OfflineTaskStore -DataDir $fixture -Token $thirdToken
    [IO.File]::WriteAllText($fresh.Path, '{broken', [Text.Encoding]::UTF8)
    $failedRead = $false
    try { Open-OfflineTaskStore -DataDir $fixture -Token $thirdToken | Out-Null } catch { $failedRead = $true }
    Assert ($failedRead -and ([IO.File]::ReadAllText($fresh.Path)).Contains('{broken')) 'Corruption without backup was silently discarded.'
    Write-Output 'PASS: account-scoped snapshots, durable UUID queue, Sync conversion, recurring close confirmation, retry/recovery, projection, and copy deduplication.'
} finally {
    $root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($fixture)
    if (!$target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notlike '.offline-test-*') { throw 'Unsafe fixture cleanup path.' }
    if ([IO.Directory]::Exists($target)) { Remove-Item -LiteralPath $target -Recurse -Force }
}
