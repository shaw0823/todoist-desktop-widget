# Non-modal reminder window. Dot-source Reminders.ps1 and Theme.ps1 before using it.
function New-ReminderPopupController {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [AllowNull()][object]$Theme = $null
    )
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$popupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Todoist 提醒" Width="390" SizeToContent="Height" MaxHeight="520" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" ShowInTaskbar="True" Background="Transparent" Topmost="True" WindowStartupLocation="Manual" FontFamily="Microsoft YaHei UI">
 <Window.Resources>
  <SolidColorBrush x:Key="ReminderBackground" Color="#263F43"/>
  <SolidColorBrush x:Key="ReminderForeground" Color="#E2ECEC"/>
  <SolidColorBrush x:Key="ReminderAccent" Color="#70D7C3"/>
  <SolidColorBrush x:Key="ReminderSurface" Color="#365055"/>
  <SolidColorBrush x:Key="ReminderBorder" Color="#557176"/>
  <SolidColorBrush x:Key="ReminderMuted" Color="#9BB7BB"/>
  <Style TargetType="Button">
   <Setter Property="Background" Value="{DynamicResource ReminderSurface}"/>
   <Setter Property="Foreground" Value="{DynamicResource ReminderForeground}"/>
   <Setter Property="BorderBrush" Value="{DynamicResource ReminderBorder}"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Padding" Value="9,5"/>
   <Setter Property="Margin" Value="3,0,0,0"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ButtonChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.8"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Border Background="{DynamicResource ReminderBackground}" BorderBrush="{DynamicResource ReminderBorder}" BorderThickness="1" CornerRadius="10" Padding="14" Margin="5">
  <Border.Effect><DropShadowEffect xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" BlurRadius="15" ShadowDepth="3" Opacity="0.4"/></Border.Effect>
  <DockPanel LastChildFill="True">
   <DockPanel DockPanel.Dock="Top" x:Name="ReminderHeader" Background="#01000000" Cursor="SizeAll" Margin="0,0,0,8">
    <Button x:Name="ReminderClose" Content="×" ToolTip="关闭本次提醒" DockPanel.Dock="Right" Width="28" Height="27" FontSize="17" Padding="0"/>
    <StackPanel>
     <TextBlock Text="◉  Todoist 提醒" FontSize="17" FontWeight="SemiBold" Foreground="{DynamicResource ReminderForeground}"/>
     <TextBlock Text="待办到时间了" FontSize="12" Foreground="{DynamicResource ReminderMuted}" Margin="0,3,0,0"/>
    </StackPanel>
   </DockPanel>
   <TextBlock DockPanel.Dock="Bottom" x:Name="ReminderStatus" Text="可以逐条稍后提醒或关闭。" FontSize="11" Foreground="{DynamicResource ReminderMuted}" TextWrapping="Wrap" Margin="0,9,0,0"/>
   <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="360">
    <StackPanel x:Name="ReminderRows"/>
   </ScrollViewer>
  </DockPanel>
 </Border>
</Window>
'@
    $popup = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($popupXaml))
    $rows = $popup.FindName('ReminderRows')
    $controller = [pscustomobject]@{
        Window = $popup
        Rows = $rows
        Status = $popup.FindName('ReminderStatus')
        Keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        State = $State
        StatePath = [IO.Path]::GetFullPath($StatePath)
    }
    $popup.Tag = $controller
    $popup.FindName('ReminderClose').Add_Click({ $this.Tag.Window.Close() }.GetNewClosure())
    $popup.FindName('ReminderClose').Tag = $controller
    $popup.FindName('ReminderHeader').Add_MouseLeftButtonDown({
        if ($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
            try { $this.Tag.Window.DragMove() } catch { }
        }
    }.GetNewClosure())
    $popup.FindName('ReminderHeader').Tag = $controller
    $popup.Add_Loaded({ Move-ReminderPopupToWorkArea $this })
    $popup.Add_SizeChanged({ Move-ReminderPopupToWorkArea $this })

    if ($null -ne $Theme) {
        $palette = Get-ThemePalette $Theme
        foreach ($name in @('Background','Foreground','Accent','Surface','Border','Muted')) {
            $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($palette[$name])
            $brush.Freeze()
            $popup.Resources['Reminder' + $name] = $brush
        }
    }
    return $controller
}

function Move-ReminderPopupToWorkArea {
    param([Parameter(Mandatory = $true)][Windows.Window]$Window)
    $area = [Windows.SystemParameters]::WorkArea
    $width = $(if ($Window.ActualWidth -gt 0) { $Window.ActualWidth } else { $Window.Width })
    $height = $(if ($Window.ActualHeight -gt 0) { $Window.ActualHeight } else { $Window.MaxHeight })
    $Window.Left = [Math]::Max($area.Left + 8, $area.Right - $width - 18)
    $Window.Top = [Math]::Max($area.Top + 8, $area.Bottom - $height - 18)
}

function Get-ReminderPopupTimeLabel {
    param([Parameter(Mandatory = $true)][object]$Occurrence)
    if ([string]$Occurrence.DueDate -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
        return '全天待办 · 09:00 提醒'
    }
    $localTime = ([DateTimeOffset]$Occurrence.At).ToLocalTime()
    if ($localTime.Date -eq [DateTime]::Today) { return '今天 ' + $localTime.ToString('HH:mm') }
    return $localTime.ToString('M月d日 HH:mm')
}

function New-ReminderPopupRow {
    param([Parameter(Mandatory = $true)][object]$Controller,
          [Parameter(Mandatory = $true)][object]$Occurrence)
    $border = [Windows.Controls.Border]::new()
    $border.CornerRadius = [Windows.CornerRadius]::new(7)
    $border.Padding = [Windows.Thickness]::new(10)
    $border.Margin = [Windows.Thickness]::new(0,0,0,7)
    $border.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'ReminderSurface')
    $panel = [Windows.Controls.StackPanel]::new()

    $title = [Windows.Controls.TextBlock]::new()
    $title.Text = $(if ([string]::IsNullOrWhiteSpace([string]$Occurrence.Title)) { '未命名待办' } else { [string]$Occurrence.Title })
    $title.FontSize = 14
    $title.FontWeight = [Windows.FontWeights]::SemiBold
    $title.TextWrapping = [Windows.TextWrapping]::Wrap
    $title.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'ReminderForeground')
    [void]$panel.Children.Add($title)

    $time = [Windows.Controls.TextBlock]::new()
    $time.Text = Get-ReminderPopupTimeLabel $Occurrence
    $time.FontSize = 11
    $time.Margin = [Windows.Thickness]::new(0,4,0,9)
    $time.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'ReminderMuted')
    [void]$panel.Children.Add($time)

    $actions = [Windows.Controls.StackPanel]::new()
    $actions.Orientation = [Windows.Controls.Orientation]::Horizontal
    $actions.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    $snooze = [Windows.Controls.Button]::new()
    $snooze.Content = '稍后 10 分钟'
    $snooze.Tag = @{ Controller = $Controller; Occurrence = $Occurrence; Row = $border }
    $snooze.Add_Click({ Set-ReminderPopupChoice -Button $this -Status Snoozed })
    [void]$actions.Children.Add($snooze)
    $dismiss = [Windows.Controls.Button]::new()
    $dismiss.Content = '知道了'
    $dismiss.Tag = @{ Controller = $Controller; Occurrence = $Occurrence; Row = $border }
    $dismiss.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'ReminderAccent')
    $dismiss.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'ReminderBackground')
    $dismiss.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, 'ReminderAccent')
    $dismiss.Add_Click({ Set-ReminderPopupChoice -Button $this -Status Dismissed })
    [void]$actions.Children.Add($dismiss)
    [void]$panel.Children.Add($actions)
    $border.Child = $panel
    return $border
}

function Set-ReminderPopupChoice {
    param([Parameter(Mandatory = $true)][Windows.Controls.Button]$Button,
          [ValidateSet('Snoozed','Dismissed')][string]$Status)
    $context = $Button.Tag
    $controller = $context.Controller
    $occurrence = $context.Occurrence
    $key = [string]$occurrence.Key
    $previous = $controller.State.Entries[$key]
    try {
        if ($Status -eq 'Snoozed') {
            Snooze-ReminderOccurrence -State $controller.State -Occurrence $occurrence -Minutes 10
        } else {
            Dismiss-ReminderOccurrence -State $controller.State -Occurrence $occurrence
        }
        Save-ReminderState -State $controller.State -Path $controller.StatePath
    } catch {
        if ($null -eq $previous) { [void]$controller.State.Entries.Remove($key) }
        else { $controller.State.Entries[$key] = $previous }
        $controller.Status.Text = '提醒状态保存失败，请重试。'
        return
    }
    [void]$controller.Keys.Remove($key)
    [void]$controller.Rows.Children.Remove($context.Row)
    if ($controller.Rows.Children.Count -eq 0) { $controller.Window.Close() }
}

function Add-ReminderPopupOccurrences {
    param([Parameter(Mandatory = $true)][object]$Controller,
          [AllowNull()][object[]]$Occurrences)
    if ($null -eq $Occurrences -or $Occurrences.Count -eq 0) { return }
    $newRows = [Collections.Generic.List[object]]::new()
    $oldEntries = @{}
    foreach ($occurrence in $Occurrences) {
        if ($null -eq $occurrence) { continue }
        $key = [string]$occurrence.Key
        if ([string]::IsNullOrWhiteSpace($key) -or $Controller.Keys.Contains($key) -or $oldEntries.ContainsKey($key)) { continue }
        $oldEntries[$key] = $Controller.State.Entries[$key]
        $row = New-ReminderPopupRow -Controller $Controller -Occurrence $occurrence
        $newRows.Add([pscustomobject]@{ Key = $key; Row = $row; Occurrence = $occurrence })
    }
    if ($newRows.Count -eq 0) { return }
    try {
        foreach ($item in $newRows) { Mark-ReminderShown -State $Controller.State -Occurrence $item.Occurrence }
        Save-ReminderState -State $Controller.State -Path $Controller.StatePath
    } catch {
        foreach ($key in $oldEntries.Keys) {
            if ($null -eq $oldEntries[$key]) { [void]$Controller.State.Entries.Remove($key) }
            else { $Controller.State.Entries[$key] = $oldEntries[$key] }
        }
        throw
    }
    foreach ($item in $newRows) {
        [void]$Controller.Keys.Add($item.Key)
        [void]$Controller.Rows.Children.Add($item.Row)
    }
}

function Show-ReminderPopup {
    param([AllowNull()][object[]]$Occurrences,
          [Parameter(Mandatory = $true)][Collections.IDictionary]$State,
          [Parameter(Mandatory = $true)][string]$StatePath,
          [AllowNull()][object]$Theme = $null,
          [AllowNull()][object]$ExistingPopup = $null)
    if ($null -eq $Occurrences -or $Occurrences.Count -eq 0) { return $ExistingPopup }
    $controller = $ExistingPopup
    $normalizedPath = [IO.Path]::GetFullPath($StatePath)
    if ($null -ne $controller -and ($controller.Window.IsVisible -eq $false -or
            $controller.StatePath -ne $normalizedPath -or
            ![object]::ReferenceEquals($controller.State, $State))) {
        if ($controller.Window.IsVisible) { $controller.Window.Close() }
        $controller = $null
    }
    if ($null -eq $controller) { $controller = New-ReminderPopupController -State $State -StatePath $StatePath -Theme $Theme }
    Add-ReminderPopupOccurrences -Controller $controller -Occurrences $Occurrences
    if (!$controller.Window.IsVisible -and $controller.Rows.Children.Count -gt 0) { $controller.Window.Show() }
    if ($controller.Window.IsVisible) { [void]$controller.Window.Activate() }
    return $controller
}

function Close-ReminderPopup {
    param([AllowNull()][object]$Controller)
    if ($null -ne $Controller -and $Controller.Window.IsVisible) { $Controller.Window.Close() }
}
