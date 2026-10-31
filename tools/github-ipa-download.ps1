<#
  github-ipa-download.ps1 — GitHub Actions(.github/workflows/ios-ipa.yml)でビルドした iOS 未署名 IPA を
  取得し、artifacts\ と iCloud Drive の Downloads(ダウンロード)へ置く。tools/codemagic-build.ps1 の
  「ダウンロード→iCloud 配置」部分を GitHub Actions 用にしたもの。

  前提: GitHub CLI (gh) がインストール済みで `gh auth login` 済みであること。

  使い方:
    .\tools\github-ipa-download.ps1                   # 現在のブランチの最新ビルドを取得
    .\tools\github-ipa-download.ps1 -Wait             # ビルド中なら完了まで待ってから取得
    .\tools\github-ipa-download.ps1 -Branch main      # ブランチを指定
    .\tools\github-ipa-download.ps1 -RunId 123456789  # 実行IDを直接指定

  クラウドセッション(Claude)からのビルド要求は .github/ios-build-request を更新して push する。
  成果物の保存期間は1日なので、ビルド完了後は早めに取得すること。
#>
[CmdletBinding()]
param(
    [string]$Branch = '',
    [long]$RunId = 0,
    [string]$Repo = 'tonton888115/MultiView',
    [string]$Workflow = 'ios-ipa.yml',
    [string]$ArtifactName = 'MultiView-unsigned-ipa',
    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) not found. Install it from https://cli.github.com/ and run "gh auth login".'
}

function Invoke-Gh {
    param([string[]]$Arguments)
    $output = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
    return $output
}

function Get-RunState {
    param([long]$Id)
    $line = Invoke-Gh @('run', 'view', "$Id", '--repo', $Repo, '--json', 'status,conclusion,url,headBranch',
        '--jq', '[.status, .conclusion, .url, .headBranch] | @tsv')
    $fields = (($line | Out-String).Trim()) -split "`t"
    return [pscustomobject]@{ Status = $fields[0]; Conclusion = $fields[1]; Url = $fields[2]; Branch = $fields[3] }
}

if ($RunId -eq 0) {
    if ([string]::IsNullOrEmpty($Branch)) {
        $Branch = (& git -C $root rev-parse --abbrev-ref HEAD | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($Branch) -or $Branch -eq 'HEAD') {
            throw 'Could not determine the current branch. Pass -Branch <name>.'
        }
    }
    $latest = Invoke-Gh @('run', 'list', '--repo', $Repo, '--workflow', $Workflow, '--branch', $Branch, '--limit', '1',
        '--json', 'databaseId', '--jq', 'if length == 0 then empty else .[0].databaseId end')
    $latestText = ($latest | Out-String).Trim()
    if ([string]::IsNullOrEmpty($latestText)) {
        throw "No iOS build found for branch '$Branch'. Update .github/ios-build-request and push to start one."
    }
    $RunId = [long]$latestText
}

$state = Get-RunState -Id $RunId
Write-Host "Run $RunId ($($state.Branch)): $($state.Status) $($state.Conclusion)"
Write-Host "url: $($state.Url)"

if ($state.Status -ne 'completed') {
    if (-not $Wait) {
        throw "The build is still running. Re-run with -Wait to wait for it, or try again later."
    }
    # gh run watch はビルドの進行を表示し、完了まで待つ(失敗時の判定は下で行う)。
    & gh run watch "$RunId" --repo $Repo --interval 30
    $state = Get-RunState -Id $RunId
}

if ($state.Conclusion -ne 'success') {
    throw "The build did not succeed (conclusion=$($state.Conclusion)). See $($state.Url)"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("multiview-ipa-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    Invoke-Gh @('run', 'download', "$RunId", '--repo', $Repo, '--name', $ArtifactName, '--dir', $tmp) | Out-Null
    $ipa = Get-ChildItem -Path $tmp -Filter '*.ipa' -Recurse | Select-Object -First 1
    if (-not $ipa) {
        throw "No IPA in artifact '$ArtifactName' of run $RunId"
    }
    $outDir = Join-Path $root 'artifacts'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    # 新しいワークフローは MultiView-<版数>-b<ビルド番号>.ipa を作る。旧形式(MultiView.ipa)の時だけ実行IDで区別する。
    $leaf = if ($ipa.Name -eq 'MultiView.ipa') { "MultiView-run$RunId.ipa" } else { $ipa.Name }
    $Output = Join-Path $outDir $leaf
    Copy-Item -LiteralPath $ipa.FullName -Destination $Output -Force
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
$sizeMB = [math]::Round((Get-Item -LiteralPath $Output).Length / 1MB, 2)
Write-Host "Saved: $Output ($sizeMB MB)"

# iCloud の Downloads は環境により日本語名「ダウンロード」になり、しかも NFD(分解形)で保存されることがある。
# 文字コードの違いで化けないよう、名前は文字番号から組み立てて Unicode 正規化して照合する
# (tools/codemagic-build.ps1 と同じ配置規則)。
$icloudRoot = Join-Path $env:USERPROFILE 'iCloudDrive'
$downloadsJa = -join [char[]](0x30C0, 0x30A6, 0x30F3, 0x30ED, 0x30FC, 0x30C9)
$icloudDir = $null
if (Test-Path $icloudRoot) {
    $dl = Get-ChildItem $icloudRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'Downloads' -or $_.Name.Normalize([Text.NormalizationForm]::FormC) -eq $downloadsJa
    } | Select-Object -First 1
    if ($dl) { $icloudDir = $dl.FullName }
}
if ($icloudDir) {
    $icloudPath = Join-Path $icloudDir $leaf
    $tmpPath = Join-Path $icloudDir "$leaf.uploading"
    Copy-Item -LiteralPath $Output -Destination $tmpPath -Force
    Move-Item -LiteralPath $tmpPath -Destination $icloudPath -Force
    (Get-Item -LiteralPath $icloudPath).LastWriteTime = Get-Date
    Write-Host "Mirrored to iCloud: $icloudPath"
    # 古い MultiView*.ipa は消し、最新の1つだけ残す(同名/旧版キャッシュ事故の防止)。
    Get-ChildItem $icloudDir -Filter 'MultiView*.ipa' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $leaf } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Write-Host "Removed old: $($_.Name)" }
} else {
    Write-Warning "iCloud Drive Downloads folder not found under $icloudRoot; skipped mirror."
}
