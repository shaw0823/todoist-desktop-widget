# Completed tasks are shown in their own non-modal window. The caller owns the
# asynchronous Todoist request and passes its result to Update-CompletedHistory.
$script:historyWindow = $null
$script:historyUi = $null
$script:historyDate = [DateTime]::Today
$script:historyRequestId = 0

function Get-CompletedHistoryLocalTime {
    param([AllowNull()][object]$Task, [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local)
    $value = Get-HistoryProperty $Task 'completed_at'
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return '' }
    $instant = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (![DateTimeOffset]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$instant)) { return '' }
    return [TimeZoneInfo]::ConvertTime($instant, $TimeZone).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function Initialize-CompletedHistoryWindow {
    if ($null -ne $script:historyWindow) { return }
    [xml]$historyXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="已完成历史" Width="410" Height="520" MinWidth="350" MinHeight="300" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" ShowInTaskbar="True" Background="Transparent" Foreground="{DynamicResource HistoryForeground}">
 <Window.Resources>
  <SolidColorBrush x:Key="HistoryBackground" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Color="#263F43"/>
  <SolidColorBrush x:Key="HistoryForeground" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Color="#E2ECEC"/>
  <SolidColorBrush x:Key="HistorySurface" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Color="#365055"/>
  <SolidColorBrush x:Key="HistoryMuted" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Color="#9BB7BB"/>
  <SolidColorBrush x:Key="HistoryAccent" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Color="#70D7C3"/>
  <SolidColorBrush x:Key="HistoryBorder" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Color="#557176"/>
  <Style TargetType="Button">
   <Setter Property="Background" Value="{DynamicResource HistorySurface}"/>
   <Setter Property="Foreground" Value="{DynamicResource HistoryForeground}"/>
   <Setter Property="BorderBrush" Value="{DynamicResource HistoryBorder}"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Padding" Value="8,4"/>
   <Setter Property="MinHeight" Value="28"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
     <ContentPresenter Content="{TemplateBinding Content}" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource HistoryAccent}"/></Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.45"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Border Background="{DynamicResource HistoryBackground}" BorderBrush="{DynamicResource HistoryBorder}" BorderThickness="1" CornerRadius="10">
  <DockPanel Margin="12">
   <Grid x:Name="HistoryHeader" DockPanel.Dock="Top" Height="34" Background="#01000000" Cursor="SizeAll" Margin="0,0,0,10">
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock Text="✓ 已完成历史" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
    <Button x:Name="HistoryClose" Grid.Column="1" Content="×" Width="30" ToolTip="关闭历史"/>
   </Grid>
   <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Button x:Name="HistoryPrevious" Grid.Column="0" Content="‹" Width="31" ToolTip="前一天"/>
    <TextBlock x:Name="HistoryDateLabel" Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="15" FontWeight="SemiBold"/>
    <Button x:Name="HistoryNext" Grid.Column="2" Content="›" Width="31" ToolTip="后一天"/>
    <Button x:Name="HistoryToday" Grid.Column="3" Content="今天" Margin="8,0,0,0"/>
   </Grid>
   <TextBlock x:Name="HistoryStatus" DockPanel.Dock="Bottom" Foreground="{DynamicResource HistoryMuted}" FontSize="11" TextWrapping="Wrap" Margin="2,8,2,0"/>
   <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel x:Name="HistoryItems"/>
   </ScrollViewer>
  </DockPanel>
 </Border>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($historyXaml)
    $script:historyWindow = [Windows.Markup.XamlReader]::Load($reader)
    $script:historyUi = @{}
    foreach ($name in 'HistoryHeader','HistoryClose','HistoryPrevious','HistoryNext','HistoryToday','HistoryDateLabel','HistoryStatus','HistoryItems') {
        $script:historyUi[$name] = $script:historyWindow.FindName($name)
    }
    $script:historyUi.HistoryHeader.Add_MouseLeftButtonDown({
        if ($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) { $script:historyWindow.DragMove() }
    })
    $script:historyUi.HistoryClose.Add_Click({ $script:historyWindow.Close() })
    $script:historyUi.HistoryPrevious.Add_Click({
        $script:historyDate = $script:historyDate.AddDays(-1)
        Load-CompletedHistory
    })
    $script:historyUi.HistoryNext.Add_Click({
        if ($script:historyDate.Date -lt [DateTime]::Today) {
            $script:historyDate = $script:historyDate.AddDays(1)
            Load-CompletedHistory
        }
    })
    $script:historyUi.HistoryToday.Add_Click({
        $script:historyDate = [DateTime]::Today
        Load-CompletedHistory
    })
    $script:historyWindow.Add_Closed({
        $script:historyRequestId++
        $script:historyWindow = $null
        $script:historyUi = $null
    })
}

function Set-CompletedHistoryTheme {
    param([AllowNull()][object]$Theme)
    if ($null -eq $script:historyWindow -or $null -eq $Theme) { return }
    $normalized = Get-NormalizedTheme $Theme
    $palette = Get-ThemePalette $normalized
    $colors = @{
        HistoryBackground = $normalized.Background
        HistoryForeground = $normalized.Foreground
        HistoryAccent = $normalized.Accent
        HistorySurface = $palette.Surface
        HistoryBorder = $palette.Border
        HistoryMuted = $palette.Muted
    }
    foreach ($entry in $colors.GetEnumerator()) {
        $script:historyWindow.Resources[$entry.Key] = [Windows.Media.BrushConverter]::new().ConvertFromString($entry.Value)
    }
}

function Set-CompletedHistoryStatus {
    param([string]$Message)
    if ($null -eq $script:historyUi) { return }
    $script:historyUi.HistoryItems.Children.Clear()
    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = $Message
    $label.FontSize = 13
    $label.TextWrapping = [Windows.TextWrapping]::Wrap
    $label.Margin = [Windows.Thickness]::new(10, 22, 10, 10)
    $label.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'HistoryMuted')
    $script:historyUi.HistoryItems.Children.Add($label) | Out-Null
    $script:historyUi.HistoryStatus.Text = $Message
}

function Render-CompletedHistory {
    param([AllowNull()][object[]]$Items, [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local)
    if ($null -eq $script:historyUi) { return }
    $selected = @(Select-CompletedHistoryForDate -Items $Items -Date $script:historyDate -TimeZone $TimeZone)
    $script:historyUi.HistoryItems.Children.Clear()
    if ($selected.Count -eq 0) {
        Set-CompletedHistoryStatus '这一天没有已完成的待办。'
        return
    }
    $ordered = @($selected | Sort-Object -Property @{ Expression = { [string](Get-HistoryProperty $_ 'completed_at') }; Descending = $true })
    foreach ($item in $ordered) {
        $row = [Windows.Controls.Border]::new()
        $row.CornerRadius = [Windows.CornerRadius]::new(6)
        $row.Padding = [Windows.Thickness]::new(10, 9, 10, 9)
        $row.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
        $row.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'HistorySurface')
        $panel = [Windows.Controls.DockPanel]::new()
        $mark = [Windows.Controls.TextBlock]::new()
        $mark.Text = '✓'
        $mark.FontWeight = [Windows.FontWeights]::Bold
        $mark.Margin = [Windows.Thickness]::new(0, 0, 9, 0)
        $mark.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'HistoryAccent')
        [Windows.Controls.DockPanel]::SetDock($mark, [Windows.Controls.Dock]::Left)
        $panel.Children.Add($mark) | Out-Null
        $time = [Windows.Controls.TextBlock]::new()
        $time.Text = Get-CompletedHistoryLocalTime -Task $item -TimeZone $TimeZone
        $time.FontSize = 11
        $time.Margin = [Windows.Thickness]::new(8, 2, 0, 0)
        $time.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'HistoryMuted')
        [Windows.Controls.DockPanel]::SetDock($time, [Windows.Controls.Dock]::Right)
        $panel.Children.Add($time) | Out-Null
        $title = [Windows.Controls.TextBlock]::new()
        $title.Text = [string](Get-HistoryProperty $item 'content')
        $title.TextWrapping = [Windows.TextWrapping]::Wrap
        $title.FontSize = 13
        $panel.Children.Add($title) | Out-Null
        $row.Child = $panel
        $script:historyUi.HistoryItems.Children.Add($row) | Out-Null
    }
    $script:historyUi.HistoryStatus.Text = '共 ' + $selected.Count + ' 条 · 显示本地完成时间'
}

function Load-CompletedHistory {
    if ($null -eq $script:historyUi) { return }
    $script:historyDate = $script:historyDate.Date
    $script:historyUi.HistoryDateLabel.Text = $script:historyDate.ToString('yyyy年M月d日', [Globalization.CultureInfo]::GetCultureInfo('zh-CN'))
    $script:historyUi.HistoryNext.IsEnabled = $script:historyDate.Date -lt [DateTime]::Today
    $script:historyUi.HistoryToday.IsEnabled = $script:historyDate.Date -ne [DateTime]::Today
    $script:historyRequestId++
    if ([string]::IsNullOrWhiteSpace([string]$script:token)) {
        Set-CompletedHistoryStatus '请先在「关联」中连接 Todoist。'
        return
    }
    Set-CompletedHistoryStatus '正在读取已完成待办…'
    try {
        $context = @{ RequestId = $script:historyRequestId; Date = $script:historyDate }
        Start-Request 'History' 'Get' (Get-CompletedHistoryRequestPath -Date $script:historyDate) $null $context
    } catch {
        Set-CompletedHistoryStatus ('读取失败：' + $_.Exception.Message)
    }
}

function Update-CompletedHistory {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [AllowNull()][object[]]$Items,
        [AllowNull()][object]$ErrorRecord
    )
    if ($null -eq $script:historyUi -or $null -eq $script:historyWindow) { return }
    if ([int]$Context.RequestId -ne $script:historyRequestId -or [DateTime]$Context.Date -ne $script:historyDate) { return }
    if ($null -ne $ErrorRecord) {
        Set-CompletedHistoryStatus ('读取失败，请检查网络或 API Token：' + $ErrorRecord.Exception.Message)
        return
    }
    Render-CompletedHistory -Items $Items
}

function Show-CompletedHistory {
    param([AllowNull()][object]$Theme)
    if ($null -ne $script:historyWindow) {
        Set-CompletedHistoryTheme -Theme $Theme
        if ($script:historyWindow.WindowState -eq [Windows.WindowState]::Minimized) { $script:historyWindow.WindowState = [Windows.WindowState]::Normal }
        $script:historyWindow.Activate() | Out-Null
        return
    }
    Initialize-CompletedHistoryWindow
    Set-CompletedHistoryTheme -Theme $Theme
    if ($null -ne $window -and $window -is [Windows.Window]) {
        $work = [Windows.SystemParameters]::WorkArea
        $left = $window.Left - $script:historyWindow.Width - 10
        if ($left -lt $work.Left) { $left = $window.Left + $window.Width + 10 }
        $script:historyWindow.Left = [Math]::Max($work.Left, [Math]::Min($left, $work.Right - $script:historyWindow.Width))
        $script:historyWindow.Top = [Math]::Max($work.Top, [Math]::Min($window.Top, $work.Bottom - $script:historyWindow.Height))
        $script:historyWindow.Topmost = $window.Topmost
    } else { $script:historyWindow.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen }
    $script:historyWindow.Show()
    Load-CompletedHistory
}
