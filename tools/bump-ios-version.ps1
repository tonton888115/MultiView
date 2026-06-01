[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+(\.\d+)*$')]
    [string]$MarketingVersion,

    [int]$BuildNumber
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$projectPath = Join-Path $repoRoot 'MultiView\ios\MultiView.xcodeproj\project.pbxproj'
$text = [System.IO.File]::ReadAllText($projectPath)

$versionMatches = [regex]::Matches($text, 'MARKETING_VERSION\s*=\s*[0-9][0-9.]*;')
$buildMatches = [regex]::Matches($text, 'CURRENT_PROJECT_VERSION\s*=\s*\d+;')
if ($versionMatches.Count -eq 0 -or $buildMatches.Count -eq 0) {
    throw 'MARKETING_VERSION / CURRENT_PROJECT_VERSION was not found in project.pbxproj'
}

if (-not $PSBoundParameters.ContainsKey('BuildNumber')) {
    $firstBuild = [regex]::Match($text, 'CURRENT_PROJECT_VERSION\s*=\s*(\d+);')
    $BuildNumber = [int]$firstBuild.Groups[1].Value + 1
}

$text = [regex]::Replace($text, 'MARKETING_VERSION\s*=\s*[0-9][0-9.]*;', "MARKETING_VERSION = $MarketingVersion;")
$text = [regex]::Replace($text, 'CURRENT_PROJECT_VERSION\s*=\s*\d+;', "CURRENT_PROJECT_VERSION = $BuildNumber;")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($projectPath, $text, $utf8NoBom)

Write-Host "iOS version set to $MarketingVersion ($BuildNumber)"
