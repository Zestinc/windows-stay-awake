$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RuntimeProbe {
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    public static extern bool Read(uint action, uint param, out uint value, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    public static extern bool Write(uint action, uint param, IntPtr value, uint flags);
}
'@
function Read-Spi([uint32]$action) {
    [uint32]$v = 0
    if (-not [RuntimeProbe]::Read($action, 0, [ref]$v, 0)) { throw "SPI read failed: $action" }
    return $v
}
function Write-Spi([uint32]$action, [uint32]$value) {
    if (-not [RuntimeProbe]::Write($action, $value, [IntPtr]::Zero, 0)) { throw "SPI write failed: $action" }
}
$originalActive = Read-Spi 0x10
$originalTimeout = Read-Spi 0x0E
$originalSecure = Read-Spi 0x76
$desktop = 'HKCU:\Control Panel\Desktop'
$originalReg = @{}
foreach ($n in @('ScreenSaveActive','ScreenSaveTimeOut')) {
    $key = Get-Item $desktop
    $originalReg[$n] = @{ Exists = $key.GetValueNames() -contains $n; Value = $key.GetValue($n) }
}
$pristine = "$env:ProgramData\StayAwake\backup-pristine.json"
if (Test-Path $pristine) { throw 'Regression test requires a pristine runner' }
try {
    Write-Spi 0x0F 300
    Write-Spi 0x11 1
    New-ItemProperty $desktop -Name ScreenSaveActive -Value '0' -PropertyType String -Force | Out-Null
    New-ItemProperty $desktop -Name ScreenSaveTimeOut -Value '0' -PropertyType String -Force | Out-Null
    if ((Read-Spi 0x10) -ne 1 -or (Read-Spi 0x0E) -ne 300) { throw 'Stale runtime fixture was not established' }
    Write-Host 'Stale runtime fixture: registry=0 runtime=1/300 OK'
    ./StayAwake.ps1 -Status
    if ($LASTEXITCODE -ne 0) { throw 'Status failed' }
    if ((Read-Spi 0x10) -ne 1 -or (Read-Spi 0x0E) -ne 300) { throw 'Status changed runtime' }
    foreach ($iteration in 1..2) {
        ./StayAwake.ps1
        if ($LASTEXITCODE -ne 0) { throw "Apply failed: $LASTEXITCODE" }
        if ((Read-Spi 0x10) -ne 0 -or (Read-Spi 0x0E) -ne 0) { throw 'Apply left stale runtime' }
        if ((Read-Spi 0x76) -ne $originalSecure) { throw 'Preset changed runtime authentication' }
    }
    $saved = Get-Content $pristine -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved.ScreenSaverRuntime.Active -ne 1 -or $saved.ScreenSaverRuntime.Timeout -ne 300) { throw 'Original runtime lost after repeat apply' }
    ./StayAwake.ps1 -Restore
    if ($LASTEXITCODE -ne 0) { throw "Restore failed: $LASTEXITCODE" }
    if ((Read-Spi 0x10) -ne 1 -or (Read-Spi 0x0E) -ne 300) { throw 'Runtime originals not restored' }
    foreach ($n in @('ScreenSaveActive','ScreenSaveTimeOut')) {
        if ((Get-ItemProperty $desktop).$n -ne '0') { throw 'Restore overwrote distinct registry original' }
    }
    Write-Host 'Stale runtime apply, repeat apply, independent restore, authentication preservation: OK'
} finally {
    Write-Spi 0x0F $originalTimeout
    Write-Spi 0x11 $originalActive
    foreach ($n in $originalReg.Keys) {
        if ($originalReg[$n].Exists) {
            New-ItemProperty $desktop -Name $n -Value $originalReg[$n].Value -PropertyType String -Force | Out-Null
        } else { Remove-ItemProperty $desktop -Name $n -ErrorAction SilentlyContinue }
    }
}
