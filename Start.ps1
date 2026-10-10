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
. (Join-Path $PSScriptRoot 'Calendar.ps1')
. (Join-Path $PSScriptRoot 'FollowSettings.ps1')
. (Join-Path $PSScriptRoot 'WindowPosition.ps1')
. (Join-Path $PSScriptRoot 'ClockSettings.ps1')
. (Join-Path $PSScriptRoot 'DisplaySettings.ps1')
$windowPositionPath = Join-Path $dataDir 'window-position.json'
$clockSettingsPath = Join-Path $dataDir 'clock.json'
$script:clockFormat = (Read-ClockSettings -Path $clockSettingsPath).Format
$displaySettingsPath = Join-Path $dataDir 'display.json'
$script:displaySettings = Read-DisplaySettings -Path $displaySettingsPath
$script:positionReady = $false
$themePath = Join-Path $dataDir 'theme.json'
$script:theme = Read-Theme $themePath
$backgroundPath = Join-Path $dataDir 'background.json'
$script:backgroundSettings = Read-BackgroundSettings $backgroundPath
$script:wallpaperCache = $null
$script:token = ''
$script:date = [DateTime]::Today
$script:viewMode = 'List'
$script:viewSizes = @{ List = @{Width=400.0; Height=460.0}; Calendar = @{Width=780.0; Height=780.0}; Minimal = @{Width=400.0; Height=140.0} }
$script:storedWindowPosition = Read-WindowPosition -Path $windowPositionPath
if ($null -ne $script:storedWindowPosition) {
    foreach ($mode in @($script:viewSizes.Keys)) {
        if ($script:storedWindowPosition.Views.ContainsKey($mode)) {
            $script:viewSizes[$mode] = $script:storedWindowPosition.Views[$mode]
        }
    }
}
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
  <SolidColorBrush x:Key="WidgetCalendarSurface" Color="#365055" Opacity="0.4"/>
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
     <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <TextBlock Text="☀ Todoist" FontWeight="Bold" VerticalAlignment="Center"/>
     <StackPanel Grid.Column="2" Orientation="Horizontal">
      <Button x:Name="MenuButton" Content="⚙" ToolTip="菜单：外观、显示内容和设置" AutomationProperties.Name="菜单">
       <Button.ContextMenu>
        <ContextMenu Background="{DynamicResource WidgetSurface}" BorderBrush="{DynamicResource WidgetControlBorder}" BorderThickness="1" Padding="4">
         <ContextMenu.Resources>
          <Style TargetType="MenuItem">
           <Setter Property="Background" Value="{DynamicResource WidgetSurface}"/>
           <Setter Property="Foreground" Value="{DynamicResource WidgetForeground}"/>
           <Setter Property="FontSize" Value="13"/>
           <Setter Property="MinWidth" Value="120"/>
           <Setter Property="Padding" Value="10,7"/>
           <Setter Property="Cursor" Value="Hand"/>
           <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
            <Border x:Name="MenuChrome" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
             <TextBlock Text="{TemplateBinding Header}" Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
             <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="MenuChrome" Property="Background" Value="{DynamicResource WidgetAccent}"/><Setter Property="Foreground" Value="{DynamicResource WidgetBackground}"/></Trigger>
             <Trigger Property="IsEnabled" Value="False"><Setter TargetName="MenuChrome" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
           </ControlTemplate></Setter.Value></Setter>
          </Style>
         </ContextMenu.Resources>
         <MenuItem x:Name="AppearanceMenuItem" Header="外观" ToolTip="颜色、壁纸和透明度"/>
         <MenuItem x:Name="DisplayMenuItem" Header="显示内容" ToolTip="时间、月历和列表开关"/>
         <MenuItem x:Name="SettingsMenuItem" Header="设置" ToolTip="连接、启动和时钟设置"/>
        </ContextMenu>
       </Button.ContextMenu>
      </Button>
      <Button x:Name="Pin" Content="📌" ToolTip="切换置顶" Background="{DynamicResource WidgetAccent}" Foreground="{DynamicResource WidgetBackground}"/>
      <Button x:Name="Refresh" Content="↻" ToolTip="刷新"/>
      <Button x:Name="Close" Content="×" ToolTip="关闭"/>
     </StackPanel>
    </Grid>
    <Border x:Name="ClockSurface" HorizontalAlignment="Center" Background="{DynamicResource WidgetSurface}" BorderBrush="{DynamicResource WidgetControlBorder}" BorderThickness="1" CornerRadius="8" Padding="16,4" Margin="0,0,0,8" Cursor="SizeAll" ToolTip="拖动时钟移动组件">
     <TextBlock x:Name="Clock" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold" FontSize="22" Typography.NumeralAlignment="Tabular" TextAlignment="Center" Foreground="{DynamicResource WidgetForeground}"/>
    </Border>
    <StackPanel x:Name="DateNavigation" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,8"><Button x:Name="Previous" Content="‹"/><Button x:Name="Day" Content="今天"/><Button x:Name="Next" Content="›"/><Button x:Name="ViewToggle" Content="月历" ToolTip="切换到完整月历" Margin="10,2,2,2"/></StackPanel>
    <TextBox x:Name="Input" Background="{DynamicResource WidgetSurface}" Foreground="{DynamicResource WidgetForeground}" CaretBrush="{DynamicResource WidgetForeground}" BorderBrush="{DynamicResource WidgetControlBorder}" BorderThickness="1.5" Padding="9" Margin="0,0,0,8" ToolTip="输入任务内容，回车添加到当前日期"/>
   </StackPanel>
   <TextBlock x:Name="Status" DockPanel.Dock="Bottom" Foreground="{DynamicResource WidgetMuted}" TextWrapping="Wrap" Margin="0,8,0,0" FontSize="11"/>
   <Grid>
    <ScrollViewer x:Name="ListView" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Tasks"/></ScrollViewer>
    <Grid x:Name="CalendarView" Visibility="Collapsed">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
     <Border Background="{DynamicResource WidgetSurface}" CornerRadius="4" Margin="2,0,2,4" Padding="0,5">
      <UniformGrid Columns="7">
       <TextBlock Text="周一" HorizontalAlignment="Center"/><TextBlock Text="周二" HorizontalAlignment="Center"/><TextBlock Text="周三" HorizontalAlignment="Center"/><TextBlock Text="周四" HorizontalAlignment="Center"/><TextBlock Text="周五" HorizontalAlignment="Center"/><TextBlock Text="周六" HorizontalAlignment="Center"/><TextBlock Text="周日" HorizontalAlignment="Center"/>
      </UniformGrid>
     </Border>
     <UniformGrid x:Name="CalendarDays" Grid.Row="1" Columns="7"/>
    </Grid>
    <TextBlock x:Name="NoViewsHint" Text="月历和列表已关闭。点击 ⚙ → 显示内容可重新开启。" Foreground="{DynamicResource WidgetMuted}" TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
   </Grid>
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
'Header','ClockSurface','Clock','MenuButton','Pin','Refresh','Close','DateNavigation','Previous','Day','Next','ViewToggle','Input','Status','Tasks','ListView','CalendarView','CalendarDays','NoViewsHint','ResizeHandle','WidgetFrame','BackgroundLayer','BackgroundFill','WallpaperOverlay' | ForEach-Object { $ui[$_] = $window.FindName($_) }
$ui.AppearanceMenuItem = $ui.MenuButton.ContextMenu.Items[0]
$ui.DisplayMenuItem = $ui.MenuButton.ContextMenu.Items[1]
$ui.SettingsMenuItem = $ui.MenuButton.ContextMenu.Items[2]
$window.Width = $script:viewSizes.List.Width
$window.Height = $script:viewSizes.List.Height
function Save-WidgetPosition {
    if (!$script:positionReady -or $window.WindowState -ne [Windows.WindowState]::Normal) { return }
    try {
        $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        $bounds = [TodoistWidget.NativeWindow]::GetWidgetBounds($handle)
        if ($bounds[2] -gt 0 -and $bounds[3] -gt 0) {
            $script:viewSizes[$script:viewMode] = @{ Width=$window.Width; Height=$window.Height }
            $views = @{}
            $previous = Read-WindowPosition -Path $windowPositionPath
            if ($null -ne $previous) {
                foreach ($mode in @($previous.Views.Keys)) { $views[$mode] = $previous.Views[$mode] }
            }
            foreach ($mode in @($script:viewSizes.Keys)) { $views[$mode] = $script:viewSizes[$mode] }
            Save-WindowPosition -Position @{Left=$bounds[0]; Top=$bounds[1]; Views=$views} -Path $windowPositionPath
        }
    } catch {
        # Position preferences must not interrupt task editing; a later move retries.
    }
}
function Restore-WidgetPosition {
    $position = $script:storedWindowPosition
    if ($null -eq $position) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        $bounds = [TodoistWidget.NativeWindow]::GetWidgetBounds($handle)
        # Both native bounds and screen work areas use the process's screen coordinates.
        $areas = @([Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.WorkingArea })
        $visible = Get-VisibleWindowPosition -Left $position.Left -Top $position.Top -Width $bounds[2] -Height $bounds[3] -WorkingAreas $areas
        $area = @($areas | Where-Object {
            $visible.Left -ge $_.Left -and $visible.Left -lt $_.Right -and
            $visible.Top -ge $_.Top -and $visible.Top -lt $_.Bottom
        } | Select-Object -First 1)
        if ($area.Count) {
            $scaleX = $bounds[2] / $window.Width
            $scaleY = $bounds[3] / $window.Height
            if ($scaleX -gt 0 -and $scaleY -gt 0) {
                $window.Width = [Math]::Max($window.MinWidth, [Math]::Min($window.Width, $area[0].Width / $scaleX))
                $window.Height = [Math]::Max($window.MinHeight, [Math]::Min($window.Height, $area[0].Height / $scaleY))
                $bounds = [TodoistWidget.NativeWindow]::GetWidgetBounds($handle)
                $visible = Get-VisibleWindowPosition -Left $position.Left -Top $position.Top -Width $bounds[2] -Height $bounds[3] -WorkingAreas $areas
            }
        }
        [TodoistWidget.NativeWindow]::MoveWidget($handle, $visible.Left, $visible.Top)
    } catch {
        # Missing displays or unreadable preferences fall back to Windows placement.
    }
}
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
    $calendarSurface = $surfaceBrush.Clone()
    $calendarSurface.Opacity = $(if ($floatingControls) { 0.18 } else { 0.4 })
    $calendarSurface.Freeze()
    $window.Resources['WidgetCalendarSurface'] = $calendarSurface
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
    foreach ($priority in 1..4) {
        $priorityColor = switch ($priority) { 4 { '#ED7777' } 3 { '#EEB17C' } 2 { '#7EB9E8' } default { $normalized.Accent } }
        $brush = [Windows.Media.BrushConverter]::new().ConvertFromString((Blend-ThemeColor $normalized.Background $priorityColor 0.42))
        $brush.Freeze()
        $window.Resources['WidgetCalendarPriority' + $priority] = $brush
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
    Render-Tasks
    if ($script:viewMode -eq 'Minimal') { return }
    if ($script:busy -or $script:pending.Count) { return }
    if (!$script:token) { $ui.Status.Text='点击 ⚙ 输入 Todoist API Token 以连接账号。'; return }
    $script:busy=$true
    $ui.Status.Text='正在同步…'
    Start-Request 'Load' 'Get' 'tasks' $null $script:revision
}
function Render-DailyTasks {
        $selected = $script:date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $candidates = @($script:cachedTasks)
        $cachedIds = @{}
        foreach ($task in $candidates) { $cachedIds[[string]$task.id] = $true }
        foreach ($state in $script:pending.Values) {
            if (!$cachedIds.ContainsKey([string]$state.Id)) { $candidates += $state.Task }
        }
        $items = @($candidates | Where-Object { (Get-TaskDateKey $_) -eq $selected } | Sort-Object @{Expression={$_.due.date}},order)
        $ui.Tasks.Children.Clear()
        foreach ($task in $items) {
            if ($script:pending.ContainsKey($task.id)) {
                $ui.Tasks.Children.Add($script:pending[$task.id].Border) | Out-Null
                continue
            }
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
            $check.Tag=@{Id=$task.id; Border=$border; Label=$label; Check=$check; Task=$task}
            $row.Children.Add($label) | Out-Null
            $border.Child=$row; $ui.Tasks.Children.Add($border) | Out-Null
        }
        $remaining = @($items | Where-Object { !$script:pending.ContainsKey($_.id) }).Count
        $ui.Status.Text = "共 $remaining 项 · 同步于 $([DateTime]::Now.ToString('HH:mm')) · 每分钟刷新"
}
function Render-Calendar {
    $days = @(Get-CalendarDays $script:date)
    $groups = Get-CalendarTaskGroups $script:cachedTasks $script:pending
    $ui.CalendarDays.Children.Clear()
    $ui.CalendarDays.Rows = [int]($days.Count / 7)
    $monthCount = 0
    foreach ($date in $days) {
        $key = $date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $tasks = @()
        if ($groups.ContainsKey($key)) { $tasks = @($groups[$key]) }
        $currentMonth = $date.Month -eq $script:date.Month -and $date.Year -eq $script:date.Year
        if ($currentMonth) { $monthCount += $tasks.Count }
        $cell = [Windows.Controls.Button]::new()
        $cell.Tag = $date
        $cell.Padding = '4'
        $cell.Margin = '1'
        $cell.MinHeight = 0
        $cell.HorizontalContentAlignment = 'Stretch'
        $cell.VerticalContentAlignment = 'Stretch'
        $cell.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'WidgetCalendarSurface')
        if ($date.Date -eq $script:date.Date) {
            $cell.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, 'WidgetAccent')
            $cell.BorderThickness = '2'
        } else { $cell.BorderThickness = '0.7' }
        $content = [Windows.Controls.Grid]::new()
        $content.ClipToBounds = $true
        $content.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
        $content.RowDefinitions[0].Height = 'Auto'
        $content.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
        $content.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
        $content.RowDefinitions[2].Height = 'Auto'
        $datePanel = [Windows.Controls.DockPanel]::new()
        $datePanel.LastChildFill = $false
        $dateLabel = [Windows.Controls.TextBlock]::new()
        $dateLabel.Text = $date.Day.ToString()
        $dateLabel.FontWeight = 'SemiBold'
        $dateLabel.FontSize = 12
        $dateLabel.Margin = '3,1,3,2'
        if ($date.Date -eq [DateTime]::Today) {
            $dateLabel.Text += ' 今天'
            $dateLabel.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'WidgetAccent')
        }
        $datePanel.Children.Add($dateLabel) | Out-Null
        if ($tasks.Count) {
            $count = [Windows.Controls.TextBlock]::new()
            $count.Text = "$($tasks.Count) 项"
            $count.FontSize = 10
            $count.Margin = '2,2,3,2'
            [Windows.Controls.DockPanel]::SetDock($count, 'Right')
            $datePanel.Children.Add($count) | Out-Null
        }
        $dateHeader = [Windows.Controls.Border]::new()
        $dateHeader.CornerRadius = '3'
        $dateHeader.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'WidgetSurface')
        $dateHeader.Child = $datePanel
        if (!$currentMonth) { $dateHeader.Opacity = 0.6 }
        $content.Children.Add($dateHeader) | Out-Null
        $preview = [Windows.Controls.StackPanel]::new()
        $preview.Margin = '0,3,0,0'
        [Windows.Controls.Grid]::SetRow($preview, 1)
        foreach ($task in @($tasks | Select-Object -First 3)) {
            $taskLabel = [Windows.Controls.TextBlock]::new()
            $taskLabel.Text = $task.content
            $taskLabel.FontSize = 11
            $taskLabel.TextTrimming = 'CharacterEllipsis'
            $taskLabel.Margin = '4,0,4,0'
            $taskLabel.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'WidgetForeground')
            $strip = [Windows.Controls.Border]::new()
            $strip.CornerRadius = '2'
            $strip.Margin = '0,0,0,1'
            $strip.Child = $taskLabel
            $priority = [Math]::Max(1, [Math]::Min(4, [int]$task.priority))
            $strip.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'WidgetCalendarPriority' + $priority)
            $preview.Children.Add($strip) | Out-Null
        }
        $content.Children.Add($preview) | Out-Null
        $more = [Windows.Controls.TextBlock]::new()
        $more.Text = "另有 $([Math]::Max(0, $tasks.Count - 3)) 项"
        $more.FontSize = 10
        $more.Margin = '3,1,0,0'
        $more.Visibility = $(if ($tasks.Count -gt 3) { 'Visible' } else { 'Collapsed' })
        $more.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'WidgetForeground')
        $more.SetResourceReference([Windows.Controls.TextBlock]::BackgroundProperty, 'WidgetSurface')
        [Windows.Controls.Grid]::SetRow($more, 2)
        $content.Children.Add($more) | Out-Null
        $content.Tag = @{Count=$tasks.Count; Header=$dateHeader; Preview=$preview; More=$more}
        $content.Add_SizeChanged({
            $state = $this.Tag
            if (!$state.Count -or $this.ActualHeight -le 0) { return }
            $available = [Math]::Max(0, $this.ActualHeight - $state.Header.ActualHeight - 3)
            $rowHeight = 15.0
            foreach ($strip in $state.Preview.Children) { $rowHeight = [Math]::Max($rowHeight, $strip.DesiredSize.Height) }
            $shown = [Math]::Min(3, $state.Count)
            if ($state.Count -gt 3 -or $shown * $rowHeight -gt $available) {
                $shown = [Math]::Min($shown, [Math]::Max(0, [Math]::Floor(($available - 14) / $rowHeight)))
            }
            for ($index=0; $index -lt $state.Preview.Children.Count; $index++) {
                $state.Preview.Children[$index].Visibility = $(if ($index -lt $shown) { 'Visible' } else { 'Collapsed' })
            }
            $state.More.Text = "另有 $($state.Count - $shown) 项"
            $state.More.Visibility = $(if ($state.Count -gt $shown) { 'Visible' } else { 'Collapsed' })
        })
        $cell.Content = $content
        $cell.ToolTip = $date.ToString('M月d日') + $(if ($script:displaySettings.ShowList) { ' · 点击查看当天任务' } else { ' · 在显示设置中开启列表后可查看当天任务' })
        if ($tasks.Count) { $cell.ToolTip += "`n" + (($tasks | ForEach-Object { $_.content }) -join "`n") }
        $cell.Add_Click({ if ($script:displaySettings.ShowList) { $script:date = [DateTime]$this.Tag; Set-WidgetView 'List' } })
        $ui.CalendarDays.Children.Add($cell) | Out-Null
    }
    $ui.Status.Text = "本月 $monthCount 项 · $(if ($script:displaySettings.ShowList) { '点击日期查看任务 · ' } else { '' })每分钟刷新"
}
function Render-Tasks {
    if ($script:viewMode -eq 'Minimal') {
        $ui.Status.Text = ''
        return
    }
    if ($script:viewMode -eq 'Calendar') {
        $ui.Day.Content = $script:date.ToString('yyyy年M月')
        $ui.Day.ToolTip = '返回本月'
        $ui.Previous.ToolTip = '上个月'
        $ui.Next.ToolTip = '下个月'
        Render-Calendar
    } else {
        $ui.Day.Content = $script:date.ToString('yyyy年M月d日')
        $ui.Day.ToolTip = '返回今天'
        $ui.Previous.ToolTip = '前一天'
        $ui.Next.ToolTip = '后一天'
        Render-DailyTasks
    }
}
function Update-ViewVisibility {
    $calendar = $script:viewMode -eq 'Calendar'
    $minimal = $script:viewMode -eq 'Minimal'
    $ui.ListView.Visibility = $(if (!$calendar -and !$minimal) { 'Visible' } else { 'Collapsed' })
    $ui.Input.Visibility = $(if (!$calendar -and !$minimal) { 'Visible' } else { 'Collapsed' })
    $ui.CalendarView.Visibility = $(if ($calendar) { 'Visible' } else { 'Collapsed' })
    $ui.NoViewsHint.Visibility = $(if ($minimal) { 'Visible' } else { 'Collapsed' })
    $ui.DateNavigation.Visibility = $(if ($minimal) { 'Collapsed' } else { 'Visible' })
    $ui.Status.Visibility = $(if ($minimal) { 'Collapsed' } else { 'Visible' })
    $ui.Refresh.Visibility = $(if ($minimal) { 'Collapsed' } else { 'Visible' })
    $ui.ViewToggle.Visibility = $(if ($script:displaySettings.ShowList -and $script:displaySettings.ShowCalendar) { 'Visible' } else { 'Collapsed' })
    $ui.ViewToggle.Content = $(if ($calendar) { '列表' } else { '月历' })
    $ui.ViewToggle.ToolTip = $(if ($calendar) { '切换到每日任务列表' } else { '切换到完整月历' })
}
function Set-WidgetView([ValidateSet('List','Calendar','Minimal')][string]$Mode) {
    if ($Mode -eq 'List' -and !$script:displaySettings.ShowList) { return }
    if ($Mode -eq 'Calendar' -and !$script:displaySettings.ShowCalendar) { return }
    if ($Mode -eq 'Minimal' -and ($script:displaySettings.ShowList -or $script:displaySettings.ShowCalendar)) { return }
    if ($Mode -eq $script:viewMode) { Update-ViewVisibility; Render-Tasks; return }
    $script:viewSizes[$script:viewMode] = @{Width=$window.Width; Height=$window.Height}
    $script:viewMode = $Mode
    $calendar = $Mode -eq 'Calendar'
    Update-ViewVisibility
    $window.MinWidth = $(if ($calendar) { 560 } else { 340 })
    $window.MinHeight = $(if ($calendar) { 440 } elseif ($Mode -eq 'Minimal') { 110 } else { 240 })
    $window.Width = $script:viewSizes[$Mode].Width
    $window.Height = $script:viewSizes[$Mode].Height
    # Keep an expanded calendar on the widget's current monitor.
    Add-Type -AssemblyName System.Windows.Forms
    $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
    $area = [Windows.Forms.Screen]::FromHandle($handle).WorkingArea
    $dpi = [Windows.PresentationSource]::FromVisual($window)
    $scaleX = 1.0; $scaleY = 1.0
    if ($dpi) { $scaleX = $dpi.CompositionTarget.TransformToDevice.M11; $scaleY = $dpi.CompositionTarget.TransformToDevice.M22 }
    $left = $area.Left / $scaleX; $top = $area.Top / $scaleY
    $right = $area.Right / $scaleX; $bottom = $area.Bottom / $scaleY
    $window.Width = [Math]::Max($window.MinWidth, [Math]::Min($window.Width, $area.Width / $scaleX))
    $window.Height = [Math]::Max($window.MinHeight, [Math]::Min($window.Height, $area.Height / $scaleY))
    if (![double]::IsNaN($window.Left)) { $window.Left = [Math]::Max($left, [Math]::Min($window.Left, $right - $window.Width)) }
    if (![double]::IsNaN($window.Top)) { $window.Top = [Math]::Max($top, [Math]::Min($window.Top, $bottom - $window.Height)) }
    Render-Tasks
}
function Apply-DisplaySettings {
    $ui.ClockSurface.Visibility = $(if ($script:displaySettings.ShowClock) { 'Visible' } else { 'Collapsed' })
    if ($clockTimer) {
        if ($script:displaySettings.ShowClock) { Update-ClockDisplay; $clockTimer.Start() }
        else { $clockTimer.Stop() }
    }
    $previousMode = $script:viewMode
    $targetMode = $script:viewMode
    if (!$script:displaySettings.ShowList -and !$script:displaySettings.ShowCalendar) {
        $targetMode = 'Minimal'
    } elseif ($targetMode -eq 'Minimal' -or ($targetMode -eq 'List' -and !$script:displaySettings.ShowList) -or ($targetMode -eq 'Calendar' -and !$script:displaySettings.ShowCalendar)) {
        $targetMode = $(if ($script:displaySettings.ShowList) { 'List' } else { 'Calendar' })
    }
    Set-WidgetView $targetMode
    if ($previousMode -eq 'Minimal' -and $targetMode -ne 'Minimal') { Load-Tasks }
}
function Configure-Display {
    [xml]$displayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="显示内容" Width="330" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#F5F6F7">
 <StackPanel Margin="20">
  <TextBlock Text="显示内容" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,6"/>
  <TextBlock Text="按需开启或关闭，修改后立即保存。" Foreground="#59636A" TextWrapping="Wrap" Margin="0,0,0,14"/>
  <CheckBox x:Name="ShowClock" Content="时间" FontSize="14" Margin="0,0,0,12"/>
  <CheckBox x:Name="ShowCalendar" Content="月历" FontSize="14" Margin="0,0,0,12"/>
  <CheckBox x:Name="ShowList" Content="列表" FontSize="14" Margin="0,0,0,10"/>
  <TextBlock x:Name="DisplayStatus" Foreground="#59636A" FontSize="11" TextWrapping="Wrap"/>
  <Button x:Name="CloseDisplay" Content="关闭" IsCancel="True" HorizontalAlignment="Right" MinWidth="75" Padding="8,5" Margin="0,14,0,0"/>
 </StackPanel>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $displayXaml))
    $dialog.Owner = $window
    $clockCheck = $dialog.FindName('ShowClock')
    $calendarCheck = $dialog.FindName('ShowCalendar')
    $listCheck = $dialog.FindName('ShowList')
    $message = $dialog.FindName('DisplayStatus')
    $clockCheck.IsChecked = $script:displaySettings.ShowClock
    $calendarCheck.IsChecked = $script:displaySettings.ShowCalendar
    $listCheck.IsChecked = $script:displaySettings.ShowList
    $message.Text = '月历和列表都关闭时，组件只显示标题和可选时间。'
    $toggleDisplay = {
        $candidate = @{
            ShowClock = [bool]$clockCheck.IsChecked
            ShowCalendar = [bool]$calendarCheck.IsChecked
            ShowList = [bool]$listCheck.IsChecked
        }
        $previous = $script:displaySettings
        try {
            Save-DisplaySettings -Settings $candidate -Path $displaySettingsPath
            $script:displaySettings = $candidate
            Apply-DisplaySettings
            $message.Foreground = [Windows.Media.Brushes]::DimGray
            $message.Text = '已保存。'
        } catch {
            $script:displaySettings = $previous
            try { Save-DisplaySettings -Settings $previous -Path $displaySettingsPath } catch {}
            try { Apply-DisplaySettings } catch {}
            $clockCheck.IsChecked = $previous.ShowClock
            $calendarCheck.IsChecked = $previous.ShowCalendar
            $listCheck.IsChecked = $previous.ShowList
            $message.Foreground = [Windows.Media.Brushes]::Firebrick
            $message.Text = '保存显示设置失败，请重试。'
        }
    }
    $clockCheck.Add_Click($toggleDisplay)
    $calendarCheck.Add_Click($toggleDisplay)
    $listCheck.Add_Click($toggleDisplay)
    $dialog.ShowDialog() | Out-Null
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
function Update-ClockDisplay {
    $text = Format-WidgetClock -DateTime ([DateTime]::Now) -Format $script:clockFormat
    if ($ui.Clock.Text -cne $text) { $ui.Clock.Text = $text }
}
function Start-FollowUpdate([bool]$Enabled, $Context) {
    $worker = [PowerShell]::Create()
    try {
        $code = 'param($runtimePath,$settingsPath,$enabled) $ErrorActionPreference="Stop"; . $runtimePath; . $settingsPath; $null=Set-FollowEnabled -Enabled $enabled -SkipInitialOpen; Get-FollowEnabled'
        $worker.AddScript($code).AddArgument((Join-Path $PSScriptRoot 'Runtime.ps1')).AddArgument((Join-Path $PSScriptRoot 'FollowSettings.ps1')).AddArgument($Enabled) | Out-Null
        $handle = $worker.BeginInvoke()
        $script:jobs.Add(@{Worker=$worker; Handle=$handle; Kind='Follow'; Context=$Context})
    } catch { $worker.Dispose(); throw }
}
function Configure {
    [xml]$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="设置" Width="440" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#F5F6F7">
 <StackPanel Margin="20">
  <TextBlock Text="连接 Todoist" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,8"/>
  <TextBlock Text="设置 → 关联应用 → 开发者，复制 API Token。" TextWrapping="Wrap" Foreground="#59636A" Margin="0,0,0,10"/>
  <PasswordBox x:Name="ApiToken" Padding="7"/>
  <TextBlock Text="API Token 仅保存在这台电脑上。" Foreground="#59636A" FontSize="11" Margin="0,6,0,0"/>
  <Button x:Name="SaveConnection" Content="保存并连接" Padding="8" Margin="0,10,0,0"/>
  <TextBlock x:Name="ConnectionStatus" Foreground="#AF3333" TextWrapping="Wrap" Margin="0,6,0,0"/>
  <Border Background="#E9EEF0" CornerRadius="6" Padding="12" Margin="0,14,0,0">
   <StackPanel>
    <TextBlock Text="启动联动" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,10"/>
    <CheckBox x:Name="FollowStartup" Content="打开 Todoist 时自动启动 Todoist Widget" FontSize="13"/>
    <TextBlock x:Name="FollowStatus" Foreground="#59636A" TextWrapping="Wrap" FontSize="11" Margin="20,6,0,0"/>
    <TextBlock Text="关闭 Todoist 后，本应用继续运行。也可以通过桌面快捷方式独立打开。" Foreground="#59636A" TextWrapping="Wrap" FontSize="11" Margin="0,12,0,0"/>
   </StackPanel>
  </Border>
  <Border Background="#E9EEF0" CornerRadius="6" Padding="12" Margin="0,10,0,0">
   <StackPanel>
    <TextBlock Text="时钟" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,8"/>
    <ComboBox x:Name="ClockFormat" HorizontalAlignment="Left" MinWidth="150" Padding="6,3">
     <ComboBoxItem Content="24 小时制" Tag="24h"/>
     <ComboBoxItem Content="12 小时制" Tag="12h"/>
    </ComboBox>
    <TextBlock x:Name="ClockFormatStatus" Foreground="#59636A" TextWrapping="Wrap" FontSize="11" Margin="0,6,0,0"/>
   </StackPanel>
  </Border>
  <Button x:Name="CloseSettings" Content="关闭" IsCancel="True" HorizontalAlignment="Right" MinWidth="75" Padding="8,5" Margin="0,14,0,0"/>
 </StackPanel>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $settingsXaml))
    $dialog.Owner = $window
    $password = $dialog.FindName('ApiToken')
    $password.Password = $script:token
    $save = $dialog.FindName('SaveConnection')
    $save.IsEnabled = ![string]::IsNullOrWhiteSpace($password.Password)
    $password.Add_PasswordChanged({ $save.IsEnabled = ![string]::IsNullOrWhiteSpace($this.Password) })
    $save.Add_Click({
        try { Save-Token $password.Password.Trim(); $dialog.DialogResult = $true }
        catch { $dialog.FindName('ConnectionStatus').Text = '保存失败，请重试。' }
    })
    $follow = $dialog.FindName('FollowStartup')
    $followStatus = $dialog.FindName('FollowStatus')
    $follow.IsChecked = Get-FollowEnabled
    $followStatus.Text = $(if ($follow.IsChecked) { '已开启，打开 Todoist 时自动启动。' } else { '已关闭，使用桌面快捷方式独立启动。' })
    $follow.Tag = @{Check=$follow; Message=$followStatus; Previous=[bool]$follow.IsChecked}
    $activeFollow = @($script:jobs | Where-Object { $_.Kind -eq 'Follow' }) | Select-Object -Last 1
    if ($activeFollow) {
        $follow.Tag = $activeFollow.Context
        $follow.Tag.Check = $follow
        $follow.Tag.Message = $followStatus
        $follow.IsChecked = $follow.Tag.Desired
        $follow.IsEnabled = $false
        $followStatus.Text = '正在保存启动设置…'
    }
    $follow.Add_Click({
        $state = $this.Tag
        $state.Desired = [bool]$this.IsChecked
        $state.Check.IsEnabled = $false
        $state.Message.Foreground = [Windows.Media.Brushes]::DimGray
        $state.Message.Text = '正在保存启动设置…'
        try { Start-FollowUpdate ([bool]$this.IsChecked) $state }
        catch {
            $state.Check.IsChecked = $state.Previous
            $state.Check.IsEnabled = $true
            $state.Message.Text = '修改失败，请重试。'
            $state.Message.Foreground = [Windows.Media.Brushes]::Firebrick
        }
    })
    $clockChoice = $dialog.FindName('ClockFormat')
    $clockStatus = $dialog.FindName('ClockFormatStatus')
    $clockChoice.SelectedIndex = $(if ($script:clockFormat -eq '12h') { 1 } else { 0 })
    $clockStatus.Text = '切换后立即保存，只影响顶部时间显示。'
    $clockChoice.Add_SelectionChanged({
        if ($null -eq $this.SelectedItem) { return }
        $desiredFormat = [string]$this.SelectedItem.Tag
        if ($desiredFormat -eq $script:clockFormat) { return }
        try {
            Save-ClockSettings -Format $desiredFormat -Path $clockSettingsPath
            $script:clockFormat = $desiredFormat
            Update-ClockDisplay
            $clockStatus.Foreground = [Windows.Media.Brushes]::DimGray
            $clockStatus.Text = '时钟格式已保存。'
        } catch {
            $this.SelectedIndex = $(if ($script:clockFormat -eq '12h') { 1 } else { 0 })
            $clockStatus.Foreground = [Windows.Media.Brushes]::Firebrick
            $clockStatus.Text = '保存时钟格式失败，请重试。'
        }
    })
    if ($dialog.ShowDialog()) { Load-Tasks }
}
function Test-HeaderDragSource($source) {
    $node = $source
    while ($null -ne $node) {
        if ($node -is [Windows.Controls.Primitives.ButtonBase]) { return $false }
        if ($node -eq $ui.Header -or $node -eq $ui.ClockSurface) { return $true }
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
$dragWidget = {
    if ($_.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed -and (Test-HeaderDragSource $_.OriginalSource)) {
        $_.Handled = $true
        $window.DragMove()
    }
}
$ui.Header.Add_PreviewMouseLeftButtonDown($dragWidget)
$ui.ClockSurface.Add_PreviewMouseLeftButtonDown($dragWidget)
$ui.MenuButton.Add_Click({
    $menu = $ui.MenuButton.ContextMenu
    $menu.PlacementTarget = $ui.MenuButton
    $menu.Placement = [Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = !$menu.IsOpen
})
$ui.AppearanceMenuItem.Add_Click({ $ui.MenuButton.ContextMenu.IsOpen = $false; Configure-Theme })
$ui.DisplayMenuItem.Add_Click({ $ui.MenuButton.ContextMenu.IsOpen = $false; Configure-Display })
$ui.SettingsMenuItem.Add_Click({ $ui.MenuButton.ContextMenu.IsOpen = $false; Configure })
$ui.Pin.Add_Click({ $window.Topmost = !$window.Topmost; $ui.Pin.Opacity = $(if ($window.Topmost) {1} else {0.45}) })
$ui.Close.Add_Click({ $window.Close() })
$ui.Refresh.Add_Click({ Load-Tasks })
$ui.ViewToggle.Add_Click({ Set-WidgetView $(if ($script:viewMode -eq 'List') { 'Calendar' } else { 'List' }) })
$ui.Previous.Add_Click({ $script:date = $(if ($script:viewMode -eq 'Calendar') { $script:date.AddMonths(-1) } else { $script:date.AddDays(-1) }); Load-Tasks })
$ui.Next.Add_Click({ $script:date = $(if ($script:viewMode -eq 'Calendar') { $script:date.AddMonths(1) } else { $script:date.AddDays(1) }); Load-Tasks })
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
            'Follow' {
                $state = $job.Context
                $state.Check.IsEnabled = $true
                if ($failure) {
                    $state.Check.IsChecked = $state.Previous
                    $state.Message.Foreground = [Windows.Media.Brushes]::Firebrick
                    $state.Message.Text = '修改失败，请重试。' + $failure.Exception.Message
                } else {
                    $enabled = [bool]$output[-1]
                    $state.Previous = $enabled
                    $state.Check.IsChecked = $enabled
                    $state.Message.Foreground = [Windows.Media.Brushes]::DimGray
                    $state.Message.Text = $(if ($enabled) { '已开启，打开 Todoist 时自动启动。' } else { '已关闭，使用桌面快捷方式独立启动。' })
                }
            }
        }
        if ($failure -and $job.Kind -ne 'Follow') { Show-Error $failure }
    }
})
$poll.Start()
$clockTimer = [Windows.Threading.DispatcherTimer]::new()
$clockTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$clockTimer.Add_Tick({ Update-ClockDisplay })
Update-ClockDisplay
$clockTimer.Start()
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMinutes(1); $timer.Add_Tick({ Load-Tasks }); $timer.Start()
$window.Add_ContentRendered({ Load-Tasks })
$positionSaveTimer = [Windows.Threading.DispatcherTimer]::new()
$positionSaveTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$positionSaveTimer.Add_Tick({ $this.Stop(); Save-WidgetPosition })
$window.Add_Loaded({ Restore-WidgetPosition; $script:positionReady = $true })
$window.Add_LocationChanged({
    if ($script:positionReady -and $window.WindowState -eq [Windows.WindowState]::Normal) {
        $positionSaveTimer.Stop()
        $positionSaveTimer.Start()
    }
})
$window.Add_SizeChanged({
    if ($script:positionReady -and $window.WindowState -eq [Windows.WindowState]::Normal) {
        $positionSaveTimer.Stop()
        $positionSaveTimer.Start()
    }
})
$window.Add_Closing({ $positionSaveTimer.Stop(); Save-WidgetPosition })
$window.Add_Closed({
    $positionSaveTimer.Stop()
    $script:positionReady = $false
    $timer.Stop(); $poll.Stop(); $clockTimer.Stop()
    foreach ($job in $script:jobs) { if ($job.Worker) { $job.Worker.Stop(); $job.Worker.Dispose() } }
})
Apply-DisplaySettings
$window.ShowDialog() | Out-Null
} finally {
    $widgetMutex.ReleaseMutex()
    $widgetMutex.Dispose()
}
