$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $PSScriptRoot 'Theme.ps1')
. (Join-Path $PSScriptRoot 'Reminders.ps1')
. (Join-Path $PSScriptRoot 'ReminderPopup.ps1')

function Assert-Popup($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$fixture = Join-Path $root ('.reminder-popup-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    $statePath = Join-Path $fixture 'reminders.json'
    $state = Get-NormalizedReminderState $null
    $day = [DateTime]::Today.ToString('yyyy-MM-dd')
    $occurrences = @(
        Get-ReminderOccurrence @{ id = '1'; content = '晨间计划'; due = @{ date = $day } }
        Get-ReminderOccurrence @{ id = '2'; content = '提交报告'; due = @{ date = $day + 'T11:30:00' } }
    )
    $popup = New-ReminderPopupController -State $state -StatePath $statePath -Theme (Get-DefaultTheme)
    Assert-Popup ($popup.Window.Owner -eq $null) 'A hidden main widget would hide an owned reminder window.'
    Assert-Popup ($popup.Window.Topmost -and $popup.Window.ShowInTaskbar) 'Reminder must remain discoverable while the widget is in the tray.'
    Assert-Popup (!$popup.Window.IsVisible) 'New popup should not show before a due reminder is supplied.'
    Add-ReminderPopupOccurrences -Controller $popup -Occurrences @($occurrences + $occurrences[0])
    Assert-Popup ($popup.Rows.Children.Count -eq 2) 'Duplicate occurrences produced duplicate rows.'
    Assert-Popup ($popup.Keys.Count -eq 2) 'Popup occurrence keys were not tracked.'
    Assert-Popup ((Read-ReminderState -Path $statePath).Entries.Count -eq 2) 'Shown reminders were not persisted.'
    Assert-Popup ($popup.Rows.Children[0].Child.Children[1].Text -eq '全天待办 · 09:00 提醒') 'All-day reminder label is wrong.'

    $snoozeButton = $popup.Rows.Children[0].Child.Children[2].Children[0]
    $snoozeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-Popup ($popup.Rows.Children.Count -eq 1) 'Snoozed reminder row remained visible.'
    Assert-Popup ((Read-ReminderState -Path $statePath).Entries[$occurrences[0].Key].Status -eq 'Snoozed') 'Snooze was not persisted.'

    $dismissButton = $popup.Rows.Children[0].Child.Children[2].Children[1]
    $dismissButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-Popup ($popup.Rows.Children.Count -eq 0) 'Dismissed reminder row remained visible.'
    Assert-Popup ((Read-ReminderState -Path $statePath).Entries[$occurrences[1].Key].Status -eq 'Dismissed') 'Dismissal was not persisted.'
    'PASS: independent topmost popup, themed rows, deduplication, snooze and dismiss persistence.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith($root + '\.reminder-popup-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe reminder popup test cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
