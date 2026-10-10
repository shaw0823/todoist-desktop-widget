$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.wallpaper-ui-test-' + [Guid]::NewGuid().ToString('N')
$testDirectory = Join-Path $root $folderName
$null = [IO.Directory]::CreateDirectory($testDirectory)
$window = $null

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (!$threw) { throw $Message }
}
function Assert-Background($Actual, $Expected, [string]$Message) {
    Assert-Equal $Actual.Count 4 "${Message}: key count"
    foreach ($key in @('Mode', 'ImagePath', 'Opacity', 'Overlay')) {
        Assert-Equal $Actual[$key] $Expected[$key] "$Message $key"
    }
}
function Assert-ContentOpaque {
    Assert-Equal $window.Opacity 1.0 'Window opacity remains opaque'
    Assert-Equal $ui.Status.Opacity 1.0 'Status text opacity remains opaque'
    Assert-Equal $ui.Input.Opacity 1.0 'Task input opacity remains opaque'
    Assert-Equal $ui.Tasks.Opacity 1.0 'Task list opacity remains opaque'
    $taskLabel = $ui.Tasks.Children[0].Child.Children[1]
    Assert-Equal $taskLabel.Opacity 1.0 'Task text opacity remains opaque'
    Assert-Equal $taskLabel.Text 'Synthetic wallpaper test task' 'Task content is retained'
    Assert-Equal $ui.BackgroundLayer.IsHitTestVisible $false 'Background does not intercept clicks'
    if ($ui.BackgroundLayer.Opacity -eq 0) { Assert-TransparentDragRegion }
}
function Assert-TransparentDragRegion {
    $window.UpdateLayout()
    Assert-Equal $ui.Header.Background.Color.A 1 'Header retains nonzero alpha for native hit testing'
    Assert-Equal $ui.Header.Opacity 1.0 'Header is independent of transparent background layer'
    if (!(Test-HeaderDragSource $ui.Header) -or !(Test-HeaderDragSource $ui.Header.Children[0])) { throw 'Header or title is not draggable' }
    if (!(Test-HeaderDragSource $ui.Header.Children[0].Inlines.FirstInline)) { throw 'Title inline is not draggable' }
    foreach ($button in @($ui.MenuButton,$ui.Pin,$ui.Refresh,$ui.Close)) {
        $button.ApplyTemplate() | Out-Null
        if (Test-HeaderDragSource $button) { throw 'Header button incorrectly starts dragging' }
        if (Test-HeaderDragSource ([Windows.Media.VisualTreeHelper]::GetChild($button,0))) { throw 'Button template incorrectly starts dragging' }
    }
    if (Test-HeaderDragSource $ui.Input) { throw 'Task input incorrectly starts dragging' }

    # Render only the generated fixture's header to prove its blank pixels have alpha.
    $width = [int][Math]::Ceiling($ui.Header.ActualWidth)
    $height = [int][Math]::Ceiling($ui.Header.ActualHeight)
    $visual = [Windows.Media.DrawingVisual]::new()
    $drawing = $visual.RenderOpen()
    try { $drawing.DrawRectangle([Windows.Media.VisualBrush]::new($ui.Header),$null,[Windows.Rect]::new(0,0,$width,$height)) }
    finally { $drawing.Close() }
    $rendered = [Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $rendered.Render($visual)
    $x = [int][Math]::Floor($ui.Header.ColumnDefinitions[0].ActualWidth - 3)
    $y = [int][Math]::Floor($height / 2)
    $pixel = [byte[]]::new(4)
    $rendered.CopyPixels([Windows.Int32Rect]::new($x,$y,1,1),$pixel,4,0)
    if ($pixel[3] -eq 0) { throw 'Header blank area still lets native mouse input pass through' }
}
function Invoke-TestButton($Dialog, [string]$Name) {
    $button = $Dialog.FindName($Name)
    if (!$button -or !$button.IsEnabled) { throw "Button $Name is missing or disabled." }
    $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}
function Test-WallpaperDialog([string]$Mode) {
    $testTimer = [Windows.Threading.DispatcherTimer]::new()
    $testTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $testTimer.Tag = @{ Mode = $Mode; Failure = $null; Completed = $false; Attempts = 0 }
    $testTimer.Add_Tick({
        $state = $this.Tag
        $state.Attempts++
        $dialog = @($window.OwnedWindows | Where-Object { $_.Title -eq '外观设置' }) | Select-Object -First 1
        if (!$dialog) {
            if ($state.Attempts -gt 30) { $this.Stop(); throw 'Appearance dialog did not open.' }
            return
        }
        $this.Stop()
        try {
            switch ($state.Mode) {
                'TransparentCancel' {
                    Assert-Equal $dialog.FindName('BackgroundMode').SelectedIndex 1 'Original wallpaper mode appears in dialog'
                    Assert-Equal $dialog.FindName('WallpaperName').ToolTip $fixturePath 'Original wallpaper path appears in dialog'
                    $dialog.FindName('BackgroundColor').Text = '#123456'
                    Invoke-TestButton $dialog 'MakeTransparent'
                    Assert-Equal $script:backgroundSettings.Mode 'Color' 'Transparent preview switches to color mode'
                    Assert-Equal $ui.BackgroundLayer.Opacity 0.0 'Transparent preview affects background immediately'
                    Assert-Equal $ui.WidgetFrame.BorderBrush.Opacity 0.0 'Transparent preview hides frame border'
                    Assert-Equal $dialog.FindName('OpacityValue').Text '0%' 'Opacity label updates'
                    Assert-ContentOpaque
                    $dialog.DialogResult = $false
                }
                'WallpaperSave' {
                    Assert-Equal $dialog.FindName('BackgroundMode').SelectedIndex 1 'Wallpaper mode is retained after cancel'
                    $dialog.FindName('BackgroundOpacity').Value = 40
                    $dialog.FindName('WallpaperOverlayAmount').Value = 70
                    $dialog.FindName('BackgroundColor').Text = '#103050'
                    Assert-Equal $ui.BackgroundLayer.Opacity 0.4 'Opacity slider previews immediately'
                    Assert-Equal $ui.WallpaperOverlay.Opacity 0.7 'Overlay slider previews immediately'
                    Assert-Equal $dialog.FindName('OpacityValue').Text '40%' 'Opacity percent label'
                    Assert-Equal $dialog.FindName('OverlayValue').Text '70%' 'Overlay percent label'
                    Assert-Equal $dialog.FindName('WallpaperOverlayAmount').IsEnabled $true 'Wallpaper enables overlay slider'
                    Assert-ContentOpaque
                    Invoke-TestButton $dialog 'SaveColors'
                    if ($dialog.IsVisible) { throw 'Wallpaper save did not close dialog.' }
                }
                'ClearCancel' {
                    Invoke-TestButton $dialog 'ClearWallpaper'
                    Assert-Equal $script:backgroundSettings.ImagePath '' 'Clear preview removes selected image path'
                    Assert-Equal $dialog.FindName('BackgroundMode').SelectedIndex 0 'Clear preview switches mode'
                    Assert-Equal $dialog.FindName('WallpaperOverlayAmount').IsEnabled $false 'Color mode disables overlay slider'
                    $dialog.FindName('BackgroundOpacity').Value = 80
                    $dialog.DialogResult = $false
                }
                'ClearSave' {
                    Invoke-TestButton $dialog 'ClearWallpaper'
                    $dialog.FindName('BackgroundOpacity').Value = 85
                    Assert-Equal $ui.WallpaperOverlay.Visibility ([Windows.Visibility]::Collapsed) 'Clear preview hides overlay'
                    if ($ui.BackgroundFill.Background -isnot [Windows.Media.SolidColorBrush]) { throw 'Clear preview did not restore a color brush.' }
                    Invoke-TestButton $dialog 'SaveColors'
                    if ($dialog.IsVisible) { throw 'Clear save did not close dialog.' }
                }
                'TransparentSave' {
                    Invoke-TestButton $dialog 'MakeTransparent'
                    Assert-ContentOpaque
                    Invoke-TestButton $dialog 'SaveColors'
                    if ($dialog.IsVisible) { throw 'Transparent save did not close dialog.' }
                }
                default { throw 'Unknown test dialog action.' }
            }
            $state.Completed = $true
        }
        catch {
            $state.Failure = $_
            $dialog.Close()
        }
    })
    $testTimer.Start()
    try { Configure-Theme } finally { $testTimer.Stop() }
    if ($testTimer.Tag.Failure) { throw $testTimer.Tag.Failure }
    if (!$testTimer.Tag.Completed) { throw 'Appearance dialog action did not run.' }
}

try {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start.ps1'))
    foreach ($module in 'Runtime.ps1', 'Theme.ps1', 'Background.ps1', 'Calendar.ps1', 'FollowSettings.ps1','WindowPosition.ps1','ClockSettings.ps1','DisplaySettings.ps1') {
        $modulePath = (Join-Path $PSScriptRoot $module).Replace("'", "''")
        $source = $source.Replace(". (Join-Path `$PSScriptRoot '$module')", ". '$modulePath'")
    }
    $source = $source.Replace('$widgetMutex = Enter-WidgetMutex $widgetMutexName', '$widgetMutex = Enter-WidgetMutex ($widgetMutexName + "-wallpaper-ui-test")')
    $source = $source.Replace('if (Test-WidgetOpen) { return }', '')
    $realDataAssignment = "`$dataDir = Join-Path `$env:LOCALAPPDATA 'TodoistDesktopWidget'"
    if (!$source.Contains($realDataAssignment)) { throw 'Cannot isolate widget settings directory.' }
    $fixtureDataPath = $testDirectory.Replace("'", "''")
    $fixtureTokenPath = (Join-Path $testDirectory 'token.dat').Replace("'", "''")
    $source = $source.Replace($realDataAssignment, "`$dataDir = '$fixtureDataPath'")
    $source = $source.Replace("`$tokenPath = Join-Path `$dataDir 'token.dat'", "`$tokenPath = '$fixtureTokenPath'")
    $source = $source.Replace('Todoist 桌面小组件', 'Todoist 壁纸测试')
    $source = $source.Replace('$window.ShowDialog() | Out-Null', '$timer.Stop(); $poll.Stop()')
    Invoke-Expression $source
    Assert-Equal $script:token '' 'Isolated fixture has no Todoist token'
    Assert-Equal $dataDir $testDirectory 'Settings directory is isolated'
    Assert-Equal $tokenPath (Join-Path $testDirectory 'token.dat') 'Token path is isolated'
    $window.Topmost = $false
    $window.Show()

    # Generate a synthetic 4 by 2 pixel PNG; no user image is read.
    $fixturePath = Join-Path $testDirectory 'synthetic-wallpaper.png'
    $pixels = [byte[]]@(
        40, 70, 220, 255, 40, 70, 220, 255, 190, 150, 30, 255, 190, 150, 30, 255,
        190, 150, 30, 255, 190, 150, 30, 255, 40, 70, 220, 255, 40, 70, 220, 255
    )
    $syntheticBitmap = [Windows.Media.Imaging.BitmapSource]::Create(4, 2, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $pixels, 16)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($syntheticBitmap))
    $fixtureStream = [IO.File]::Open($fixturePath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $encoder.Save($fixtureStream) } finally { $fixtureStream.Dispose() }
    $sourceBefore = [IO.File]::ReadAllBytes($fixturePath) -join ','
    $initialTheme = Get-DefaultTheme
    $initialBackground = @{ Mode = 'Image'; ImagePath = $fixturePath; Opacity = 0.65; Overlay = 0.35 }
    Apply-Theme $initialTheme
    Apply-Background $initialBackground -Strict
    if ($ui.BackgroundFill.Background -isnot [Windows.Media.ImageBrush]) { throw 'Wallpaper did not create an ImageBrush.' }
    Assert-Equal $ui.BackgroundFill.Background.Stretch ([Windows.Media.Stretch]::UniformToFill) 'Wallpaper fills component without distortion'
    Assert-Equal $ui.BackgroundFill.Background.ImageSource.IsFrozen $true 'Wallpaper bitmap is frozen'
    if ($ui.BackgroundFill.Background.ImageSource.PixelWidth -le 0 -or $ui.BackgroundFill.Background.ImageSource.PixelHeight -le 0) { throw 'Wallpaper bitmap has no pixels.' }
    $cachedBitmap = $ui.BackgroundFill.Background.ImageSource
    if (![object]::ReferenceEquals($cachedBitmap, (Get-WallpaperBitmap $fixturePath))) { throw 'Wallpaper preview did not reuse cached bitmap.' }
    $exclusiveStream = [IO.File]::Open($fixturePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $exclusiveStream.Dispose()
    Assert-Equal $ui.WallpaperOverlay.Visibility ([Windows.Visibility]::Visible) 'Wallpaper enables tint overlay'
    Assert-Equal $ui.BackgroundLayer.Opacity 0.65 'Configured background opacity applied'
    Assert-Equal $ui.WallpaperOverlay.Opacity 0.35 'Configured tint amount applied'
    Assert-Equal $window.AllowsTransparency $true 'Widget supports transparent background'
    Assert-Equal $window.Background.Color.A 0 'Window itself has transparent background'
    $script:cachedTasks = @([pscustomobject]@{ id = 'synthetic-task'; content = 'Synthetic wallpaper test task'; due = @{ date = $script:date.ToString('yyyy-MM-dd') }; order = 0 })
    Render-Tasks
    Assert-ContentOpaque

    Test-WallpaperDialog 'TransparentCancel'
    Assert-Background $script:backgroundSettings $initialBackground 'Cancel restores wallpaper and opacity'
    Assert-Equal $script:theme.Background $initialTheme.Background 'Cancel restores color preview'
    Assert-Equal $ui.BackgroundLayer.Opacity 0.65 'Cancel restores visible wallpaper opacity'
    if ($ui.BackgroundFill.Background -isnot [Windows.Media.ImageBrush]) { throw 'Cancel did not restore image brush.' }
    if ([IO.File]::Exists($themePath) -or [IO.File]::Exists($backgroundPath)) { throw 'Cancel wrote settings.' }

    Test-WallpaperDialog 'WallpaperSave'
    $savedWallpaper = @{ Mode = 'Image'; ImagePath = $fixturePath; Opacity = 0.4; Overlay = 0.7 }
    Assert-Background (Read-BackgroundSettings $backgroundPath) $savedWallpaper 'Wallpaper settings persist from UI'
    Assert-Equal (Read-Theme $themePath).Background '#103050' 'Tint color persists from UI'
    Assert-Equal $ui.WallpaperOverlay.Background.Color.ToString() '#FF103050' 'Tint uses current background color'
    Assert-Equal ([IO.File]::ReadAllBytes($fixturePath) -join ',') $sourceBefore 'UI save does not modify image source'
    $savedJson = [IO.File]::ReadAllText($backgroundPath)
    Test-WallpaperDialog 'ClearCancel'
    Assert-Background $script:backgroundSettings $savedWallpaper 'Clear cancel restores wallpaper settings'
    Assert-Equal ([IO.File]::ReadAllText($backgroundPath)) $savedJson 'Clear cancel leaves saved settings unchanged'

    Test-WallpaperDialog 'ClearSave'
    Assert-Background (Read-BackgroundSettings $backgroundPath) @{ Mode = 'Color'; ImagePath = ''; Opacity = 0.85; Overlay = 0.7 } 'Cleared wallpaper persists from UI'
    Apply-Background $initialBackground -Strict
    Test-WallpaperDialog 'TransparentSave'
    $savedTransparent = @{ Mode = 'Color'; ImagePath = $fixturePath; Opacity = 0.0; Overlay = 0.35 }
    Assert-Background (Read-BackgroundSettings $backgroundPath) $savedTransparent 'Transparent settings persist from UI'
    Apply-Theme (Read-Theme $themePath)
    Apply-Background (Read-BackgroundSettings $backgroundPath)
    Assert-Equal $ui.BackgroundLayer.Opacity 0.0 'Reload preserves transparent background'
    Assert-ContentOpaque

    $missingBackground = @{ Mode = 'Image'; ImagePath = (Join-Path $testDirectory 'missing.png'); Opacity = 0.25; Overlay = 0.8 }
    Apply-Background $missingBackground
    if ($ui.BackgroundFill.Background -isnot [Windows.Media.SolidColorBrush]) { throw 'Missing wallpaper did not fall back to color.' }
    Assert-Equal $ui.WallpaperOverlay.Visibility ([Windows.Visibility]::Collapsed) 'Missing wallpaper hides tint layer'
    Assert-Equal $ui.BackgroundLayer.Opacity 0.25 'Missing wallpaper fallback preserves opacity'
    Assert-Background $script:backgroundSettings $missingBackground 'Missing file preserves selected path for future retry'
    $strictMissing = @{ Mode = 'Image'; ImagePath = $missingBackground.ImagePath; Opacity = 0.9; Overlay = 0.1 }
    Assert-Throws { Apply-Background $strictMissing -Strict } 'Strict preview rejects missing image'
    Assert-Background $script:backgroundSettings $missingBackground 'Failed strict preview preserves previous settings'
    Assert-Equal $ui.BackgroundLayer.Opacity 0.25 'Failed strict preview preserves previous display'
    $invalidImage = Join-Path $testDirectory 'invalid.png'
    [IO.File]::WriteAllBytes($invalidImage, [byte[]]@(0, 1, 2, 3))
    $invalidBackground = @{ Mode = 'Image'; ImagePath = $invalidImage; Opacity = 0.5; Overlay = 0.5 }
    Assert-Throws { Apply-Background $invalidBackground -Strict } 'Strict preview rejects undecodable image'
    Apply-Background $invalidBackground
    if ($ui.BackgroundFill.Background -isnot [Windows.Media.SolidColorBrush]) { throw 'Undecodable wallpaper did not fall back to color.' }
    Assert-Equal ([IO.File]::ReadAllBytes($fixturePath) -join ',') $sourceBefore 'Image fixture unchanged by all previews'
    Write-Output 'PASS: wallpaper and transparency persistence, missing-image fallback, and transparent header pixels/drag targets/button exclusions.'
}
finally {
    if ($window) { $window.Close() }
    $resolvedTarget = [IO.Path]::GetFullPath($testDirectory).TrimEnd('\')
    $resolvedParent = [IO.Path]::GetDirectoryName($resolvedTarget)
    if ($resolvedParent -cne $root -or [IO.Path]::GetFileName($resolvedTarget) -cne $folderName -or $resolvedTarget -ceq $root) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}
