[CmdletBinding()]
param(
    [string]$Tag = '',
    [string]$IpaPath = '',
    [string]$Repo = 'tonton888115/MultiView'
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$pbxPath = Join-Path $root 'MultiView\ios\MultiView.xcodeproj\project.pbxproj'
$pbxText = Get-Content -Path $pbxPath -Raw
$marketing = [regex]::Match($pbxText, 'MARKETING_VERSION\s*=\s*([0-9][0-9.]*)').Groups[1].Value
$buildNum = [regex]::Match($pbxText, 'CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)').Groups[1].Value
if ([string]::IsNullOrEmpty($marketing) -or [string]::IsNullOrEmpty($buildNum)) {
    throw 'MARKETING_VERSION / CURRENT_PROJECT_VERSION を project.pbxproj から取得できませんでした'
}

if ([string]::IsNullOrEmpty($Tag)) {
    $Tag = "v$marketing-b$buildNum"
}

if ([string]::IsNullOrEmpty($IpaPath)) {
    $IpaPath = Join-Path $root "artifacts\MultiView-$marketing-b$buildNum.ipa"
}

if (-not (Test-Path -LiteralPath $IpaPath)) {
    throw "IPA not found: $IpaPath"
}

$title = "MultiView $marketing (build $buildNum)"
$notes = "Unsigned IPA for sideload use with SideStore + LiveContainer."

$oldNativePreference = $null
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
    $global:PSNativeCommandUseErrorActionPreference = $false
}
$oldErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$existing = & gh release view $Tag --repo $Repo --json tagName 2>$null
$viewExitCode = $LASTEXITCODE
$ErrorActionPreference = $oldErrorPreference
if ($null -ne $oldNativePreference) {
    $global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
}

if ($viewExitCode -eq 0 -and $existing) {
    Write-Host "Updating existing release: $Tag"
    & gh release upload $Tag $IpaPath --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) { throw "gh release upload failed" }
} else {
    Write-Host "Creating release: $Tag"
    & gh release create $Tag $IpaPath --repo $Repo --title $title --notes $notes
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
}

Write-Host "Release URL: https://github.com/$Repo/releases/tag/$Tag"
