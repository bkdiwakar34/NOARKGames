# Install the exported Android APK with adb, launch it, and tail useful logs.
param(
    [string]$ApkPath = "android/export/noark.apk",
    [string]$PackageName = "com.example.noarkgames",
    [string]$DeviceSerial = "",
    [switch]$NoInstall,
    [switch]$RawLogcat
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
}

function Get-AdbDeviceSerial {
    param([string]$RequestedSerial)

    if ($RequestedSerial) {
        return $RequestedSerial
    }

    $deviceLines = & adb devices |
        Select-Object -Skip 1 |
        Where-Object { $_ -match "^\S+\s+device$" }

    if ($deviceLines.Count -eq 0) {
        throw "No adb device detected. Connect a tablet/emulator and confirm 'adb devices' shows it as 'device'."
    }

    if ($deviceLines.Count -gt 1) {
        $serials = $deviceLines | ForEach-Object { ($_ -split "\s+")[0] }
        throw "Multiple adb devices detected. Re-run with -DeviceSerial. Found: $($serials -join ', ')"
    }

    return ($deviceLines[0] -split "\s+")[0]
}

function Invoke-Adb {
    param(
        [string]$Serial,
        [string[]]$Arguments
    )

    if ($Serial) {
        & adb -s $Serial @Arguments
    } else {
        & adb @Arguments
    }
}

$null = Get-Command adb -ErrorAction Stop

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $repoRoot

$resolvedApk = Join-Path $repoRoot $ApkPath
if (-not $NoInstall -and -not (Test-Path $resolvedApk)) {
    throw "APK not found at '$resolvedApk'"
}

$serial = Get-AdbDeviceSerial -RequestedSerial $DeviceSerial
Write-Host "Using adb target: $serial" -ForegroundColor Cyan

if (-not $NoInstall) {
    Write-Host "Installing APK: $resolvedApk" -ForegroundColor Cyan
    Invoke-Adb -Serial $serial -Arguments @("install", "-r", $resolvedApk)
}

Write-Host "Clearing previous logcat buffer..." -ForegroundColor Cyan
Invoke-Adb -Serial $serial -Arguments @("logcat", "-c")

Write-Host "Launching package: $PackageName" -ForegroundColor Cyan
Invoke-Adb -Serial $serial -Arguments @("shell", "monkey", "-p", $PackageName, "-c", "android.intent.category.LAUNCHER", "1")

Start-Sleep -Seconds 3
$appPid = Invoke-Adb -Serial $serial -Arguments @("shell", "pidof", "-s", $PackageName) 2>$null
if ($appPid) {
    Write-Host "App PID: $appPid" -ForegroundColor Green
} else {
    Write-Host "App PID not found after launch. It may have exited immediately." -ForegroundColor Yellow
}

Write-Host "Tailing logcat. Press Ctrl+C to stop." -ForegroundColor Cyan

if ($RawLogcat) {
    Invoke-Adb -Serial $serial -Arguments @("logcat", "-v", "time")
} else {
    $pattern = "godot|AndroidRuntime|libc|DEBUG|linker|nativehelper|SecurityException|$PackageName|gdble|panic|FATAL"
    Invoke-Adb -Serial $serial -Arguments @("logcat", "-v", "time") | Select-String -Pattern $pattern
}
