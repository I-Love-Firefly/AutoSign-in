param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceSerial
)

$flutterExe = 'D:/DevTools/flutter/bin/flutter.bat'
$productionPackage = 'com.xmum.attendance_assistant'
$qaPackage = 'com.xmum.attendance_assistant.qa'

function Get-ProductionInstallTime {
    $details = & adb -s $DeviceSerial shell dumpsys package $productionPackage
    $line = $details | Select-String 'firstInstallTime=' | Select-Object -First 1
    if ($null -eq $line) { throw 'Production app is not installed.' }
    return $line.Line.Trim()
}

$before = Get-ProductionInstallTime
$project = Split-Path -Parent $PSScriptRoot
Push-Location $project
try {
    & $flutterExe test integration_test/smoke_test.dart -d $DeviceSerial --flavor qa --no-uninstall
    if ($LASTEXITCODE -ne 0) { throw 'Device smoke test failed.' }

    & $flutterExe test integration_test/archive_crypto_test.dart -d $DeviceSerial --flavor qa --no-uninstall --plain-name 'native archive encryption survives transfer and rejects tampering'
    if ($LASTEXITCODE -ne 0) { throw 'Native archive crypto test failed.' }
} finally {
    Pop-Location
    & adb -s $DeviceSerial uninstall $qaPackage | Out-Null
    $after = Get-ProductionInstallTime
    if ($after -ne $before) {
        throw 'Production app installation changed during QA testing.'
    }
}
