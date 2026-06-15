<#
  android-verify.ps1 — MultiView Android 実機検証ヘルパー (Phase 0)
  使い方:
    .\tools\android-verify.ps1 build      # assembleDebug
    .\tools\android-verify.ps1 install     # 直近のAPKを実機へ -r install
    .\tools\android-verify.ps1 run         # build + install
    .\tools\android-verify.ps1 logcat      # 関連タグのlogcatを表示(Ctrl+Cで停止)
    .\tools\android-verify.ps1 shot [name] # スクショを artifacts/ へ取得
    .\tools\android-verify.ps1 clearlog    # logcatバッファ消去
#>
param(
  [Parameter(Position=0)][string]$cmd = "run",
  [Parameter(Position=1)][string]$arg = ""
)

$ErrorActionPreference = "Stop"
$Root      = Split-Path $PSScriptRoot                      # C:\Users\rinng\projects\APP
$AndroidDir= Join-Path $Root "MultiView\android"
$Adb       = Join-Path $Root ".tools\android-sdk\platform-tools\adb.exe"
$JavaHome  = Join-Path $Root ".tools\jdk\jdk-17.0.19+10"
$Device    = "520ed290"
$Artifacts = Join-Path $Root "artifacts\baseline"
$Apk       = Join-Path $AndroidDir "app\build\outputs\apk\debug\app-debug.apk"

$env:JAVA_HOME = $JavaHome
$env:ANDROID_HOME = Join-Path $Root ".tools\android-sdk"
$env:PATH = "$JavaHome\bin;" + $env:PATH

function Invoke-Gradle([string]$task) {
  Push-Location $AndroidDir
  try { & "$AndroidDir\gradlew.bat" $task "-Dorg.gradle.java.home=$JavaHome" }
  finally { Pop-Location }
}

switch ($cmd) {
  "build"   { Invoke-Gradle ":app:assembleDebug" }
  "install" { & $Adb -s $Device install -r $Apk }
  "run"     { Invoke-Gradle ":app:assembleDebug"; & $Adb -s $Device install -r $Apk }
  "logcat"  { & $Adb -s $Device logcat -v time ReactNativeJS:V ReactNative:V ExoPlayerImpl:V MultiView:V AndroidRuntime:E "*:S" }
  "clearlog"{ & $Adb -s $Device logcat -c; Write-Output "logcat cleared" }
  "shot"    {
    if (-not (Test-Path $Artifacts)) { New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null }
    $name = if ($arg) { $arg } else { "shot-" + (Get-Date -Format "yyyyMMdd-HHmmss") }
    $remote = "/sdcard/$name.png"; $local = Join-Path $Artifacts "$name.png"
    & $Adb -s $Device shell screencap -p $remote
    & $Adb -s $Device pull $remote $local
    & $Adb -s $Device shell rm $remote
    Write-Output "saved: $local"
  }
  default   { Write-Output "unknown cmd: $cmd (build|install|run|logcat|shot|clearlog)" }
}
