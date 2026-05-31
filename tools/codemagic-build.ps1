[CmdletBinding()]
param(
    [string]$AppId      = '6a15829322edf308d423b90f',
    [string]$WorkflowId = 'ios-unsigned-ipa',
    [string]$Branch     = 'main',
    [string]$Output     = '',
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

# IPAファイル名にビルド版数を付与する（同名キャッシュ衝突＝「入れたのに更新されない」を防ぐ）。
if ([string]::IsNullOrEmpty($Output)) {
    $pbxPath = Join-Path $PSScriptRoot '..\MultiView\ios\MultiView.xcodeproj\project.pbxproj'
    $pbxText = Get-Content -Path $pbxPath -Raw
    $marketing = [regex]::Match($pbxText, 'MARKETING_VERSION\s*=\s*([0-9][0-9.]*)').Groups[1].Value
    $buildNum  = [regex]::Match($pbxText, 'CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)').Groups[1].Value
    if ([string]::IsNullOrEmpty($marketing) -or [string]::IsNullOrEmpty($buildNum)) {
        throw "MARKETING_VERSION / CURRENT_PROJECT_VERSION を project.pbxproj から取得できませんでした"
    }
    $ipaName = "MultiView-$marketing-b$buildNum.ipa"
    $Output  = Join-Path $PSScriptRoot "..\artifacts\$ipaName"
    Write-Host "Versioned IPA name: $ipaName"
}

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
# curl.exe を使う: 成果物URLは api.codemagic.io（要 x-auth-token）→ S3 プリサインURL へ
# クロスホスト301する。Invoke-WebRequest は x-auth-token を S3 にも転送してしまい署名auth
# が壊れ ExpiredToken/Forbidden になる。curl -L はクロスホスト時に認証ヘッダを落とすので正しい。
& curl.exe -sS -L --fail -H "x-auth-token: $token" -o $Output $ipa.url
if ($LASTEXITCODE -ne 0) { throw "IPA download failed (curl exit $LASTEXITCODE)" }
$sizeMB = [math]::Round((Get-Item $Output).Length / 1MB, 2)
Write-Host "Saved: $Output ($sizeMB MB)"

$icloudDir = Join-Path $env:USERPROFILE 'iCloudDrive\Downloads'
if (Test-Path $icloudDir) {
    $icloudPath = Join-Path $icloudDir (Split-Path -Path $Output -Leaf)
    Copy-Item -Path $Output -Destination $icloudPath -Force
    Write-Host "Mirrored to iCloud: $icloudPath"
    # 紛らわしいバージョン無しの旧ファイルは消す（同名キャッシュの元）。
    $staleGeneric = Join-Path $icloudDir 'MultiView.ipa'
    if (Test-Path $staleGeneric) { Remove-Item $staleGeneric -Force; Write-Host "Removed stale: $staleGeneric" }
} else {
    Write-Warning "iCloud Drive Downloads not found at $icloudDir; skipped mirror."
}
