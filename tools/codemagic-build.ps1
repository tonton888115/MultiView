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

# iCloud の Downloads は再起動等で日本語ローカライズ名 'ダウンロード' に化けることがあり、
# しかも NFD(分解形)で保存されるため 'ダウンロード'(NFC)直書きでは一致しない。実体を列挙し
# Unicode 正規化して照合する。
$icloudRoot = Join-Path $env:USERPROFILE 'iCloudDrive'
$icloudDir = $null
if (Test-Path $icloudRoot) {
    $dlName = [string]'ダウンロード'
    $dl = Get-ChildItem $icloudRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'Downloads' -or $_.Name.Normalize([Text.NormalizationForm]::FormC) -eq $dlName.Normalize([Text.NormalizationForm]::FormC)
    } | Select-Object -First 1
    if ($dl) { $icloudDir = $dl.FullName }
}
if ($icloudDir) {
    $leaf = Split-Path -Path $Output -Leaf
    $icloudPath = Join-Path $icloudDir $leaf
    $tmpPath = Join-Path $icloudDir "$leaf.uploading"
    Copy-Item -Path $Output -Destination $tmpPath -Force
    Move-Item -Path $tmpPath -Destination $icloudPath -Force
    (Get-Item -LiteralPath $icloudPath).LastWriteTime = Get-Date
    Write-Host "Mirrored to iCloud: $icloudPath"
    # 古い MultiView*.ipa は全部消し、最新の1つだけ残す（同名/旧版キャッシュ事故の根絶）。
    Get-ChildItem $icloudDir -Filter 'MultiView*.ipa' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $leaf } |
        ForEach-Object { Remove-Item $_.FullName -Force; Write-Host "Removed old: $($_.Name)" }
} else {
    Write-Warning "iCloud Drive Downloads/ダウンロード folder not found under $icloudRoot; skipped mirror."
}
