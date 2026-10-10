$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowPosition.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Assert-Position($Actual, [int]$Left, [int]$Top, [string]$Message) {
    Assert-Equal ($Actual -is [hashtable]) $true "$Message returns a hashtable"
    Assert-Equal $Actual.Left $Left "$Message left"
    Assert-Equal $Actual.Top $Top "$Message top"
    Assert-Equal ($Actual.Left -is [int]) $true "$Message left is an integer"
    Assert-Equal ($Actual.Top -is [int]) $true "$Message top is an integer"
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    if (!$thrown) { throw $Message }
}

$primary = @{ Left = 0; Top = 0; Width = 1920; Height = 1040 }
$secondary = [pscustomobject]@{ Left = -1920; Top = -120; Width = 1920; Height = 1080 }
Assert-Position (Get-VisibleWindowPosition 400 200 400 460 @($primary)) 400 200 'Visible position is preserved'
Assert-Position (Get-VisibleWindowPosition -1800 -80 400 460 @($primary, $secondary)) -1800 -80 'Negative-coordinate secondary screen'
Assert-Position (Get-VisibleWindowPosition -200 100 500 460 @($primary, $secondary)) 0 100 'Largest overlap selects primary screen'
Assert-Position (Get-VisibleWindowPosition -400 100 500 460 @($primary, $secondary)) -500 100 'Largest overlap selects secondary screen'
Assert-Position (Get-VisibleWindowPosition -1800 -80 400 460 @($primary)) 0 0 'Unplugged secondary screen falls back to primary'
Assert-Position (Get-VisibleWindowPosition 2200 1300 400 460 @($primary)) 1520 580 'Bottom taskbar and right edge are respected'
Assert-Position (Get-VisibleWindowPosition 0 0 400 460 @(@{ Left = 48; Top = 30; Width = 1872; Height = 1010 })) 48 30 'Left and top taskbars are respected'
Assert-Position (Get-VisibleWindowPosition 200 100 2400 1400 @($primary)) 0 0 'Oversized windows retain a reachable top-left'
Assert-Position (Get-VisibleWindowPosition 200 100 1920 1040 @($primary)) 0 0 'Exact work-area-sized window'
Assert-Position (Get-VisibleWindowPosition 4000 1600 400 460 @($primary, @{ Left = 2560; Top = 0; Width = 1920; Height = 1040 })) 4000 580 'Nearest screen is chosen across a monitor gap'
Assert-Position (Get-VisibleWindowPosition 0 -1800 400 460 @($primary, @{ Left = 0; Top = -1080; Width = 1920; Height = 1080 })) 0 -1080 'Nearest vertically stacked screen'
Assert-Position (Get-VisibleWindowPosition 123 234 400 460 @($null, @{ Left = 0; Top = 0; Width = 0; Height = 1040 }, @{ Left = '0'; Top = 0; Width = 1920; Height = 1040 })) 123 234 'Invalid screens are ignored'
Assert-Position (Get-VisibleWindowPosition 123 234 400 460 @()) 123 234 'No screen data preserves the requested position'
Assert-Throws { Get-VisibleWindowPosition 0 0 0 460 @($primary) } 'Nonpositive window width must be rejected'

$testRoot = Join-Path $PSScriptRoot ('.window-position-test-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
$path = Join-Path $testRoot 'position.json'
try {
    Assert-Equal (Read-WindowPosition $path) $null 'Missing cache safely defaults'
    Save-WindowPosition @{ Left = -1800; Top = -80; Views = @{ List = @{Width=435.5; Height=510}; Calendar = @{Width=825; Height=745} }; Unrelated = 'must not be saved' } $path
    $first = Read-WindowPosition $path
    Assert-Position $first -1800 -80 'First save/read round-trip'
    Assert-Equal $first.Views.List.Width 435.5 'List width persists independently'
    Assert-Equal $first.Views.List.Height 510.0 'List height persists independently'
    Assert-Equal $first.Views.Calendar.Width 825.0 'Calendar width persists independently'
    Assert-Equal $first.Views.Calendar.Height 745.0 'Calendar height persists independently'
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert-Equal (($bytes[0..2] | ForEach-Object { $_.ToString('X2') }) -join '') 'EFBBBF' 'JSON retains UTF-8 BOM'
    $saved = ConvertFrom-Json ([System.IO.File]::ReadAllText($path))
    Assert-Equal ((@($saved.PSObject.Properties.Name) | Sort-Object) -join ',') 'Left,Top,Views' 'Only placement fields are persisted'
    Save-WindowPosition ([pscustomobject]@{ Left = 640.0; Top = 220 }) $path
    Assert-Position (Read-WindowPosition $path) 640 220 'Atomic replacement round-trip'
    $beforeFailure = [System.IO.File]::ReadAllText($path)
    foreach ($invalid in @($null, @{}, @{ Left = 0 }, @{ Left = '123'; Top = 0 }, @{ Left = $true; Top = 0 }, @{ Left = 1.5; Top = 0 }, @{ Left = [double]::NaN; Top = 0 }, @{ Left = [double]::PositiveInfinity; Top = 0 }, @{ Left = [int]::MaxValue; Top = 0 }, @{ Left = 0; Top = -1000001 })) {
        Assert-Throws { Save-WindowPosition $invalid $path } 'Invalid position must not be saved'
        Assert-Equal ([System.IO.File]::ReadAllText($path)) $beforeFailure 'Invalid save preserves previous cache'
    }
    foreach ($badViews in @('invalid', @{List=@{Width='400';Height=460}}, @{List=@{Width=[double]::NaN;Height=460}}, @{List=@{Width=400;Height=0}}, @{List=@{Width=400;Height=10001}})) {
        Assert-Throws { Save-WindowPosition @{Left=640;Top=220;Views=$badViews} $path } 'Invalid view sizes must not be saved'
        Assert-Equal ([System.IO.File]::ReadAllText($path)) $beforeFailure 'Invalid size preserves previous cache'
    }
    # Deny deletion/replacement while allowing reads; a failed atomic save must preserve the old file.
    $locked = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { Assert-Throws { Save-WindowPosition @{ Left = 900; Top = 400 } $path } 'A locked destination must fail without truncation' }
    finally { $locked.Dispose() }
    Assert-Equal ([System.IO.File]::ReadAllText($path)) $beforeFailure 'Failed replacement preserves the old complete file'
    Assert-Equal @(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp' -Force).Count 0 'Failed replacement cleans its temporary file'
    foreach ($invalidJson in @('', '{', 'null', '[]', '[1,2]', '{"Left":0}', '{"Left":"0","Top":10}', '{"Left":0.5,"Top":10}', '{"Left":0,"Top":1000001}', '{"Left":0,"Top":10,"Views":{"List":{"Width":0,"Height":460}}}', (' ' * 4097))) {
        [System.IO.File]::WriteAllText($path, $invalidJson, [System.Text.UTF8Encoding]::new($true))
        Assert-Equal (Read-WindowPosition $path) $null 'Malformed, invalid or oversized cache safely defaults'
    }
    [System.IO.File]::WriteAllText($path, '{"Left":-1000000,"Top":1000000}', [System.Text.UTF8Encoding]::new($true))
    Assert-Position (Read-WindowPosition $path) -1000000 1000000 'Coordinate limits remain accepted'
    Assert-Equal (Read-WindowPosition $path).Views.Count 0 'Older coordinate-only cache remains compatible'
}
finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\.window-position-test-'
    if (!$resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside the test directory.' }
    if ([System.IO.Directory]::Exists($resolvedTestRoot)) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
Write-Output 'PASS: position and per-view size persistence, validation, UTF-8 atomic saves, failed-write preservation, negative monitors and disconnected screens.'
