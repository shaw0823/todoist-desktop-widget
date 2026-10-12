$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $PSScriptRoot 'Theme.ps1')
. (Join-Path $PSScriptRoot 'History.ps1')
. (Join-Path $PSScriptRoot 'HistoryUI.ps1')

function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Click($Button) { $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
function Start-Request($Kind, $Method, $Path, $Body, $Context) {
    $script:historyRequests.Add(@{ Kind = $Kind; Method = $Method; Path = $Path; Context = $Context })
}
function New-CompletedTask([string]$Title, [DateTime]$LocalTime) {
    $local = [DateTime]::SpecifyKind($LocalTime, [DateTimeKind]::Local)
    [pscustomobject]@{ id = [Guid]::NewGuid().ToString('N'); content = $Title; completed_at = $local.ToUniversalTime().ToString('o'); is_deleted = $false }
}

$script:historyRequests = [Collections.Generic.List[object]]::new()
$script:token = 'fixture-only'
$window = $null
try {
    Show-CompletedHistory -Theme (Get-DefaultTheme)
    Assert ($null -ne $script:historyWindow -and $script:historyWindow.IsVisible) 'History window did not open.'
    Assert ($script:historyRequests.Count -eq 1) 'Opening history should request current completion date.'
    Assert ($script:historyRequests[0].Kind -ceq 'History') 'History request uses wrong worker kind.'
    Assert ($script:historyRequests[0].Path.StartsWith('tasks/completed/by_completion_date?')) 'History did not request completion-date endpoint.'
    Assert ($script:historyUi.HistoryNext.IsEnabled -eq $false) 'Next day should be disabled when today is selected.'
    Assert ($script:historyUi.HistoryToday.IsEnabled -eq $false) 'Today shortcut should be disabled when today is selected.'

    $todayRequest = $script:historyRequests[0]
    $todayTask = New-CompletedTask 'Today completed task' ([DateTime]::Today.AddHours(12))
    $oldTask = New-CompletedTask 'Old completed task' ([DateTime]::Today.AddDays(-1).AddHours(11))
    Update-CompletedHistory -Context $todayRequest.Context -Items @($todayTask, $oldTask)
    Assert ($script:historyUi.HistoryItems.Children.Count -eq 1) 'History included another completion date.'
    Assert ($script:historyUi.HistoryStatus.Text.Contains('共 1 条')) 'History count not updated.'
    $row = $script:historyUi.HistoryItems.Children[0]
    Assert ($row.Child.Children[2].Text -ceq 'Today completed task') 'Completed task title not shown.'
    Assert ($row.Child.Children[1].Text -ceq '12:00') 'Completion time was not converted to local time.'

    Click $script:historyUi.HistoryPrevious
    Assert ($script:historyRequests.Count -eq 2) 'Previous date did not request history.'
    Assert ($script:historyUi.HistoryNext.IsEnabled) 'Next date should become available after going back.'
    Update-CompletedHistory -Context $todayRequest.Context -Items @($todayTask)
    Assert ($script:historyUi.HistoryStatus.Text.Contains('正在读取')) 'Stale history response replaced the current loading state.'
    Update-CompletedHistory -Context $script:historyRequests[1].Context -Items @($todayTask, $oldTask)
    Assert ($script:historyUi.HistoryItems.Children.Count -eq 1) 'Previous date should show only its own task.'
    Assert ($script:historyUi.HistoryItems.Children[0].Child.Children[2].Text -ceq 'Old completed task') 'Previous date task title was wrong.'

    Click $script:historyUi.HistoryToday
    Assert ($script:historyRequests.Count -eq 3) 'Today shortcut did not request history.'
    $failure = $null
    try { throw 'Fixture service offline' } catch { $failure = $_ }
    Update-CompletedHistory -Context $script:historyRequests[2].Context -ErrorRecord $failure
    Assert ($script:historyUi.HistoryStatus.Text.Contains('读取失败')) 'History network error was not shown.'
    Update-CompletedHistory -Context $script:historyRequests[2].Context -Items @()
    Assert ($script:historyUi.HistoryStatus.Text.Contains('没有已完成')) 'Empty history message was not shown.'

    $shownWindow = $script:historyWindow
    Show-CompletedHistory -Theme (Get-DefaultTheme)
    Assert ([object]::ReferenceEquals($script:historyWindow, $shownWindow)) 'Repeated menu click should reuse the history window.'
    Assert ($script:historyRequests.Count -eq 3) 'Reopening visible history caused an unnecessary request.'
    Click $script:historyUi.HistoryClose
    Assert ($null -eq $script:historyWindow) 'Closing history did not clear its state.'
    $script:token = ''
    Show-CompletedHistory -Theme (Get-DefaultTheme)
    Assert ($script:historyRequests.Count -eq 3) 'History requested Todoist without a token.'
    Assert ($script:historyUi.HistoryStatus.Text.Contains('关联')) 'Disconnected state was not explained.'
    Write-Output 'PASS: completed history window, dates, local completion times, loading, stale results, errors and empty state.'
} finally {
    if ($null -ne $script:historyWindow) { $script:historyWindow.Close() }
}
