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
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Todoist 桌面小组件" Width="400" Height="460" MinWidth="340" MinHeight="240" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" ShowInTaskbar="False" Background="Transparent" Foreground="#E2ECEC" Topmost="True">
 <Window.Resources>
  <Style TargetType="Button"><Setter Property="Background" Value="#36555B"/><Setter Property="Foreground" Value="#D8E6E8"/><Setter Property="BorderBrush" Value="#557176"/><Setter Property="Padding" Value="6,3"/><Setter Property="Margin" Value="2"/></Style>
 </Window.Resources>
 <Grid>
 <Border Background="#263F43" BorderBrush="#557176" BorderThickness="1" CornerRadius="10" Padding="10">
  <DockPanel>
   <StackPanel DockPanel.Dock="Top">
    <Grid x:Name="Header" Background="Transparent" Margin="0,0,0,8">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <TextBlock Text="☀ Todoist" FontWeight="Bold" VerticalAlignment="Center"/>
     <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="Settings" Content="⚙" ToolTip="连接 Todoist"/><Button x:Name="Pin" Content="📌" ToolTip="切换置顶" Background="#6C5797"/><Button x:Name="Refresh" Content="↻" ToolTip="刷新"/><Button x:Name="Close" Content="×" ToolTip="关闭" Foreground="#FF8585"/></StackPanel>
    </Grid>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,8"><Button x:Name="Previous" Content="‹"/><Button x:Name="Day" Content="今天"/><Button x:Name="Next" Content="›"/></StackPanel>
    <TextBox x:Name="Input" Background="#365055" Foreground="#E2ECEC" BorderBrush="#557176" Padding="9" Margin="0,0,0,8" ToolTip="输入任务内容，回车添加到当前日期"/>
   </StackPanel>
   <TextBlock x:Name="Status" DockPanel.Dock="Bottom" Foreground="#9BB7BB" TextWrapping="Wrap" Margin="0,8,0,0" FontSize="11"/>
   <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Tasks"/></ScrollViewer>
  </DockPanel>
 </Border>
 <Thumb x:Name="ResizeHandle" Width="15" Height="15" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,3,3" Cursor="SizeNWSE" ToolTip="拖动调整大小">
  <Thumb.Template><ControlTemplate TargetType="Thumb"><Grid Background="Transparent"><Path Data="M 5,12 L 12,5 M 9,12 L 12,9" Stroke="#739094" StrokeThickness="1"/></Grid></ControlTemplate></Thumb.Template>
 </Thumb>
 </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
'Header','Settings','Pin','Refresh','Close','Previous','Day','Next','Input','Status','Tasks','ResizeHandle' | ForEach-Object { $ui[$_] = $window.FindName($_) }
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
    $state.Label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#70D7C3')
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
            $border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#3B575B')
            $border.BorderThickness = '0,0,0,1'; $border.Padding='2,10,2,10'
            $row = New-Object Windows.Controls.DockPanel
            $check = New-Object Windows.Controls.CheckBox
            $check.Margin='0,2,10,0'; $check.ToolTip='完成任务并同步到 Todoist'
            $check.Add_Click({ Animate-Complete $this })
            $row.Children.Add($check) | Out-Null
            $label = New-Object Windows.Controls.TextBlock
            $label.Text=$task.content; $label.TextWrapping='Wrap'; $label.FontSize=13
            $check.Tag=@{Id=$task.id; Border=$border; Label=$label; Check=$check}
            $row.Children.Add($label) | Out-Null
            $border.Child=$row; $ui.Tasks.Children.Add($border) | Out-Null
        }
        $ui.Status.Text = "共 $($items.Count) 项 · 同步于 $([DateTime]::Now.ToString('HH:mm')) · 每分钟刷新"
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
$ui.Header.Add_MouseLeftButtonDown({ if ($_.OriginalSource -is [Windows.Controls.TextBlock] -or $_.OriginalSource -eq $ui.Header) { $window.DragMove() } })
$ui.Settings.Add_Click({ Configure })
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
                    $state.Label.Foreground=$window.Foreground
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
