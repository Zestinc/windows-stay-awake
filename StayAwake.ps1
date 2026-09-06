#Requires -Version 5.1
<#
.SYNOPSIS
    关闭 Windows 的全部自动休眠 / 自动关屏 / 自动锁屏，让机器保持唤醒并持续显示当前界面。

.DESCRIPTION
    默认动作是 Apply：先把每一项的原值备份成 JSON，再写入，最后逐项读回验证。
    读回不一致会以非零退出码失败，不会只打印“已完成”。

    分两层，安全边界不会被静默降低：
      预设层（默认）     : 只关“自动发生”的行为——超时关屏、睡眠、休眠、屏保、
                           无人值守睡眠、锁屏后关显示、不活动自动锁定、动态锁。
      -DisableLockScreen : 额外降低认证强度——唤醒不要密码、屏保恢复不要密码、
                           关掉锁屏界面、禁用 Win+L。必须显式指定。

.PARAMETER Status
    只读。打印当前所有相关项的实际值，不做任何修改。不需要管理员。

.PARAMETER Restore
    从备份 JSON 回滚。不指定 -BackupFile 时使用最近一次备份。

.PARAMETER Guard
    前台常驻，持续声明 ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED。
    用于压制“策略/应用把设置改回去”或 Modern Standby 上超时不生效的情况。
    Ctrl+C 退出后系统立即恢复正常空闲计时。

.PARAMETER DisableLockScreen
    见上。会改变这台机器的物理安全性，请确认场景后再用。

.PARAMETER BackupFile
    配合 -Restore 指定要回滚的备份文件；配合 Apply 指定备份写出位置。

.EXAMPLE
    .\StayAwake.ps1
    应用预设层并验证。

.EXAMPLE
    .\StayAwake.ps1 -Status
    只看当前状态。

.EXAMPLE
    .\StayAwake.ps1 -Restore
    回滚到最近一次备份。
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Guard')]
    [switch]$Guard,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$DisableLockScreen,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Restore')]
    [string]$BackupFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:StateDir = Join-Path $env:ProgramData 'StayAwake'

# --------------------------------------------------------------------------
# 电源设置 GUID（语言无关；powercfg 的文字输出会随系统语言变化，不能用来解析）
# --------------------------------------------------------------------------
$script:SUB_VIDEO = '7516b95f-f776-4464-8c53-06167f40cc99'
$script:SUB_SLEEP = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$script:SUB_DISK  = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$script:SUB_NONE  = 'fea3413e-88d6-4123-a466-e9f8b03e494d'

$script:PowerSettings = @(
    @{ Key = 'VideoIdle';      Sub = $script:SUB_VIDEO; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Label = '空闲后关闭显示器';       Target = 0; Tier = 'preset' }
    @{ Key = 'VideoConLock';   Sub = $script:SUB_VIDEO; Setting = '8ec4b3a5-6868-48c2-be75-4f3044be88a7'; Label = '锁屏后关闭显示器';       Target = 0; Tier = 'preset' }
    @{ Key = 'StandbyIdle';    Sub = $script:SUB_SLEEP; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Label = '空闲后进入睡眠';         Target = 0; Tier = 'preset' }
    @{ Key = 'HibernateIdle';  Sub = $script:SUB_SLEEP; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364'; Label = '空闲后休眠';             Target = 0; Tier = 'preset' }
    @{ Key = 'UnattendSleep';  Sub = $script:SUB_SLEEP; Setting = '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'; Label = '无人值守睡眠超时';       Target = 0; Tier = 'preset' }
    @{ Key = 'DiskIdle';       Sub = $script:SUB_DISK;  Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Label = '空闲后关闭硬盘';         Target = 0; Tier = 'preset' }
    @{ Key = 'ConsoleLock';    Sub = $script:SUB_NONE;  Setting = '0e796bdb-100d-47d6-a2d5-f7d2daa51f51'; Label = '唤醒时需要密码';         Target = 0; Tier = 'lockscreen' }
)

# --------------------------------------------------------------------------
# 注册表项
# HKCU 项在提权后会落到管理员账户，必须显式定位交互登录用户的 hive，
# 所以这里用 <USERHIVE> 占位，运行时替换成 HKEY_USERS\<登录用户 SID>。
# --------------------------------------------------------------------------
$script:RegSettings = @(
    @{ Key = 'ScreenSaveActive';    Path = '<USERHIVE>\Control Panel\Desktop';                                     Name = 'ScreenSaveActive';     Target = '0'; Type = 'String'; Label = '屏幕保护程序';         Tier = 'preset' }
    @{ Key = 'ScreenSaveTimeOut';   Path = '<USERHIVE>\Control Panel\Desktop';                                     Name = 'ScreenSaveTimeOut';    Target = '0'; Type = 'String'; Label = '屏保等待时间';         Tier = 'preset' }
    @{ Key = 'InactivityTimeout';   Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System';      Name = 'InactivityTimeoutSecs'; Target = 0;  Type = 'DWord';  Label = '不活动自动锁定';       Tier = 'preset' }
    @{ Key = 'DynamicLock';         Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsLogon';               Name = 'EnableGoodbye';        Target = 0;   Type = 'DWord';  Label = '动态锁（蓝牙走开即锁）'; Tier = 'preset' }
    @{ Key = 'ScreenSaverIsSecure'; Path = '<USERHIVE>\Control Panel\Desktop';                                     Name = 'ScreenSaverIsSecure';  Target = '0'; Type = 'String'; Label = '屏保恢复需要密码';     Tier = 'lockscreen' }
    @{ Key = 'NoLockScreen';        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization';            Name = 'NoLockScreen';         Target = 1;   Type = 'DWord';  Label = '锁屏界面';             Tier = 'lockscreen' }
    @{ Key = 'DisableLockWorkstation'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System';   Name = 'DisableLockWorkstation'; Target = 1; Type = 'DWord';  Label = '手动锁定 (Win+L)';     Tier = 'lockscreen' }
)

# ==========================================================================
# 基础设施
# ==========================================================================

function Test-Administrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InteractiveUserHive {
    <#
        返回 ('Registry::HKEY_USERS\<SID>', '<账户名>')。
        提权运行时 HKCU 指向管理员，写进去对真正在用这台机器的人无效。
    #>
    $userName = $null
    try {
        $userName = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    } catch {
        $userName = $null
    }

    if ([string]::IsNullOrWhiteSpace($userName)) {
        # 无人交互登录（例如仅 SSH 会话）：只能退回当前进程的 HKCU。
        return @('HKCU:', "$env:USERDOMAIN\$env:USERNAME (无交互登录会话，回落到当前用户)")
    }

    try {
        $account = New-Object System.Security.Principal.NTAccount($userName)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return @('HKCU:', "$userName (SID 解析失败，回落到当前用户)")
    }

    $hive = "Registry::HKEY_USERS\$sid"
    if (-not (Test-Path $hive)) {
        return @('HKCU:', "$userName (用户 hive 未加载，回落到当前用户)")
    }
    return @($hive, $userName)
}

function Resolve-RegPath {
    param([string]$Path, [string]$UserHive)
    return $Path.Replace('<USERHIVE>', $UserHive)
}

function Invoke-PowerCfg {
    <#
        统一的 powercfg 调用点。
        原生命令写 stderr 时，ErrorActionPreference='Stop' 会把它升级成终止异常，
        于是 $LASTEXITCODE 根本轮不到检查，错误信息也会退化成 NativeCommandError。
        这里把首选项临时降级，把退出码和原文一起交回调用方判断。
    #>
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powercfg @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{
        ExitCode = $code
        Output   = (($output | Out-String).Trim())
    }
}

function Get-HibernateEnabled {
    # 语言无关地读休眠开关；未知时返回 $null。
    $v = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
    if ($null -eq $v) { return $null }
    return [int]$v
}

function Set-HibernateBestEffort {
    <#
        休眠开关是“额外收紧”，不是达成目标的必要条件——超时全零已经杜绝了
        自动休眠。很多 VM 与部分 OEM 配置根本不支持它，那属于机器能力边界，
        不该让整次操作失败；但也不能静默吞掉，所以如实打印 powercfg 的原文。
    #>
    param([ValidateSet('on', 'off')][string]$State)

    $r = Invoke-PowerCfg -Arguments @('/hibernate', $State)
    if ($r.ExitCode -ne 0) {
        Write-Host ('  跳过休眠开关 ({0})：{1}' -f $State, $r.Output) -ForegroundColor DarkGray
        return $false
    }
    return $true
}

function Get-ActiveSchemeGuid {
    $r = Invoke-PowerCfg -Arguments @('/getactivescheme')
    $out = $r.Output
    if ($r.ExitCode -ne 0) { throw "powercfg /getactivescheme 失败: $out" }
    # GUID 格式与系统语言无关，直接从任意语言的输出里提取。
    $m = [regex]::Match(($out -join ' '), '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
    if (-not $m.Success) { throw "无法从 powercfg 输出中解析当前电源方案 GUID: $out" }
    return $m.Value
}

$script:SCHEME_BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'

function Read-SettingIndexes {
    param([string]$Path)
    $result = @{ AC = $null; DC = $null }
    if (-not (Test-Path $Path)) { return $result }
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $result }
    foreach ($side in @('AC', 'DC')) {
        $prop = "${side}SettingIndex"
        if ($item.PSObject.Properties.Name -contains $prop) {
            $result[$side] = [int]$item.$prop
        }
    }
    return $result
}

function Get-PowerValue {
    <#
        返回该设置项当前的“有效值”。

        直接读注册表而不是解析 powercfg 的文字输出——后者在中文系统上是中文的，
        按英文关键字解析会静默失配。

        方案键里没有这一项时并不代表“没有值”，而是沿用方案默认值。回滚要恢复的
        是机器的行为，不是注册表键的存在性——何况 powercfg 没有“取消设置”这个
        操作，删掉键之后 /setactive 会立刻把它重建。所以这里向下回落到默认值，
        Restore 再把这个有效值原样写回去。
    #>
    param([string]$Scheme, [string]$Sub, [string]$Setting)

    $schemePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$Scheme\$Sub\$Setting"
    $v = Read-SettingIndexes -Path $schemePath
    if ($null -ne $v.AC -and $null -ne $v.DC) {
        return @{ AC = $v.AC; DC = $v.DC; Source = 'scheme' }
    }

    # 回落：先查这个方案的默认值，自定义方案查不到时退回“平衡”模板。
    foreach ($src in @($Scheme, $script:SCHEME_BALANCED)) {
        $defPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$Sub\$Setting\DefaultPowerSchemeValues\$src"
        $d = Read-SettingIndexes -Path $defPath
        if ($null -ne $d.AC -or $null -ne $d.DC) {
            return @{
                AC     = $(if ($null -ne $v.AC) { $v.AC } else { $d.AC })
                DC     = $(if ($null -ne $v.DC) { $v.DC } else { $d.DC })
                Source = 'default'
            }
        }
    }

    return @{ AC = $v.AC; DC = $v.DC; Source = 'unknown' }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) { return $null }
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if ($item.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $item.$Name
}

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-RegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) { return }
    Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
}

function Format-Value {
    param($Value)
    if ($null -eq $Value) { return '(未设置)' }
    if ($Value -is [int] -and $Value -eq 0) { return '0 (从不)' }
    return [string]$Value
}

# ==========================================================================
# 状态收集
# ==========================================================================

function Get-CurrentState {
    param([switch]$IncludeLockScreen)

    $scheme = Get-ActiveSchemeGuid
    $hiveInfo = Get-InteractiveUserHive
    $userHive = $hiveInfo[0]
    $tiers = if ($IncludeLockScreen) { @('preset', 'lockscreen') } else { @('preset') }

    $items = New-Object System.Collections.ArrayList

    foreach ($s in $script:PowerSettings) {
        if ($tiers -notcontains $s.Tier) { continue }
        $v = Get-PowerValue -Scheme $scheme -Sub $s.Sub -Setting $s.Setting
        [void]$items.Add([pscustomobject]@{
            Kind = 'power'; Key = $s.Key; Label = $s.Label; Tier = $s.Tier
            Sub = $s.Sub; Setting = $s.Setting; Target = $s.Target
            AC = $v.AC; DC = $v.DC; Source = $v.Source
        })
    }

    foreach ($s in $script:RegSettings) {
        if ($tiers -notcontains $s.Tier) { continue }
        $path = Resolve-RegPath -Path $s.Path -UserHive $userHive
        [void]$items.Add([pscustomobject]@{
            Kind = 'registry'; Key = $s.Key; Label = $s.Label; Tier = $s.Tier
            Path = $path; Name = $s.Name; Type = $s.Type; Target = $s.Target
            Value = (Get-RegValue -Path $path -Name $s.Name)
        })
    }

    return [pscustomobject]@{
        Scheme            = $scheme
        UserHive          = $userHive
        UserAccount       = $hiveInfo[1]
        HibernateEnabled  = (Get-HibernateEnabled)
        Items             = $items
    }
}

function Show-Status {
    param([switch]$IncludeLockScreen)

    $state = Get-CurrentState -IncludeLockScreen:$IncludeLockScreen
    Write-Host ''
    Write-Host '当前状态' -ForegroundColor Cyan
    Write-Host ('  电源方案 : {0}' -f $state.Scheme)
    Write-Host ('  目标用户 : {0}' -f $state.UserAccount)
    $hib = if ($null -eq $state.HibernateEnabled) { '(不支持/未知)' } elseif ([int]$state.HibernateEnabled -eq 1) { '已启用' } else { '已关闭' }
    Write-Host ('  休眠功能 : {0}' -f $hib)
    Write-Host ''

    foreach ($item in $state.Items) {
        if ($item.Kind -eq 'power') {
            $ok = ($item.AC -eq $item.Target) -and ($item.DC -eq $item.Target)
            $mark = if ($ok) { '[OK]' } else { '[--]' }
            $color = if ($ok) { 'Green' } else { 'Yellow' }
            Write-Host ('  {0} {1,-22} 交流={2}  电池={3}' -f $mark, $item.Label, (Format-Value $item.AC), (Format-Value $item.DC)) -ForegroundColor $color
        } else {
            $ok = ([string]$item.Value -eq [string]$item.Target)
            $mark = if ($ok) { '[OK]' } else { '[--]' }
            $color = if ($ok) { 'Green' } else { 'Yellow' }
            Write-Host ('  {0} {1,-22} {2}' -f $mark, $item.Label, (Format-Value $item.Value)) -ForegroundColor $color
        }
    }
    Write-Host ''
}

# ==========================================================================
# Apply
# ==========================================================================

function Invoke-Apply {
    param([switch]$IncludeLockScreen, [string]$BackupPath)

    if (-not (Test-Administrator)) {
        throw '需要管理员权限。请用 StayAwake.cmd 启动，或在管理员 PowerShell 中运行。'
    }

    $before = Get-CurrentState -IncludeLockScreen:$IncludeLockScreen

    # ---- 1. 先备份，再改 ----
    if (-not (Test-Path $script:StateDir)) { New-Item -Path $script:StateDir -ItemType Directory -Force | Out-Null }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $BackupPath = Join-Path $script:StateDir "backup-$stamp.json"
    }
    $backup = [pscustomobject]@{
        CreatedAt         = (Get-Date).ToString('o')
        Scheme            = $before.Scheme
        UserHive          = $before.UserHive
        UserAccount       = $before.UserAccount
        HibernateEnabled  = $before.HibernateEnabled
        IncludeLockScreen = [bool]$IncludeLockScreen
        Items             = $before.Items
    }
    $backup | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupPath -Encoding UTF8
    Copy-Item -Path $BackupPath -Destination (Join-Path $script:StateDir 'backup-latest.json') -Force
    Write-Host ('已备份原值 -> {0}' -f $BackupPath) -ForegroundColor DarkGray

    # ---- 2. 写入 ----
    # 区分两种“没成功”：
    #   skipped — 这台机器不支持该设置项，属于能力边界，不阻止其余项生效。
    #   failure — 写进去了但读回不符，那是真问题（被策略覆盖或本脚本有 bug）。
    $scheme = $before.Scheme
    $skipped = New-Object System.Collections.ArrayList
    foreach ($item in $before.Items) {
        if ($item.Kind -eq 'power') {
            $ac = Invoke-PowerCfg -Arguments @('/setacvalueindex', $scheme, $item.Sub, $item.Setting, "$($item.Target)")
            $dc = Invoke-PowerCfg -Arguments @('/setdcvalueindex', $scheme, $item.Sub, $item.Setting, "$($item.Target)")
            if ($ac.ExitCode -ne 0 -or $dc.ExitCode -ne 0) {
                $msg = if ($ac.ExitCode -ne 0) { $ac.Output } else { $dc.Output }
                [void]$skipped.Add([pscustomobject]@{ Key = $item.Key; Label = $item.Label; Reason = $msg })
            }
        } else {
            Set-RegValue -Path $item.Path -Name $item.Name -Value $item.Target -Type $item.Type
        }
    }

    # 让方案生效（写 index 后必须重新激活，否则运行中的会话仍用旧值）
    $activate = Invoke-PowerCfg -Arguments @('/setactive', $scheme)
    if ($activate.ExitCode -ne 0) { throw "powercfg /setactive 失败: $($activate.Output)" }

    # 休眠功能本身：关掉才能杜绝“混合睡眠/快速启动”路径上的自动休眠。
    [void](Set-HibernateBestEffort -State 'off')

    # ---- 3. 读回验证 ----
    $after = Get-CurrentState -IncludeLockScreen:$IncludeLockScreen
    $skippedKeys = @($skipped | ForEach-Object { $_.Key })
    $failures = New-Object System.Collections.ArrayList
    foreach ($item in $after.Items) {
        if ($skippedKeys -contains $item.Key) { continue }
        if ($item.Kind -eq 'power') {
            if ($item.AC -ne $item.Target) { [void]$failures.Add("$($item.Label) 交流侧读回 = $(Format-Value $item.AC)，期望 $($item.Target)") }
            if ($item.DC -ne $item.Target) { [void]$failures.Add("$($item.Label) 电池侧读回 = $(Format-Value $item.DC)，期望 $($item.Target)") }
        } else {
            if ([string]$item.Value -ne [string]$item.Target) { [void]$failures.Add("$($item.Label) 读回 = $(Format-Value $item.Value)，期望 $($item.Target)") }
        }
    }

    Show-Status -IncludeLockScreen:$IncludeLockScreen

    if ($failures.Count -gt 0) {
        Write-Host '验证未通过：' -ForegroundColor Red
        foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
        Write-Host ''
        Write-Host ('可用 .\StayAwake.ps1 -Restore -BackupFile "{0}" 回滚。' -f $BackupPath) -ForegroundColor Yellow
        exit 1
    }

    if ($skipped.Count -gt 0) {
        Write-Host '这台机器不支持以下设置项，已跳过（其余项已生效）：' -ForegroundColor Yellow
        foreach ($s in $skipped) { Write-Host ('  - {0}: {1}' -f $s.Label, $s.Reason) -ForegroundColor Yellow }
        Write-Host ''
    }

    $verified = $after.Items.Count - $skipped.Count
    Write-Host ('{0} 项已写入并读回验证通过。' -f $verified) -ForegroundColor Green
    if (-not $IncludeLockScreen) {
        Write-Host '注意：唤醒密码、Win+L、锁屏界面保持原样（需要时加 -DisableLockScreen）。' -ForegroundColor DarkGray
    }
    Write-Host ('回滚：.\StayAwake.ps1 -Restore' ) -ForegroundColor DarkGray
}

# ==========================================================================
# Restore
# ==========================================================================

function Invoke-Restore {
    param([string]$BackupPath)

    if (-not (Test-Administrator)) {
        throw '需要管理员权限。请用 StayAwake.cmd -Restore 启动，或在管理员 PowerShell 中运行。'
    }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $BackupPath = Join-Path $script:StateDir 'backup-latest.json'
    }
    if (-not (Test-Path $BackupPath)) {
        throw "找不到备份文件: $BackupPath"
    }

    $backup = Get-Content -Path $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('从 {0} 回滚（备份于 {1}）' -f $BackupPath, $backup.CreatedAt) -ForegroundColor Cyan

    $scheme = $backup.Scheme
    foreach ($item in $backup.Items) {
        if ($item.Kind -eq 'power') {
            # 备份里存的是有效值（键缺失时已回落到方案默认值），原样写回即可。
            # 读不到有效值的项（Source = unknown）当时就没被改过，跳过。
            if ($null -ne $item.AC) { [void](Invoke-PowerCfg -Arguments @('/setacvalueindex', $scheme, $item.Sub, $item.Setting, "$($item.AC)")) }
            if ($null -ne $item.DC) { [void](Invoke-PowerCfg -Arguments @('/setdcvalueindex', $scheme, $item.Sub, $item.Setting, "$($item.DC)")) }
        } else {
            if ($null -eq $item.Value) {
                Remove-RegValue -Path $item.Path -Name $item.Name
            } else {
                Set-RegValue -Path $item.Path -Name $item.Name -Value $item.Value -Type $item.Type
            }
        }
    }

    $activate = Invoke-PowerCfg -Arguments @('/setactive', $scheme)
    if ($activate.ExitCode -ne 0) { throw "powercfg /setactive 失败: $($activate.Output)" }

    # 恢复休眠到备份记录的原状态，而不是无脑打开——原本就没开休眠的机器
    # 被“回滚”成开着，那不是回滚。
    $hadHibernate = $null
    if ($backup.PSObject.Properties.Name -contains 'HibernateEnabled') { $hadHibernate = $backup.HibernateEnabled }
    if ($null -ne $hadHibernate) {
        [void](Set-HibernateBestEffort -State $(if ([int]$hadHibernate -eq 1) { 'on' } else { 'off' }))
    }

    # 读回验证：每一项都必须回到备份里的原值
    $after = Get-CurrentState -IncludeLockScreen:([bool]$backup.IncludeLockScreen)
    $failures = New-Object System.Collections.ArrayList
    foreach ($item in $backup.Items) {
        $now = $after.Items | Where-Object { $_.Key -eq $item.Key } | Select-Object -First 1
        if ($null -eq $now) { continue }
        if ($item.Kind -eq 'power') {
            # 备份时就读不到有效值的项当时没被改过，也无从声称回滚了它。
            if ($null -ne $item.AC -and [string]$now.AC -ne [string]$item.AC) { [void]$failures.Add("$($item.Label) 交流侧 = $(Format-Value $now.AC)，期望 $(Format-Value $item.AC)") }
            if ($null -ne $item.DC -and [string]$now.DC -ne [string]$item.DC) { [void]$failures.Add("$($item.Label) 电池侧 = $(Format-Value $now.DC)，期望 $(Format-Value $item.DC)") }
        } else {
            if ([string]$now.Value -ne [string]$item.Value) { [void]$failures.Add("$($item.Label) = $(Format-Value $now.Value)，期望 $(Format-Value $item.Value)") }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host '回滚验证未通过：' -ForegroundColor Red
        foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
        exit 1
    }

    Write-Host '已回滚到备份中的原始设置，并读回验证通过。' -ForegroundColor Green
}

# ==========================================================================
# Guard
# ==========================================================================

function Invoke-Guard {
    Add-Type -Namespace StayAwake -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

    # PowerShell 把 0x80000000 当 Int32 字面量解析，值是 -2147483648，
    # 直接 [uint32] 转换会溢出。L 后缀强制走 Int64 字面量。
    $ES_CONTINUOUS       = [uint32]0x80000000L
    $ES_SYSTEM_REQUIRED  = [uint32]0x00000001
    $ES_DISPLAY_REQUIRED = [uint32]0x00000002

    # -bor 会把操作数提升到 Int64，显式转回 UInt32 再交给 P/Invoke。
    $flags = [uint32]($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
    $prev = [StayAwake.Native]::SetThreadExecutionState($flags)
    if ($prev -eq 0) {
        throw "SetThreadExecutionState 失败 (Win32 错误 $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }

    Write-Host ''
    Write-Host '守护模式已启动：系统与显示器均被声明为“正在使用”。' -ForegroundColor Green
    Write-Host '这个窗口保持打开即持续生效；Ctrl+C 退出后立刻恢复正常空闲计时。' -ForegroundColor DarkGray
    Write-Host ''

    try {
        while ($true) {
            # 重新声明一次，抵消其他进程清空执行状态的情况。
            [void][StayAwake.Native]::SetThreadExecutionState($flags)
            Write-Host ('  {0}  保持唤醒中…' -f (Get-Date -Format 'HH:mm:ss')) -NoNewline
            Write-Host "`r" -NoNewline
            Start-Sleep -Seconds 30
        }
    } finally {
        [void][StayAwake.Native]::SetThreadExecutionState($ES_CONTINUOUS)
        Write-Host ''
        Write-Host '守护模式已退出，系统恢复正常空闲计时。' -ForegroundColor Yellow
    }
}

# ==========================================================================
# 入口
# ==========================================================================

try {
    if ($Status) {
        Show-Status -IncludeLockScreen
    } elseif ($Restore) {
        Invoke-Restore -BackupPath $BackupFile
    } elseif ($Guard) {
        Invoke-Guard
    } else {
        Invoke-Apply -IncludeLockScreen:$DisableLockScreen -BackupPath $BackupFile
    }
} catch {
    Write-Host ''
    Write-Host ('错误: {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkRed
    }
    if ($_.Exception.InnerException) {
        Write-Host ('内层错误: {0}' -f $_.Exception.InnerException.Message) -ForegroundColor DarkRed
    }
    exit 2
}
