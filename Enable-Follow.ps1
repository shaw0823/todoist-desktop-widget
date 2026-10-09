$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime.ps1')
. (Join-Path $PSScriptRoot 'FollowSettings.ps1')
Set-FollowEnabled $true
Write-Output 'Todoist follow mode enabled.'
