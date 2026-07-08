<#
  Galaxy Z Fold 7 install helper for MultiView.

  Usage:
    .\tools\android-zfold7.ps1 build    # build debug APK only
    .\tools\android-zfold7.ps1 install  # install existing debug APK to Z Fold 7
    .\tools\android-zfold7.ps1 run      # build, then install to Z Fold 7

  The script maps this repo to a short temporary drive before running Gradle.
  That avoids Windows/CMake 260-character path failures in React Native prefab
  headers.
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet("build", "install", "run", "devices")]
  [string]$Command = "run"
)

$ErrorActionPreference = "Stop"

$Root = Split-Path $PSScriptRoot
$PreferredModel = "SM_F966Z"

function New-ShortRepoDrive {
  foreach ($letter in @("X", "W", "V", "U")) {
    $drive = "${letter}:"
    if (-not (Test-Path "$drive\")) {
      & subst $drive $Root
      return @{ Drive = $drive; Created = $true }
    }
  }
  return @{ Drive = $Root; Created = $false }
}

function Remove-ShortRepoDrive($mapping) {
  if ($mapping.Created) {
    & subst $mapping.Drive /D
  }
}

function Get-ZFoldSerial($adb) {
  $devices = & $adb devices -l
  $match = $devices | Where-Object { $_ -match "\bdevice\b" -and $_ -match "model:$PreferredModel\b" } | Select-Object -First 1
  if (-not $match) {
    return $null
  }
  return ($match -split "\s+")[0]
}

$mapping = New-ShortRepoDrive
try {
  $ShortRoot = $mapping.Drive
  $AndroidDir = Join-Path $ShortRoot "MultiView\android"
  $JavaHome = Join-Path $ShortRoot ".tools\jdk\jdk-17.0.19+10"
  $AndroidHome = Join-Path $ShortRoot ".tools\android-sdk"
  $GradleHome = Join-Path $ShortRoot ".tools\g"
  $Adb = Join-Path $AndroidHome "platform-tools\adb.exe"
  $Apk = Join-Path $AndroidDir "app\build\outputs\apk\debug\app-debug.apk"

  New-Item -ItemType Directory -Force -Path $GradleHome | Out-Null
  $env:JAVA_HOME = $JavaHome
  $env:ANDROID_HOME = $AndroidHome
  $env:GRADLE_USER_HOME = $GradleHome
  $env:PATH = "$JavaHome\bin;" + $env:PATH
  # SUBSTドライブ上でもMetroバンドル(release)を実パスCWDで実行させる。
  # JavaのtoRealPath()はSUBSTを解決しないため、実パスはここから明示的に渡す
  # (app/build.gradle の react.root が参照)。無いとreleaseバンドルがSHA-1エラーで失敗。
  $env:MULTIVIEW_REPO_REAL_ROOT = $Root

  if ($Command -eq "devices") {
    & $Adb devices -l
    exit $LASTEXITCODE
  }

  if ($Command -eq "build" -or $Command -eq "run") {
    Push-Location $AndroidDir
    try {
      & "$AndroidDir\gradlew.bat" :app:assembleDebug --no-daemon --console=plain "-Dorg.gradle.java.home=$JavaHome"
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
      Pop-Location
    }
  }

  if ($Command -eq "install" -or $Command -eq "run") {
    if (-not (Test-Path $Apk)) {
      throw "Debug APK not found: $Apk"
    }
    $serial = Get-ZFoldSerial $Adb
    if (-not $serial) {
      throw "Z Fold 7 ($PreferredModel) is not connected. Connect it and rerun: .\tools\android-zfold7.ps1 install"
    }
    & $Adb -s $serial install -r $Apk
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Output "Installed MultiView debug APK to $PreferredModel ($serial)."
  }
} finally {
  Remove-ShortRepoDrive $mapping
}
