$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Background.ps1')

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

$root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$folderName = '.verify-background-' + [Guid]::NewGuid().ToString('N')
$temporaryRoot = Join-Path $root $folderName
$null = [System.IO.Directory]::CreateDirectory($temporaryRoot)
try {
    $defaults = Get-DefaultBackground
    Assert-Background $defaults @{ Mode = 'Color'; ImagePath = ''; Opacity = 1.0; Overlay = 0.45 } 'Default values'
    $independent = Get-DefaultBackground
    $independent.Mode = 'Image'
    $independent.Opacity = 0.2
    Assert-Background (Get-DefaultBackground) $defaults 'Fresh default instances'
    Assert-Background (Get-NormalizedBackground $defaults) $defaults 'Dictionary normalization'
    Assert-Background (Get-NormalizedBackground ([pscustomobject]$defaults)) $defaults 'JSON object normalization'
    Assert-Background (Get-NormalizedBackground ([ordered]@{ Mode = 'Color'; ImagePath = ''; Opacity = 1; Overlay = 0 })) @{ Mode = 'Color'; ImagePath = ''; Opacity = 1.0; Overlay = 0.0 } 'Boundary values and ordered dictionary'

    $sourcePath = Join-Path $temporaryRoot 'source.bin'
    $sample = @{ Mode = 'Image'; ImagePath = $sourcePath; Opacity = 0.75; Overlay = 0.25 }
    $normalized = Get-NormalizedBackground $sample
    Assert-Background $normalized $sample 'Nonexistent local path allowed'
    $normalized.Opacity = 0.1
    Assert-Equal $sample.Opacity 0.75 'Normalization must not mutate input'
    foreach ($localPath in @('C:\missing\image.png', 'D:/missing/image.png', '\\server\share\image.png', '\\server\share', '//server/share/image.png')) {
        $candidate = @{ Mode = 'Image'; ImagePath = $localPath; Opacity = 1; Overlay = 0 }
        Assert-Equal (Get-NormalizedBackground $candidate).ImagePath $localPath 'Drive and UNC path accepted without file access'
    }
    foreach ($invalidPath in @('', ' ', 'image.png', '.\image.png', '\image.png', 'C:image.png', 'https://example.com/image.png', 'HTTP://example.com/image.png', 'file:///C:/image.png', '\\server', '\\server\', '\\?\C:\image.png', 123, $null)) {
        $candidate = @{ Mode = 'Image'; ImagePath = $invalidPath; Opacity = 1; Overlay = 0 }
        Assert-Throws { Get-NormalizedBackground $candidate } 'Invalid image path must be rejected'
    }
    foreach ($invalidMode in @('Wallpaper', 'image', 'color', '', 1, $null)) {
        $candidate = @{ Mode = $invalidMode; ImagePath = $sourcePath; Opacity = 1; Overlay = 0 }
        Assert-Throws { Get-NormalizedBackground $candidate } 'Invalid mode must be rejected'
    }
    foreach ($key in @('Opacity', 'Overlay')) {
        foreach ($invalidAmount in @(-0.01, 1.01, [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity, '0.5', '1', $true, $null)) {
            $candidate = Get-DefaultBackground
            $candidate[$key] = $invalidAmount
            Assert-Throws { Get-NormalizedBackground $candidate } 'Invalid amount must be rejected'
        }
    }
    Assert-Throws { Get-NormalizedBackground $null } 'Null object must be rejected'
    Assert-Throws { Get-NormalizedBackground 'Color' } 'Scalar settings must be rejected'
    Assert-Throws { Get-NormalizedBackground @{ Mode = 'Color'; ImagePath = ''; Opacity = 1 } } 'Missing field must be rejected'
    Assert-Throws { Get-NormalizedBackground @{ Mode = 'Color'; ImagePath = ''; Opacity = 1; Extra = 0 } } 'Unknown field must be rejected'
    Assert-Throws { Get-NormalizedBackground @{ Mode = 'Color'; ImagePath = ''; Opacity = 1; Overlay = 0; Extra = 1 } } 'Extra field must be rejected'
    Assert-Throws { Get-NormalizedBackground @{ mode = 'Color'; ImagePath = ''; Opacity = 1; Overlay = 0 } } 'Field names must match exactly'
    Assert-Throws { Get-NormalizedBackground @{ Mode = 'Color'; ImagePath = $null; Opacity = 1; Overlay = 0 } } 'Color image path must still be a string'

    $path = Join-Path $temporaryRoot 'background.json'
    Assert-Background (Read-BackgroundSettings $path) $defaults 'Missing settings fallback'
    foreach ($invalidJson in @('{ invalid json', '{"Mode":"Color"}', '{"Mode":"Image","ImagePath":"relative.png","Opacity":1,"Overlay":0}', '{"Mode":"Color","ImagePath":"","Opacity":"1","Overlay":0}', '{"Mode":"Color","ImagePath":"","Opacity":1,"Overlay":2}', 'null', '[]')) {
        [System.IO.File]::WriteAllText($path, $invalidJson, [System.Text.Encoding]::UTF8)
        Assert-Background (Read-BackgroundSettings $path) $defaults 'Corrupt or invalid settings fallback'
    }
    [System.IO.File]::Delete($path)
    # A binary fixture proves persistence saves only the path and never modifies source data.
    $fixture = [byte[]]@(0, 1, 2, 3, 254, 255)
    [System.IO.File]::WriteAllBytes($sourcePath, $fixture)
    $sourceBefore = [System.IO.File]::ReadAllBytes($sourcePath) -join ','
    Save-BackgroundSettings $sample $path
    Assert-Background (Read-BackgroundSettings $path) $sample 'Create settings roundtrip'
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert-Equal ($bytes[0..2] -join ',') '239,187,191' 'JSON contains UTF-8 BOM'
    Assert-Equal ([System.IO.File]::ReadAllBytes($sourcePath) -join ',') $sourceBefore 'Source data remains unchanged'
    Save-BackgroundSettings $defaults $path
    Assert-Background (Read-BackgroundSettings $path) $defaults 'Atomic replacement roundtrip'
    Assert-Equal ([System.IO.File]::ReadAllBytes($sourcePath) -join ',') $sourceBefore 'Replacing settings does not alter source data'
    $previous = [System.IO.File]::ReadAllText($path)
    Assert-Throws { Save-BackgroundSettings @{ Mode = 'Image' } $path } 'Invalid settings cannot overwrite file'
    Assert-Equal ([System.IO.File]::ReadAllText($path)) $previous 'Validation failure preserves previous file'
    Assert-Equal @(Get-ChildItem -LiteralPath $temporaryRoot -Filter '.background-*.tmp' -Force).Count 0 'No temporary files remain'
    $nestedPath = Join-Path (Join-Path $temporaryRoot 'nested') 'background.json'
    Save-BackgroundSettings $defaults $nestedPath
    Assert-Background (Read-BackgroundSettings $nestedPath) $defaults 'Parent directory created'
    Write-Output 'PASS: background validation, fallback, independent defaults, atomic UTF-8 JSON create/replace, and source preservation.'
}
finally {
    $resolvedTarget = [System.IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\')
    $resolvedParent = [System.IO.Path]::GetDirectoryName($resolvedTarget)
    if ($resolvedParent -cne $root -or [System.IO.Path]::GetFileName($resolvedTarget) -cne $folderName -or $resolvedTarget -ceq $root) {
        throw 'Refusing cleanup outside the exact test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}
