Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Security
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')
$widgetMutex = Enter-WidgetMutex $widgetMutexName
if ($null -eq $widgetMutex) { return }
try {
if (Test-WidgetOpen) { return }
$dataDir = Join-Path $env:LOCALAPPDATA 'TodoistDesktopWidget'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$tokenPath = Join-Path $dataDir 'token.dat'
. (Join-Path $PSScriptRoot 'Theme.ps1')
. (Join-Path $PSScriptRoot 'Background.ps1')
$themePath = Join-Path $dataDir 'theme.json'
$script:theme = Read-Theme $themePath
$backgroundPath = Join-Path $dataDir 'background.json'
$script:backgroundSettings = Read-BackgroundSettings $backgroundPath
$script:wallpaperCache = $null
$script:token = ''
$script:date = [DateTime]::Today
$script:busy = $false
$script:jobs = [Collections.Generic.List[object]]::new()
$script:pending = @{}
$script:cachedTasks = @()
$script:revision = 0
function Save-Token([string]$value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($value)
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($tokenPath,$encrypted)
    $script:token = $value
}
if (Test-Path $tokenPath) {
    try { $script:token = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($tokenPath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)) } catch {}
}
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Todoist 桌面小组件" Width="400" Height="460" MinWidth="340" MinHeight="240" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" ShowInTaskbar="False" Background="Transparent" Foreground="{DynamicResource WidgetForeground}" Topmost="True">
 <Window.Resources>
  <SolidColorBrush x:Key="WidgetBackground" Color="#263F43"/>
  <SolidColorBrush x:Key="WidgetForeground" Color="#E2ECEC"/>
  <SolidColorBrush x:Key="WidgetAccent" Color="#70D7C3"/>
  <SolidColorBrush x:Key="WidgetSurface" Color="#365055"/>
  <SolidColorBrush x:Key="WidgetBorder" Color="#557176"/>
  <SolidColorBrush x:Key="WidgetControlBorder" Color="#557176"/>
  <SolidColorBrush x:Key="WidgetDivider" Color="#3B575B"/>
  <SolidColorBrush x:Key="WidgetMuted" Color="#9BB7BB"/>
  <Style TargetType="Button">
   <Setter Property="Background" Value="{DynamicResource WidgetSurface}"/>
   <Setter Property="Foreground" Value="{DynamicResource WidgetForeground}"/>
   <Setter Property="BorderBrush" Value="{DynamicResource WidgetControlBorder}"/>
   <Setter Property="BorderThickness" Value="1.2"/>
   <Setter Property="Padding" Value="6,3"/>
   <Setter Property="Margin" Value="2"/>
   <Setter Property="MinHeight" Value="24"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="HorizontalContentAlignment" Value="Center"/>
   <Setter Property="VerticalContentAlignment" Value="Center"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ButtonChrome" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
     <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="True"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonChrome" Property="BorderBrush" Value="{DynamicResource WidgetAccent}"/></Trigger>
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonChrome" Property="BorderBrush" Value="{DynamicResource WidgetAccent}"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.8"/></Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.5"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="CheckBox">
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
    <Border x:Name="Box" Width="18" Height="18" CornerRadius="3" BorderThickness="1.5" BorderBrush="{DynamicResource WidgetControlBorder}" Background="{DynamicResource WidgetSurface}">
     <Path x:Name="Mark" Data="M 3,8 L 6,11 L 12,4" Stroke="{DynamicResource WidgetBackground}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource WidgetAccent}"/></Trigger>
     <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="{DynamicResource WidgetAccent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource WidgetAccent}"/><Setter TargetName="Mark" Property="Visibility" Value="Visible"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Grid>
 <Border x:Name="WidgetFrame" Background="Transparent" BorderBrush="{DynamicResource WidgetBorder}" BorderThickness="1" CornerRadius="10">
  <Grid>
   <Grid x:Name="BackgroundLayer" IsHitTestVisible="False">
    <Border x:Name="BackgroundFill" Background="{DynamicResource WidgetBackground}" CornerRadius="9"/>
    <Border x:Name="WallpaperOverlay" Background="{DynamicResource WidgetBackground}" CornerRadius="9" Visibility="Collapsed"/>
   </Grid>
  <DockPanel Margin="10">
   <StackPanel DockPanel.Dock="Top">
    <Grid x:Name="Header" Background="#01000000" MinHeight="30" Cursor="SizeAll" ToolTip="拖动标题或顶部空白处移动组件" Margin="0,0,0,8">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <TextBlock Text="☀ Todoist" FontWeight="Bold" VerticalAlignment="Center"/>
     <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="Appearance" Content="◐" ToolTip="颜色、壁纸和透明度"/><Button x:Name="Settings" Content="⚙" ToolTip="连接 Todoist"/><Button x:Name="Pin" Content="📌" ToolTip="切换置顶" Background="{DynamicResource WidgetAccent}" Foreground="{DynamicResource WidgetBackground}"/><Button x:Name="Refresh" Content="↻" ToolTip="刷新"/><Button x:Name="Close" Content="×" ToolTip="关闭"/></StackPanel>
    </Grid>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,8"><Button x:Name="Previous" Content="‹"/><Button x:Name="Day" Content="今天"/><Button x:Name="Next" Content="›"/></StackPanel>
    <TextBox x:Name="Input" Background="{DynamicResource WidgetSurface}" Foreground="{DynamicResource WidgetForeground}" CaretBrush="{DynamicResource WidgetForeground}" BorderBrush="{DynamicResource WidgetControlBorder}" BorderThickness="1.5" Padding="9" Margin="0,0,0,8" ToolTip="输入任务内容，回车添加到当前日期"/>
   </StackPanel>
   <TextBlock x:Name="Status" DockPanel.Dock="Bottom" Foreground="{DynamicResource WidgetMuted}" TextWrapping="Wrap" Margin="0,8,0,0" FontSize="11"/>
   <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Tasks"/></ScrollViewer>
  </DockPanel>
  </Grid>
 </Border>
 <Thumb x:Name="ResizeHandle" Width="15" Height="15" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,3,3" Cursor="SizeNWSE" ToolTip="拖动调整大小">
  <Thumb.Template><ControlTemplate TargetType="Thumb"><Grid Background="Transparent"><Path Data="M 5,12 L 12,5 M 9,12 L 12,9" Stroke="{DynamicResource WidgetMuted}" StrokeThickness="1"/></Grid></ControlTemplate></Thumb.Template>
 </Thumb>
 </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
'Header','Appearance','Settings','Pin','Refresh','Close','Previous','Day','Next','Input','Status','Tasks','ResizeHandle','WidgetFrame','BackgroundLayer','BackgroundFill','WallpaperOverlay' | ForEach-Object { $ui[$_] = $window.FindName($_) }
function Get-WallpaperBitmap([string]$path) {
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 50MB) { throw '请选择小于 50 MB 的图片文件。' }
    $cacheKey = $file.FullName + '|' + $file.LastWriteTimeUtc.Ticks + '|' + $file.Length
    if ($script:wallpaperCache -and $script:wallpaperCache.Key -eq $cacheKey) { return $script:wallpaperCache.Source }
    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
        $bitmap.BeginInit()
        $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.DecodePixelWidth = 1600
        $bitmap.StreamSource = $stream
        $bitmap.EndInit()
        $bitmap.Freeze()
    } finally { $stream.Dispose() }
    $script:wallpaperCache = @{Key=$cacheKey; Source=$bitmap}
    return $bitmap
}
function Apply-Background($value, [switch]$Strict) {
    $normalized = Get-NormalizedBackground $value
    $bitmap = $null
    if ($normalized.Mode -eq 'Image') {
        try { $bitmap = Get-WallpaperBitmap $normalized.ImagePath }
        catch { if ($Strict) { throw } }
    }
    if ($bitmap) {
        $imageBrush = [Windows.Media.ImageBrush]::new($bitmap)
        $imageBrush.Stretch = [Windows.Media.Stretch]::UniformToFill
        $imageBrush.Freeze()
        $ui.BackgroundFill.Background = $imageBrush
        $ui.WallpaperOverlay.Visibility = 'Visible'
        $ui.WallpaperOverlay.Opacity = $normalized.Overlay
    } else {
        $ui.BackgroundFill.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'WidgetBackground')
        $ui.WallpaperOverlay.Visibility = 'Collapsed'
    }
    $ui.BackgroundLayer.Opacity = $normalized.Opacity
    $frameBrush = $window.Resources['WidgetBorder'].Clone()
    $frameBrush.Opacity = $normalized.Opacity
    $frameBrush.Freeze()
    $ui.WidgetFrame.BorderBrush = $frameBrush
    $floatingControls = $normalized.Mode -eq 'Image' -or $normalized.Opacity -lt 1
    $controlBorderColor = Blend-ThemeColor $script:theme.Background $script:theme.Foreground $(if ($floatingControls) { 0.65 } else { 0.24 })
    $controlBorder = [Windows.Media.BrushConverter]::new().ConvertFromString($controlBorderColor)
    $controlBorder.Freeze()
    $window.Resources['WidgetControlBorder'] = $controlBorder
    $surfaceBrush = $window.Resources['WidgetSurface'].Clone()
    # Actionable controls stay readable even when the background itself is invisible.
    $surfaceBrush.Opacity = $(if ($floatingControls) { 0.94 } else { 1 })
    $surfaceBrush.Freeze()
    $window.Resources['WidgetSurface'] = $surfaceBrush
    $script:backgroundSettings = $normalized
}
function Apply-Theme($value) {
    $normalized = Get-NormalizedTheme $value
    $palette = Get-ThemePalette $normalized
    foreach ($key in $palette.Keys) {
        $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($palette[$key])
        $brush.Freeze()
        $window.Resources['Widget' + $key] = $brush
    }
    $script:theme = $normalized
    Apply-Background $script:backgroundSettings
}
Apply-Theme $script:theme
$ui.ResizeHandle.Add_DragDelta({
    $window.Width = [Math]::Max($window.MinWidth, $window.ActualWidth + $_.HorizontalChange)
    $window.Height = [Math]::Max($window.MinHeight, $window.ActualHeight + $_.VerticalChange)
})
function Api([string]$method,[string]$path,$body = $null) {
    $args = @{ Uri = "https://api.todoist.com/api/v1/$path"; Method = $method; Headers = @{Authorization="Bearer $script:token"}; TimeoutSec=15 }
    if ($null -ne $body) { $args.ContentType='application/json; charset=utf-8'; $args.Body=[Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress)) }
    # Windows PowerShell 5.1 may decode JSON as a legacy code page when
    # the response omits charset. Decode the original response bytes explicitly.
    $response = Invoke-WebRequest @args -UseBasicParsing
    $stream = $response.RawContentStream
    $stream.Position = 0
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if (![string]::IsNullOrWhiteSpace($json)) { $json | ConvertFrom-Json }
}
function Show-Error($errorRecord) {
    $ui.Status.Text = '同步失败，请检查网络和 API Token。' + $errorRecord.Exception.Message
}
function Start-Request($kind, $method, $path, $body, $context) {
    $worker = [PowerShell]::Create()
    $code = 'param($token,$kind,$method,$path,$body) $ErrorActionPreference="Stop"; $script:token=$token; function Api {' + ${function:Api}.ToString() + '}; if ($kind -eq "Load") { $all=@(); $cursor=$null; do { $url="tasks?limit=200"; if ($cursor) { $url += "&cursor=" + [Uri]::EscapeDataString($cursor) }; $result=Api "Get" $url; $all+=@($result.results); $cursor=$result.next_cursor } while ($cursor); $all } else { Api $method $path $body }'
    $worker.AddScript($code).AddArgument($script:token).AddArgument($kind).AddArgument($method).AddArgument($path).AddArgument($body) | Out-Null
    $handle=$worker.BeginInvoke()
    $script:jobs.Add(@{Worker=$worker; Handle=$handle; Kind=$kind; Context=$context})
}
function Animate-Complete($check) {
    $state=$check.Tag
    if ($script:pending.ContainsKey($state.Id)) { return }
    $script:pending[$state.Id]=$state
    $script:revision++
    $check.IsEnabled=$false
    $state.Label.TextDecorations=[Windows.TextDecorations]::Strikethrough
    $state.Label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'WidgetAccent')
    $fade=[Windows.Media.Animation.DoubleAnimation]::new(1,0.45,[TimeSpan]::FromMilliseconds(220))
    $state.Border.BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)
    $ui.Status.Text='正在后台同步完成状态…'
    Start-Request 'Close' 'Post' ('tasks/' + $state.Id + '/close') $null $state
}
function Load-Tasks {
    $ui.Day.Content = $script:date.ToString('yyyy年M月d日')
    Render-Tasks
    if ($script:busy -or $script:pending.Count) { return }
    if (!$script:token) { $ui.Status.Text='点击 ⚙ 输入 Todoist API Token 以连接账号。'; return }
    $script:busy=$true
    $ui.Status.Text='正在同步…'
    Start-Request 'Load' 'Get' 'tasks' $null $script:revision
}
function Render-Tasks {
        $selected = $script:date.ToString('yyyy-MM-dd')
        $items = @($script:cachedTasks | Where-Object { $_.due -and $_.due.date.Substring(0,10) -eq $selected -and !$script:pending.ContainsKey($_.id) } | Sort-Object @{Expression={$_.due.date}},order)
        $ui.Tasks.Children.Clear()
        foreach ($task in $items) {
            $border = New-Object Windows.Controls.Border
            $border.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'WidgetDivider')
            $border.BorderThickness = '0,0,0,1'; $border.Padding='2,10,2,10'
            $row = New-Object Windows.Controls.DockPanel
            $check = New-Object Windows.Controls.CheckBox
            $check.Margin='0,2,10,0'; $check.ToolTip='完成任务并同步到 Todoist'
            $check.Add_Click({ Animate-Complete $this })
            $row.Children.Add($check) | Out-Null
            $label = New-Object Windows.Controls.TextBlock
            $label.Text=$task.content; $label.TextWrapping='Wrap'; $label.FontSize=13
            $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'WidgetForeground')
            $check.Tag=@{Id=$task.id; Border=$border; Label=$label; Check=$check}
            $row.Children.Add($label) | Out-Null
            $border.Child=$row; $ui.Tasks.Children.Add($border) | Out-Null
        }
        $ui.Status.Text = "共 $($items.Count) 项 · 同步于 $([DateTime]::Now.ToString('HH:mm')) · 每分钟刷新"
}
function Configure-Theme {
    $originalTheme = Get-NormalizedTheme $script:theme
    $originalBackground = Get-NormalizedBackground $script:backgroundSettings
    $backgroundDraft = Get-NormalizedBackground $script:backgroundSettings
    [xml]$appearanceXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="外观设置" Width="440" MinHeight="360" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#F5F6F7">
 <StackPanel Margin="20">
  <TextBlock Text="颜色、壁纸与透明度" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,6"/>
  <TextBlock Text="修改时实时预览，文字保持清晰。" Foreground="#59636A" Margin="0,0,0,14"/>
  <ComboBox x:Name="Preset" Margin="0,0,0,14" Padding="5" ToolTip="选择配色预设"/>
  <Grid>
   <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/><ColumnDefinition Width="75"/></Grid.ColumnDefinitions>
   <Grid.RowDefinitions><RowDefinition Height="38"/><RowDefinition Height="38"/><RowDefinition Height="38"/></Grid.RowDefinitions>
   <TextBlock Text="背景颜色" VerticalAlignment="Center"/>
   <TextBox x:Name="BackgroundColor" Grid.Column="1" Margin="0,3,10,3" Padding="6" MaxLength="7"/>
   <Button x:Name="PickBackground" Grid.Column="2" Content="选颜色" Margin="0,3,0,3"/>
   <TextBlock Text="文字颜色" Grid.Row="1" VerticalAlignment="Center"/>
   <TextBox x:Name="ForegroundColor" Grid.Row="1" Grid.Column="1" Margin="0,3,10,3" Padding="6" MaxLength="7"/>
   <Button x:Name="PickForeground" Grid.Row="1" Grid.Column="2" Content="选颜色" Margin="0,3,0,3"/>
   <TextBlock Text="强调颜色" Grid.Row="2" VerticalAlignment="Center"/>
   <TextBox x:Name="AccentColor" Grid.Row="2" Grid.Column="1" Margin="0,3,10,3" Padding="6" MaxLength="7"/>
   <Button x:Name="PickAccent" Grid.Row="2" Grid.Column="2" Content="选颜色" Margin="0,3,0,3"/>
  </Grid>
  <Separator Margin="0,10,0,10"/>
  <DockPanel Margin="0,0,0,8">
   <TextBlock Text="背景类型" Width="80" VerticalAlignment="Center"/>
   <ComboBox x:Name="BackgroundMode" Padding="5"/>
  </DockPanel>
  <DockPanel Margin="0,0,0,8">
   <Button x:Name="ChooseWallpaper" Content="选择图片" Padding="8,4" DockPanel.Dock="Right" Margin="8,0,0,0"/>
   <Button x:Name="ClearWallpaper" Content="移除" Padding="8,4" DockPanel.Dock="Right"/>
   <TextBlock x:Name="WallpaperName" Text="未选择壁纸" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
  </DockPanel>
  <TextBlock Text="背景不透明度（0% 为透明，文字不受影响）" Foreground="#59636A"/>
  <DockPanel Margin="0,4,0,8">
   <TextBlock x:Name="OpacityValue" DockPanel.Dock="Right" Width="42" TextAlignment="Right"/>
   <Slider x:Name="BackgroundOpacity" Minimum="0" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True"/>
  </DockPanel>
  <TextBlock Text="壁纸遮罩（使用背景颜色保护文字对比度）" Foreground="#59636A"/>
  <DockPanel Margin="0,4,0,8">
   <TextBlock x:Name="OverlayValue" DockPanel.Dock="Right" Width="42" TextAlignment="Right"/>
   <Slider x:Name="WallpaperOverlayAmount" Minimum="0" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True"/>
  </DockPanel>
  <Button x:Name="MakeTransparent" Content="设为完全透明背景" HorizontalAlignment="Left" Padding="8,4"/>
  <TextBlock x:Name="ColorMessage" Text="支持 #RRGGBB，例如 #263F43。" Foreground="#59636A" Margin="0,8,0,10"/>
  <DockPanel>
   <Button x:Name="ResetColors" Content="恢复默认" Padding="10,5" DockPanel.Dock="Left"/>
   <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
    <Button x:Name="CancelColors" Content="取消" Padding="16,5" Margin="0,0,8,0" IsCancel="True"/>
    <Button x:Name="SaveColors" Content="保存" Padding="16,5" IsDefault="True"/>
   </StackPanel>
  </DockPanel>
 </StackPanel>
</Window>
'@
    $appearanceDialog = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $appearanceXaml))
    $appearanceDialog.Owner = $window
    $backgroundControls = @{}
    foreach ($name in 'BackgroundMode','BackgroundOpacity','WallpaperOverlayAmount','WallpaperName','OpacityValue','OverlayValue') {
        $backgroundControls[$name] = $appearanceDialog.FindName($name)
    }
    $backgroundControls.BackgroundMode.Items.Add('纯色') | Out-Null
    $backgroundControls.BackgroundMode.Items.Add('壁纸') | Out-Null
    $backgroundControls.BackgroundMode.SelectedIndex = $(if ($backgroundDraft.Mode -eq 'Image') { 1 } else { 0 })
    $backgroundControls.BackgroundOpacity.Value = $backgroundDraft.Opacity * 100
    $backgroundControls.WallpaperOverlayAmount.Value = $backgroundDraft.Overlay * 100
    $editBoxes = @{}
    foreach ($key in 'Background','Foreground','Accent') {
        $editBoxes[$key] = $appearanceDialog.FindName($key + 'Color')
        $editBoxes[$key].Text = $originalTheme[$key]
        $picker = $appearanceDialog.FindName('Pick' + $key)
        $picker.Tag = $key
        $picker.Add_Click({
            Add-Type -AssemblyName System.Windows.Forms,System.Drawing
            $colorDialog = [Windows.Forms.ColorDialog]::new()
            $colorDialog.FullOpen = $true
            $colorDialog.AnyColor = $true
            try { $colorDialog.Color = [Drawing.ColorTranslator]::FromHtml((ConvertTo-ThemeColor $editBoxes[$this.Tag].Text)) } catch {}
            $owner = [Windows.Forms.NativeWindow]::new()
            $owner.AssignHandle([Windows.Interop.WindowInteropHelper]::new($appearanceDialog).Handle)
            try {
                if ($colorDialog.ShowDialog($owner) -eq [Windows.Forms.DialogResult]::OK) {
                    $editBoxes[$this.Tag].Text = '#{0:X2}{1:X2}{2:X2}' -f $colorDialog.Color.R,$colorDialog.Color.G,$colorDialog.Color.B
                }
            } finally { $owner.ReleaseHandle(); $colorDialog.Dispose() }
        })
    }
    $colorMessage = $appearanceDialog.FindName('ColorMessage')
    $saveColors = $appearanceDialog.FindName('SaveColors')
    $previewTheme = {
        try {
            $candidate = @{Background=$editBoxes.Background.Text; Foreground=$editBoxes.Foreground.Text; Accent=$editBoxes.Accent.Text}
            Apply-Theme $candidate
            $backgroundDraft.Mode = $(if ($backgroundControls.BackgroundMode.SelectedIndex -eq 1) { 'Image' } else { 'Color' })
            $backgroundDraft.Opacity = [double]$backgroundControls.BackgroundOpacity.Value / 100
            $backgroundDraft.Overlay = [double]$backgroundControls.WallpaperOverlayAmount.Value / 100
            $backgroundControls.OpacityValue.Text = [string][Math]::Round($backgroundControls.BackgroundOpacity.Value) + '%'
            $backgroundControls.OverlayValue.Text = [string][Math]::Round($backgroundControls.WallpaperOverlayAmount.Value) + '%'
            $backgroundControls.WallpaperOverlayAmount.IsEnabled = $backgroundDraft.Mode -eq 'Image'
            $backgroundControls.WallpaperName.Text = $(if ($backgroundDraft.ImagePath) { [IO.Path]::GetFileName($backgroundDraft.ImagePath) } else { '未选择壁纸' })
            $backgroundControls.WallpaperName.ToolTip = $backgroundDraft.ImagePath
            Apply-Background $backgroundDraft -Strict
            $saveColors.IsEnabled = $true
            $colorMessage.Text = '正在预览 · 保存后下次打开继续使用。'
        } catch {
            $saveColors.IsEnabled = $false
            $colorMessage.Text = '请检查色号，或选择可读取的 JPG / PNG / BMP 图片。'
        }
    }
    foreach ($box in $editBoxes.Values) { $box.Add_TextChanged({ & $previewTheme }) }
    $backgroundControls.BackgroundMode.Add_SelectionChanged({ & $previewTheme })
    $backgroundControls.BackgroundOpacity.Add_ValueChanged({ & $previewTheme })
    $backgroundControls.WallpaperOverlayAmount.Add_ValueChanged({ & $previewTheme })
    $appearanceDialog.FindName('ChooseWallpaper').Add_Click({
        $fileDialog = [Microsoft.Win32.OpenFileDialog]::new()
        $fileDialog.Title = '选择组件壁纸'
        $fileDialog.Filter = '图片文件|*.jpg;*.jpeg;*.png;*.bmp|所有文件|*.*'
        $fileDialog.CheckFileExists = $true
        if ($fileDialog.ShowDialog($appearanceDialog)) {
            $backgroundDraft.ImagePath = $fileDialog.FileName
            $backgroundControls.BackgroundMode.SelectedIndex = 1
            if ($backgroundControls.BackgroundOpacity.Value -eq 0) { $backgroundControls.BackgroundOpacity.Value = 100 }
            & $previewTheme
        }
    })
    $appearanceDialog.FindName('ClearWallpaper').Add_Click({
        $backgroundDraft.ImagePath = ''
        $backgroundControls.BackgroundMode.SelectedIndex = 0
        & $previewTheme
    })
    $appearanceDialog.FindName('MakeTransparent').Add_Click({
        $backgroundControls.BackgroundMode.SelectedIndex = 0
        $backgroundControls.BackgroundOpacity.Value = 0
        & $previewTheme
    })
    $presets = [ordered]@{
        '深青色' = (Get-DefaultTheme)
        '石墨黑' = @{Background='#202329'; Foreground='#E8EDF3'; Accent='#8EB8FF'}
        '浅色' = @{Background='#F4F6F8'; Foreground='#28323C'; Accent='#187D70'}
        '暖色' = @{Background='#3A2B29'; Foreground='#F5E7DA'; Accent='#F3B87A'}
    }
    $presetBox = $appearanceDialog.FindName('Preset')
    foreach ($name in $presets.Keys) { $presetBox.Items.Add($name) | Out-Null }
    $presetBox.Add_SelectionChanged({
        if ($null -ne $this.SelectedItem) {
            $presetTheme = $presets[[string]$this.SelectedItem]
            foreach ($key in 'Background','Foreground','Accent') { $editBoxes[$key].Text = $presetTheme[$key] }
        }
    })
    $appearanceDialog.FindName('ResetColors').Add_Click({
        $defaults = Get-DefaultTheme
        foreach ($key in 'Background','Foreground','Accent') { $editBoxes[$key].Text = $defaults[$key] }
        $backgroundDefaults = Get-DefaultBackground
        $backgroundDraft.ImagePath = ''
        $backgroundControls.BackgroundMode.SelectedIndex = 0
        $backgroundControls.BackgroundOpacity.Value = $backgroundDefaults.Opacity * 100
        $backgroundControls.WallpaperOverlayAmount.Value = $backgroundDefaults.Overlay * 100
        & $previewTheme
    })
    $saveColors.Add_Click({
        try {
            $candidate = Get-NormalizedTheme @{Background=$editBoxes.Background.Text; Foreground=$editBoxes.Foreground.Text; Accent=$editBoxes.Accent.Text}
            $backgroundCandidate = Get-NormalizedBackground $backgroundDraft
            Apply-Background $backgroundCandidate -Strict
            $previousTheme = Read-Theme $themePath
            $themeExisted = [IO.File]::Exists($themePath)
            Save-Theme $candidate $themePath
            try { Save-BackgroundSettings $backgroundCandidate $backgroundPath }
            catch {
                if ($themeExisted) { Save-Theme $previousTheme $themePath }
                else { [IO.File]::Delete($themePath) }
                throw
            }
            Apply-Theme $candidate
            $appearanceDialog.DialogResult = $true
        } catch { $colorMessage.Text = '保存失败，请检查色号、图片和本机文件权限。' }
    })
    & $previewTheme
    try { $saved = $appearanceDialog.ShowDialog() }
    finally {
        if ($appearanceDialog.DialogResult -ne $true) {
            Apply-Background $originalBackground
            Apply-Theme $originalTheme
        }
    }
}
function Configure {
    $dialog = New-Object Windows.Window
    $dialog.Title='连接 Todoist'; $dialog.Width=420; $dialog.Height=205; $dialog.ResizeMode='NoResize'; $dialog.Owner=$window; $dialog.WindowStartupLocation='CenterOwner'
    $panel=New-Object Windows.Controls.StackPanel; $panel.Margin='16'
    $label=New-Object Windows.Controls.TextBlock; $label.Text="Todoist → 设置 → 集成 → 开发者 → API Token`n密钥使用 Windows 当前用户加密保存。"; $label.Margin='0,0,0,12'
    $password=New-Object Windows.Controls.PasswordBox; $password.Password=$script:token; $password.Padding='6'
    $save=New-Object Windows.Controls.Button; $save.Content='保存并连接'; $save.Margin='0,12,0,0'; $save.Padding='6'
    $save.Add_Click({ if ($password.Password.Trim()) { Save-Token $password.Password.Trim(); $dialog.DialogResult=$true } })
    $panel.Children.Add($label)|Out-Null; $panel.Children.Add($password)|Out-Null; $panel.Children.Add($save)|Out-Null; $dialog.Content=$panel
    if ($dialog.ShowDialog()) { Load-Tasks }
}
function Test-HeaderDragSource($source) {
    $node = $source
    while ($null -ne $node) {
        if ($node -is [Windows.Controls.Primitives.ButtonBase]) { return $false }
        if ($node -eq $ui.Header) { return $true }
        if ($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]) {
            $node = [Windows.Media.VisualTreeHelper]::GetParent($node)
        } elseif ($node -is [Windows.FrameworkContentElement]) {
            $node = $node.Parent
        } elseif ($node -is [Windows.ContentElement]) {
            $node = [Windows.ContentOperations]::GetParent($node)
        } else { $node = [Windows.LogicalTreeHelper]::GetParent($node) }
    }
    return $false
}
$ui.Header.Add_PreviewMouseLeftButtonDown({
    if ($_.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed -and (Test-HeaderDragSource $_.OriginalSource)) {
        $_.Handled = $true
        $window.DragMove()
    }
})
$ui.Settings.Add_Click({ Configure })
$ui.Appearance.Add_Click({ Configure-Theme })
$ui.Pin.Add_Click({ $window.Topmost = !$window.Topmost; $ui.Pin.Opacity = $(if ($window.Topmost) {1} else {0.45}) })
$ui.Close.Add_Click({ $window.Close() })
$ui.Refresh.Add_Click({ Load-Tasks })
$ui.Previous.Add_Click({ $script:date=$script:date.AddDays(-1); Load-Tasks })
$ui.Next.Add_Click({ $script:date=$script:date.AddDays(1); Load-Tasks })
$ui.Day.Add_Click({ $script:date=[DateTime]::Today; Load-Tasks })
$ui.Input.Add_KeyDown({
    if ($_.Key -eq 'Return' -and $ui.Input.Text.Trim() -and $script:token) {
        if (!$ui.Input.IsEnabled) { return }
        $ui.Input.IsEnabled=$false
        Start-Request 'Add' 'Post' 'tasks' @{content=$ui.Input.Text.Trim(); due_date=$script:date.ToString('yyyy-MM-dd')} $null
    }
})
$poll=New-Object Windows.Threading.DispatcherTimer
$poll.Interval=[TimeSpan]::FromMilliseconds(40)
$poll.Add_Tick({
    foreach ($job in @($script:jobs.ToArray())) {
        if ($job.Kind -eq 'Remove') {
            if ([DateTime]::Now -lt $job.Deadline) { continue }
            $ui.Tasks.Children.Remove($job.Context.Border)
            $script:pending.Remove($job.Context.Id)
            $script:jobs.Remove($job) | Out-Null
            if (!$script:pending.Count) { Load-Tasks }
            continue
        }
        if (!$job.Handle.IsCompleted) { continue }
        $script:jobs.Remove($job) | Out-Null
        $failure=$null; $output=@()
        try {
            $output=@($job.Worker.EndInvoke($job.Handle))
            if ($job.Worker.Streams.Error.Count) { throw $job.Worker.Streams.Error[0] }
        } catch { $failure=$_ } finally { $job.Worker.Dispose() }
        switch ($job.Kind) {
            'Load' {
                $script:busy=$false
                if (!$failure -and $job.Context -eq $script:revision -and !$script:pending.Count) {
                    $script:cachedTasks=$output
                    Render-Tasks
                } elseif (!$failure -and !$script:pending.Count) { Load-Tasks }
            }
            'Close' {
                $state=$job.Context
                if ($failure) {
                    $script:pending.Remove($state.Id)
                    $state.Border.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
                    $state.Check.IsChecked=$false; $state.Check.IsEnabled=$true
                    $state.Label.TextDecorations=$null
                    $state.Label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'WidgetForeground')
                    Render-Tasks
                } else {
                    $script:cachedTasks=@($script:cachedTasks | Where-Object { $_.id -ne $state.Id })
                    $state.Border.ClipToBounds=$true
                    $height=[Windows.Media.Animation.DoubleAnimation]::new($state.Border.ActualHeight,0,[TimeSpan]::FromMilliseconds(280))
                    $height.EasingFunction=[Windows.Media.Animation.CubicEase]::new()
                    $state.Border.BeginAnimation([Windows.FrameworkElement]::HeightProperty,$height)
                    $fade=[Windows.Media.Animation.DoubleAnimation]::new(0.45,0,[TimeSpan]::FromMilliseconds(200))
                    $state.Border.BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)
                    $script:jobs.Add(@{Kind='Remove'; Context=$state; Deadline=[DateTime]::Now.AddMilliseconds(300)})
                }
            }
            'Add' {
                $ui.Input.IsEnabled=$true
                if (!$failure) { $ui.Input.Clear(); $script:revision++; Load-Tasks }
            }
        }
        if ($failure) { Show-Error $failure }
    }
})
$poll.Start()
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMinutes(1); $timer.Add_Tick({ Load-Tasks }); $timer.Start()
$window.Add_ContentRendered({ Load-Tasks })
$window.Add_Closed({
    $timer.Stop(); $poll.Stop()
    foreach ($job in $script:jobs) { if ($job.Worker) { $job.Worker.Stop(); $job.Worker.Dispose() } }
})
$window.ShowDialog() | Out-Null
} finally {
    $widgetMutex.ReleaseMutex()
    $widgetMutex.Dispose()
}
