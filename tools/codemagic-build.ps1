[CmdletBinding()]
param(
    [string]$AppId      = '6a15829322edf308d423b90f',
    [string]$WorkflowId = 'ios-unsigned-ipa',
    [string]$Branch     = 'main',
    [string]$Output     = (Join-Path $PSScriptRoot '..\artifacts\MultiView.ipa'),
    [int]$PollSeconds   = 20,
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'

$tokenPath = Join-Path $env:USERPROFILE '.codemagic\token'
if (-not (Test-Path $tokenPath)) {
    throw "Codemagic token not found at $tokenPath. Save it there first."
}
$token = (Get-Content -Path $tokenPath -Raw).Trim()
$headers = @{ 'x-auth-token' = $token }
$jsonHeaders = $headers + @{ 'Content-Type' = 'application/json' }

Write-Host "Triggering build: app=$AppId workflow=$WorkflowId branch=$Branch"
$body = @{ appId = $AppId; workflowId = $WorkflowId; branch = $Branch } | ConvertTo-Json
$start = Invoke-RestMethod -Uri 'https://api.codemagic.io/builds' -Method Post -Headers $jsonHeaders -Body $body
$buildId = $start.buildId
Write-Host "buildId: $buildId"
Write-Host "url: https://codemagic.io/app/$AppId/build/$buildId"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastStatus = ''
$build = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSeconds
    $r = Invoke-RestMethod -Uri "https://api.codemagic.io/builds/$buildId" -Headers $headers
    $build = $r.build
    if ($build.status -ne $lastStatus) {
        Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $build.status)
        $lastStatus = $build.status
    }
    if ($build.status -in @('finished','failed','canceled','warning','timeout','skipped')) { break }
}

if ($null -eq $build -or $build.status -ne 'finished') {
    throw "Build did not finish cleanly. status=$($build.status)"
}

$ipa = $build.artefacts | Where-Object { $_.name -like '*.ipa' } | Select-Object -First 1
if (-not $ipa) { throw "No IPA artifact in build $buildId" }

$outDir = Split-Path -Path $Output -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

Write-Host "Downloading IPA from $($ipa.url)"
Invoke-WebRequest -Uri $ipa.url -OutFile $Output -Headers $headers
$sizeMB = [math]::Round((Get-Item $Output).Length / 1MB, 2)
Write-Host "Saved: $Output ($sizeMB MB)"
