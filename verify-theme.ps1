$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Theme.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected $Expected; got $Actual)" }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (!$threw) { throw $Message }
}
function Assert-Theme($Actual, $Expected, [string]$Message) {
    Assert-Equal $Actual.Count 3 "${Message}: key count"
    foreach ($key in @('Background', 'Foreground', 'Accent')) {
        Assert-Equal $Actual[$key] $Expected[$key] "$Message $key"
    }
}

$root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.verify-theme-' + [Guid]::NewGuid().ToString('N')
$temporaryRoot = Join-Path $root $folderName
$null = [System.IO.Directory]::CreateDirectory($temporaryRoot)
try {
    $defaults = Get-DefaultTheme
    $independent = Get-DefaultTheme
    $independent.Background = '#FFFFFF'
    Assert-Equal (Get-DefaultTheme).Background '#263F43' 'Default themes must be independent'
    Assert-Equal (ConvertTo-ThemeColor ' #a3F ') '#AA33FF' 'Short color expansion'
    Assert-Equal (ConvertTo-ThemeColor 'abcdef') '#ABCDEF' 'Optional hash and uppercase'
    foreach ($invalid in @('', '#12', '#1234', '#12345678', 'red', '#GGGGGG', '##abc', $null, 123456)) {
        $value = $invalid
        Assert-Throws { ConvertTo-ThemeColor $value } 'Invalid colors must be rejected'
    }
    $sample = @{ Background = 'fff'; Foreground = '#123'; Accent = '#f06' }
    $expected = @{ Background = '#FFFFFF'; Foreground = '#112233'; Accent = '#FF0066' }
    Assert-Theme (Get-NormalizedTheme $sample) $expected 'Normalize dictionary'
    Assert-Theme (Get-NormalizedTheme ([pscustomobject]$sample)) $expected 'Normalize JSON object'
    Assert-Equal $sample.Background 'fff' 'Normalization must not mutate input'
    Assert-Throws { Get-NormalizedTheme $null } 'Null themes must be rejected'
    Assert-Throws { Get-NormalizedTheme @{ Background = '#fff'; Foreground = '#000' } } 'Missing keys must be rejected'
    Assert-Throws { Get-NormalizedTheme @{ Background = '#fff'; Foreground = '#000'; Other = '#aaa' } } 'Unknown keys must be rejected'
    Assert-Throws { Get-NormalizedTheme @{ Background = '#fff'; Foreground = '#000'; Accent = '#aaa'; Other = '#bbb' } } 'Extra keys must be rejected'
    Assert-Throws { Get-NormalizedTheme @{ Background = '#fff'; Foreground = 'bad color'; Accent = '#aaa' } } 'Invalid theme colors must be rejected'

    $path = Join-Path $temporaryRoot 'theme.json'
    Assert-Theme (Read-Theme $path) $defaults 'Missing file fallback'
    foreach ($invalidJson in @('{ invalid json', '{"Background":"#fff"}', '{"Background":"#fff","Foreground":"#000","Accent":"red"}', 'null', '[]')) {
        [System.IO.File]::WriteAllText($path, $invalidJson, [System.Text.Encoding]::UTF8)
        Assert-Theme (Read-Theme $path) $defaults 'Invalid file fallback'
    }
    [System.IO.File]::Delete($path)
    Save-Theme $sample $path
    Assert-Theme (Read-Theme $path) $expected 'Create and persist normalized theme'
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert-Equal ($bytes[0..2] -join ',') '239,187,191' 'Persisted JSON UTF-8 BOM'
    Save-Theme $defaults $path
    Assert-Theme (Read-Theme $path) $defaults 'Atomic replacement roundtrip'
    $previous = [System.IO.File]::ReadAllText($path)
    Assert-Throws { Save-Theme @{ Background = '#fff' } $path } 'Invalid theme cannot overwrite saved file'
    Assert-Equal ([System.IO.File]::ReadAllText($path)) $previous 'Previous file preserved on validation failure'
    Assert-Equal @(Get-ChildItem -LiteralPath $temporaryRoot -Filter '.theme-*.tmp' -Force).Count 0 'No temporary files remain'

    $dark = Get-ThemePalette @{ Background = '#000'; Foreground = '#fff'; Accent = '#0f0' }
    $light = Get-ThemePalette @{ Background = '#fff'; Foreground = '#000'; Accent = '#00f' }
    Assert-Equal $dark.Surface '#1A1A1A' 'Dark surface blend'
    Assert-Equal $dark.Border '#3D3D3D' 'Dark border blend'
    Assert-Equal $dark.Divider '#242424' 'Dark divider blend'
    Assert-Equal $dark.Muted '#A6A6A6' 'Dark muted blend'
    Assert-Equal $light.Surface '#E6E6E6' 'Light surface blend'
    Assert-Equal $light.Border '#C2C2C2' 'Light border blend'
    Assert-Equal $light.Divider '#DBDBDB' 'Light divider blend'
    Assert-Equal $light.Muted '#595959' 'Light muted blend'
    Assert-Equal $dark.Accent '#00FF00' 'Palette keeps accent'
    Assert-Equal $light.Foreground '#000000' 'Palette keeps foreground'
    Assert-Equal $dark.Count 7 'Palette key count'
    Write-Output 'PASS: theme validation, fallback, atomic JSON persistence, and light/dark palettes.'
}
finally {
    $resolvedTarget = [System.IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\')
    $resolvedParent = [System.IO.Path]::GetDirectoryName($resolvedTarget)
    if ($resolvedParent -cne $root -or [System.IO.Path]::GetFileName($resolvedTarget) -cne $folderName -or $resolvedTarget -ceq $root) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}
