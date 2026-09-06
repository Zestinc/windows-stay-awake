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
    [string]$BackupFile,

    # 内部使用：标记本进程是被自己提权拉起来的，结束前要停住让人看到结果。
    # 不要手工传。
    [switch]$Elevated
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
    # 动态锁有两个开关：用户在“设置”里点的那个在用户 hive 的 Winlogon 下，
    # 组策略那个在 HKLM Policies 下。只写其中一个都可能留下仍会锁屏的路径，
    # 两个都写。
    @{ Key = 'DynamicLockUser';     Path = '<USERHIVE>\Software\Microsoft\Windows NT\CurrentVersion\Winlogon';    Name = 'EnableGoodbye';        Target = 0;   Type = 'DWord';  Label = '动态锁（用户开关）';   Tier = 'preset' }
    @{ Key = 'DynamicLockPolicy';   Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsLogon';               Name = 'EnableGoodbye';        Target = 0;   Type = 'DWord';  Label = '动态锁（组策略）';     Tier = 'preset' }
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

function ConvertTo-CommandLineArgument {
    <#
        按 Windows 命令行规则引用单个参数。

        Start-Process -ArgumentList 收到数组时只是用空格拼接，**不会**替含空格的
        元素加引号。脚本装在 "C:\My Tools\" 下、或 -BackupFile 指向带空格的路径
        时，子进程会因此拿到被拆碎的参数。
        规则：内部的 " 要转义，且紧邻闭合引号的反斜杠必须加倍，否则会把引号转义掉。
    #>
    param([string]$Value)

    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-SelfElevate {
    <#
        以管理员身份重新拉起自己。

        提权判断必须在这一层做：启动器只能对命令行做字符串匹配来猜要不要提权，
        那份猜测跟这里真正的参数集解析是两套逻辑，迟早漂移；而参数经 cmd 的
        %* 二次内插后，带空格或 & 的值会直接碎掉。这里用 $PSBoundParameters
        精确重建，Start-Process 的数组形参负责引用，绕开所有 cmd 转义。

        无交互桌面（SSH 会话、计划任务、服务）里 UAC 弹不出来，这种情况必须
        明说怎么办，而不是丢一个神秘失败——从 Mac SSH 过来正是常见用法。
    #>
    param([hashtable]$BoundParameters)

    if (-not [Environment]::UserInteractive) {
        throw ('需要管理员权限，但当前会话没有交互桌面（SSH / 计划任务 / 服务），UAC 无法弹出。' + [Environment]::NewLine +
               '请改用具备管理员身份的账户运行，或在这台机器上开一个管理员 PowerShell 再执行。')
    }

    $psExe = (Get-Process -Id $PID).Path
    $argList = New-Object System.Collections.ArrayList
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)) {
        [void]$argList.Add($a)
    }
    foreach ($kv in $BoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'Elevated') { continue }
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { [void]$argList.Add("-$($kv.Key)") }
        } else {
            [void]$argList.Add("-$($kv.Key)")
            [void]$argList.Add([string]$kv.Value)
        }
    }
    [void]$argList.Add('-Elevated')

    $commandLine = ($argList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '

    Write-Host '正在请求管理员权限…' -ForegroundColor Cyan
    try {
        # -Wait 才能把子进程的退出码带回来。没有它，提权后无论成败父进程都
        # 立刻 exit 0，调用方（以及 .cmd 的 %ERRORLEVEL%）会收到假的成功。
        $child = Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $commandLine `
                               -Wait -PassThru -ErrorAction Stop
    } catch {
        throw ('提权被取消或失败：{0}' -f $_.Exception.Message)
    }
    return $child.ExitCode
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

    $self = "$env:USERDOMAIN\$env:USERNAME"

    if ([string]::IsNullOrWhiteSpace($userName)) {
        return [pscustomobject]@{
            Hive = 'HKCU:'; Account = $self; Resolved = $false
            Note = '没有检测到交互登录会话，只能改当前账户；若实际有人在用桌面，其屏保设置不会被改到'
        }
    }

    if ($userName -eq $self) {
        return [pscustomobject]@{ Hive = 'HKCU:'; Account = $userName; Resolved = $true; Note = $null }
    }

    try {
        $account = New-Object System.Security.Principal.NTAccount($userName)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return [pscustomobject]@{
            Hive = 'HKCU:'; Account = $self; Resolved = $false
            Note = "无法解析登录用户 $userName 的 SID，改的是 $self；$userName 的屏保设置不会被改到"
        }
    }

    $hive = "Registry::HKEY_USERS\$sid"
    if (-not (Test-Path $hive)) {
        return [pscustomobject]@{
            Hive = 'HKCU:'; Account = $self; Resolved = $false
            Note = "登录用户 $userName 的注册表 hive 未加载，改的是 $self；$userName 的屏保设置不会被改到"
        }
    }
    return [pscustomobject]@{ Hive = $hive; Account = $userName; Resolved = $true; Note = $null }
}

# SPI acts on the calling session, not an arbitrary HKEY_USERS hive.
function Initialize-ScreenSaverApi {
    if ('StayAwake.ScreenSaverApi' -as [type]) { return }
    Add-Type -Namespace StayAwake -Name ScreenSaverApi -MemberDefinition @'
[DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool Get(uint action, uint param, out uint value, uint flags);
[DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool Set(uint action, uint param, IntPtr value, uint flags);
[DllImport("kernel32.dll")]
public static extern uint WTSGetActiveConsoleSessionId();
'@
}

function Get-ScreenSaverRuntime {
    Initialize-ScreenSaverApi
    $values = @{}
    foreach ($pair in @(@('Active', 0x10), @('Timeout', 0x0E), @('Secure', 0x76))) {
        [uint32]$value = 0
        if (-not [StayAwake.ScreenSaverApi]::Get($pair[1], 0, [ref]$value, 0)) {
            throw "屏保运行状态读取失败：$($pair[0])，Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        $values[$pair[0]] = $value
    }
    return [pscustomobject]@{
        Active = $values.Active; Timeout = $values.Timeout; Secure = $values.Secure
        UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        SessionId = (Get-Process -Id $PID).SessionId
    }
}

function Assert-ScreenSaverContext {
    param([string]$UserHive, $Runtime)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($UserHive -ne 'HKCU:' -and $UserHive -ne "Registry::HKEY_USERS\$sid") {
        throw '屏保运行状态只能在目标用户自己的会话中更新；请以正在使用桌面的账户运行，不能用另一管理员账户代替。尚未修改设置。'
    }
    Initialize-ScreenSaverApi
    $target = Get-InteractiveUserHive
    if ($target.Resolved -and (Get-Process -Id $PID).SessionId -ne [StayAwake.ScreenSaverApi]::WTSGetActiveConsoleSessionId()) {
        throw '当前进程不在目标控制台会话，无法同步其屏保运行状态；请在目标 Windows 桌面运行。尚未修改设置。'
    }
    if ($null -ne $Runtime -and $Runtime.UserSid -ne $sid) {
        throw '备份属于另一用户，不能把其屏保运行状态恢复到当前账户。尚未修改设置。'
    }
}

function Set-ScreenSaverRuntime {
    param([uint32]$Active, [uint32]$Timeout, [switch]$IncludeSecure,
          [uint32]$Secure, [uint32]$Flags = 3)
    Initialize-ScreenSaverApi
    $pairs = @(@(0x0F, $Timeout), @(0x11, $Active))
    if ($IncludeSecure) { $pairs += ,@(0x77, $Secure) }
    foreach ($pair in $pairs) {
        if (-not [StayAwake.ScreenSaverApi]::Set($pair[0], $pair[1], [IntPtr]::Zero, $Flags)) {
            throw "屏保运行状态更新失败：SPI=$($pair[0])，Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())；原值已备份，可运行 -Restore。"
        }
    }
    $actual = Get-ScreenSaverRuntime
    if ($actual.Active -ne $Active -or $actual.Timeout -ne $Timeout -or
        ($IncludeSecure -and $actual.Secure -ne $Secure)) {
        throw "屏保运行状态验证失败：Active=$($actual.Active), Timeout=$($actual.Timeout), Secure=$($actual.Secure)"
    }
    Write-Host "Screen saver runtime verified: Active=$Active Timeout=$Timeout Session=$($actual.SessionId)" -ForegroundColor Green
}

function Get-ScreenSaverPolicyConflicts {
    <#
        组策略位置优先于普通的 Control Panel\Desktop。域里（或本机组策略里）
        强制开了屏保时，只改普通位置不会生效，而读回普通位置却会显示成功。
        这里只做检测和如实报告：写组策略缓存在域环境下会被下一次 gpupdate
        覆盖，制造“改好了”的假象，比不改更糟。
    #>
    param([string]$UserHive)

    $conflicts = New-Object System.Collections.ArrayList
    $policyPath = "$UserHive\Software\Policies\Microsoft\Windows\Control Panel\Desktop"
    $checks = @(
        @{ Name = 'ScreenSaveActive';    Bad = '1'; Label = '组策略强制启用了屏幕保护程序' }
        @{ Name = 'ScreenSaverIsSecure'; Bad = '1'; Label = '组策略强制屏保恢复时需要密码' }
    )
    foreach ($c in $checks) {
        $v = Get-RegValue -Path $policyPath -Name $c.Name
        if ($null -ne $v -and [string]$v -eq $c.Bad) {
            [void]$conflicts.Add(('{0}（{1}\{2} = {3}），本工具改的普通设置会被它压过' -f $c.Label, $policyPath, $c.Name, $v))
        }
    }
    $timeout = Get-RegValue -Path $policyPath -Name 'ScreenSaveTimeOut'
    if ($null -ne $timeout -and [int]$timeout -gt 0) {
        [void]$conflicts.Add(('组策略设定了屏保等待时间 {0} 秒（{1}\ScreenSaveTimeOut）' -f $timeout, $policyPath))
    }
    return $conflicts
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
    # 两侧必须各自独立回落——某个来源只提供 AC 默认值时，不能就此收工把 DC
    # 留成 null：Apply 照样会把 DC 写成 0，而 Restore 见到 null 会跳过，
    # 那一侧就永远回不去了。
    $ac = $v.AC
    $dc = $v.DC
    $usedDefault = $false
    foreach ($src in @($Scheme, $script:SCHEME_BALANCED)) {
        if ($null -ne $ac -and $null -ne $dc) { break }
        $defPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$Sub\$Setting\DefaultPowerSchemeValues\$src"
        $d = Read-SettingIndexes -Path $defPath
        if ($null -eq $ac -and $null -ne $d.AC) { $ac = $d.AC; $usedDefault = $true }
        if ($null -eq $dc -and $null -ne $d.DC) { $dc = $d.DC; $usedDefault = $true }
    }

    $source = if ($null -eq $ac -or $null -eq $dc) { 'unknown' }
              elseif ($usedDefault) { 'default' }
              else { 'scheme' }
    return @{ AC = $ac; DC = $dc; Source = $source }
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
    $userHive = $hiveInfo.Hive
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
        UserAccount       = $hiveInfo.Account
        UserResolved      = $hiveInfo.Resolved
        UserNote          = $hiveInfo.Note
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
    $runtime = Get-ScreenSaverRuntime
    Write-Host ('  当前会话屏保 : Active={0} Timeout={1} Secure={2} Session={3}' -f $runtime.Active, $runtime.Timeout, $runtime.Secure, $runtime.SessionId)
    if ($state.UserHive -ne 'HKCU:') {
        Write-Host '  当前进程与目标用户不同：以上运行值不能证明目标桌面状态。' -ForegroundColor Yellow
    }
    $hib = if ($null -eq $state.HibernateEnabled) { '(不支持/未知)' } elseif ([int]$state.HibernateEnabled -eq 1) { '已启用' } else { '已关闭' }
    Write-Host ('  休眠功能 : {0}' -f $hib)
    if (-not $state.UserResolved -and $state.UserNote) {
        Write-Host ('  ⚠ {0}' -f $state.UserNote) -ForegroundColor Yellow
    }
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
    Assert-ScreenSaverContext -UserHive $before.UserHive
    $runtimeBefore = Get-ScreenSaverRuntime

    # ---- 1. 先备份，再改 ----
    if (-not (Test-Path $script:StateDir)) { New-Item -Path $script:StateDir -ItemType Directory -Force | Out-Null }
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        # 毫秒精度：同一秒内连跑两次不会互相覆盖历史备份。
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $BackupPath = Join-Path $script:StateDir "backup-$stamp.json"
    }
    $backup = [pscustomobject]@{
        CreatedAt         = (Get-Date).ToString('o')
        Scheme            = $before.Scheme
        UserHive          = $before.UserHive
        UserAccount       = $before.UserAccount
        HibernateEnabled  = $before.HibernateEnabled
        IncludeLockScreen = [bool]$IncludeLockScreen
        ScreenSaverRuntime = $runtimeBefore
        Items             = $before.Items
    }
    $backup | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupPath -Encoding UTF8
    Copy-Item -Path $BackupPath -Destination (Join-Path $script:StateDir 'backup-latest.json') -Force
    Write-Host ('已备份原值 -> {0}' -f $BackupPath) -ForegroundColor DarkGray

    # pristine：本工具第一次动手之前的状态，只创建一次，绝不被后续 Apply 覆盖。
    # 没有它的话，「先 -DisableLockScreen 再跑一次预设层」这种连续 Apply 会把
    # 备份刷成已被改过的中间态，认证层的原值就永久丢了，之后 Restore 会成功
    # 退出但唤醒密码仍是关的。
    $pristinePath = Join-Path $script:StateDir 'backup-pristine.json'
    if (Test-Path $pristinePath) {
        # 已有 pristine，但本次可能覆盖了它没记录的层（例如它只记了预设层，
        # 这次带上了 -DisableLockScreen）。那些项此刻还没被本次写入改动，
        # 现在的值就是它们的原值，补进去。
        $pristine = Get-Content -Path $pristinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-ScreenSaverContext -UserHive $pristine.UserHive
        if ($pristine.PSObject.Properties.Name -notcontains 'ScreenSaverRuntime') {
            $pristine | Add-Member -NotePropertyName ScreenSaverRuntime -NotePropertyValue $runtimeBefore
            $pristine | ConvertTo-Json -Depth 6 | Set-Content -Path $pristinePath -Encoding UTF8
        }
        Assert-ScreenSaverContext -UserHive $pristine.UserHive -Runtime $pristine.ScreenSaverRuntime
        $known = @($pristine.Items | ForEach-Object { $_.Key })
        $missing = @($before.Items | Where-Object { $known -notcontains $_.Key })
        if ($missing.Count -gt 0) {
            $pristine.Items = @($pristine.Items) + $missing
            $pristine | ConvertTo-Json -Depth 6 | Set-Content -Path $pristinePath -Encoding UTF8
            Write-Host ('  已把 {0} 个新增项的原值并入 pristine 备份' -f $missing.Count) -ForegroundColor DarkGray
        }
    } else {
        $backup | ConvertTo-Json -Depth 6 | Set-Content -Path $pristinePath -Encoding UTF8
    }

    # ---- 2. 写入 ----
    $scheme = $before.Scheme
    $writeErrors = @{}
    foreach ($item in $before.Items) {
        if ($item.Kind -eq 'power') {
            $ac = Invoke-PowerCfg -Arguments @('/setacvalueindex', $scheme, $item.Sub, $item.Setting, "$($item.Target)")
            $dc = Invoke-PowerCfg -Arguments @('/setdcvalueindex', $scheme, $item.Sub, $item.Setting, "$($item.Target)")
            if ($ac.ExitCode -ne 0 -or $dc.ExitCode -ne 0) {
                $writeErrors[$item.Key] = $(if ($ac.ExitCode -ne 0) { $ac.Output } else { $dc.Output })
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

    # 保存值与会话缓存必须分别更新，单写注册表不会关闭已缓存的屏保。
    Set-ScreenSaverRuntime -Active 0 -Timeout 0 -IncludeSecure:$IncludeLockScreen -Secure 0

    # ---- 3. 读回验证 ----
    # 判据以读回结果为准，写入时的退出码只是线索。三分：
    #   通过     — 读回等于目标值。
    #   skipped  — 读回不等，且系统的 PowerSettings 下根本没有这个设置项，
    #              属于真正的机器能力边界。
    #   failure  — 读回不等，但系统认识这个设置项。那是权限不足、被策略覆盖
    #              或本脚本有 bug，绝不能当成“不支持”然后返回成功。
    $after = Get-CurrentState -IncludeLockScreen:$IncludeLockScreen
    $skipped = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList
    foreach ($item in $after.Items) {
        if ($item.Kind -eq 'power') {
            $bad = New-Object System.Collections.ArrayList
            if ($item.AC -ne $item.Target) { [void]$bad.Add("交流侧 = $(Format-Value $item.AC)") }
            if ($item.DC -ne $item.Target) { [void]$bad.Add("电池侧 = $(Format-Value $item.DC)") }
            if ($bad.Count -eq 0) { continue }

            $supported = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$($item.Sub)\$($item.Setting)"
            $detail = ($bad -join '，')
            if (-not $supported) {
                $reason = if ($writeErrors.ContainsKey($item.Key)) { $writeErrors[$item.Key] } else { '这台机器没有这个电源设置项' }
                [void]$skipped.Add([pscustomobject]@{ Key = $item.Key; Label = $item.Label; Reason = $reason })
            } else {
                $extra = if ($writeErrors.ContainsKey($item.Key)) { "；powercfg: $($writeErrors[$item.Key])" } else { '' }
                [void]$failures.Add("$($item.Label) $detail，期望 $($item.Target)$extra")
            }
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
        $script:ExitCode = 1
        return
    }

    if ($skipped.Count -gt 0) {
        Write-Host '这台机器不支持以下设置项，已跳过（其余项已生效）：' -ForegroundColor Yellow
        foreach ($s in $skipped) { Write-Host ('  - {0}: {1}' -f $s.Label, $s.Reason) -ForegroundColor Yellow }
        Write-Host ''
    }

    # 验证通过不代表目标达成：改错了账户、或被组策略压过，读回都会显示成功。
    if (-not $after.UserResolved -and $after.UserNote) {
        Write-Host ('⚠ {0}' -f $after.UserNote) -ForegroundColor Yellow
        Write-Host ''
    }
    # @() 是必须的：PowerShell 从函数返回集合时会把它展开，空集合会变成
    # $null，随后 $null.Count 在 StrictMode 下直接抛错。
    $policyConflicts = @(Get-ScreenSaverPolicyConflicts -UserHive $after.UserHive)
    if ($policyConflicts.Count -gt 0) {
        Write-Host '⚠ 检测到组策略配置，它优先于本工具修改的普通设置：' -ForegroundColor Yellow
        foreach ($c in $policyConflicts) { Write-Host ('  - {0}' -f $c) -ForegroundColor Yellow }
        Write-Host '  屏保可能仍会启动。请在组策略（gpedit.msc / 域策略）里关闭对应项。' -ForegroundColor Yellow
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

    # 默认回滚到 pristine——它记的是本工具第一次动手之前的状态。
    # backup-latest 在连续 Apply 之后记的是「已经被改过的状态」，拿它回滚
    # 等于回到中间态。
    $usingPristine = $false
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $pristinePath = Join-Path $script:StateDir 'backup-pristine.json'
        if (Test-Path $pristinePath) {
            $BackupPath = $pristinePath
            $usingPristine = $true
        } else {
            $BackupPath = Join-Path $script:StateDir 'backup-latest.json'
        }
    }
    if (-not (Test-Path $BackupPath)) {
        throw "找不到备份文件: $BackupPath"
    }

    $backup = Get-Content -Path $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('从 {0} 回滚（备份于 {1}）' -f $BackupPath, $backup.CreatedAt) -ForegroundColor Cyan

    $runtimeOriginal = $null
    if ($backup.PSObject.Properties.Name -contains 'ScreenSaverRuntime') {
        $runtimeOriginal = $backup.ScreenSaverRuntime
    }
    Assert-ScreenSaverContext -UserHive $backup.UserHive -Runtime $runtimeOriginal
    if ($null -eq $runtimeOriginal) {
        throw '旧备份未记录屏保运行状态，无法精确回滚当前会话；请使用新版 Apply 生成或补录的备份。尚未修改设置。'
    }

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

    # 仅恢复运行缓存并广播（flags=2），避免把当时不一致的注册表原值覆盖掉。
    $restoreSecure = @($backup.Items | Where-Object { $_.Key -eq 'ScreenSaverIsSecure' }).Count -gt 0
    Set-ScreenSaverRuntime -Active $runtimeOriginal.Active -Timeout $runtimeOriginal.Timeout `
        -IncludeSecure:$restoreSecure -Secure $runtimeOriginal.Secure -Flags 2

    # 读回验证：直接按备份里记录的路径读，不重新解析「当前交互用户」。
    # 备份写的是 A 的 hive，若此刻登录的是 B，重新解析会去比 B 的值，
    # A 明明恢复正确也会报失败（反之则会漏报）。
    $failures = New-Object System.Collections.ArrayList
    foreach ($item in $backup.Items) {
        if ($item.Kind -eq 'power') {
            $now = Get-PowerValue -Scheme $scheme -Sub $item.Sub -Setting $item.Setting
            # 备份时就读不到有效值的项当时没被改过，也无从声称回滚了它。
            if ($null -ne $item.AC -and [string]$now.AC -ne [string]$item.AC) { [void]$failures.Add("$($item.Label) 交流侧 = $(Format-Value $now.AC)，期望 $(Format-Value $item.AC)") }
            if ($null -ne $item.DC -and [string]$now.DC -ne [string]$item.DC) { [void]$failures.Add("$($item.Label) 电池侧 = $(Format-Value $now.DC)，期望 $(Format-Value $item.DC)") }
        } else {
            $now = Get-RegValue -Path $item.Path -Name $item.Name
            if ([string]$now -ne [string]$item.Value) { [void]$failures.Add("$($item.Label) = $(Format-Value $now)，期望 $(Format-Value $item.Value)") }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host '回滚验证未通过：' -ForegroundColor Red
        foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
        $script:ExitCode = 1
        return
    }

    Write-Host ('已回滚到备份中的原始设置（{0} 项），并读回验证通过。' -f $backup.Items.Count) -ForegroundColor Green

    # pristine 已经用掉了：删掉它，下次 Apply 才会重新记录一份真实原值。
    if ($usingPristine) {
        Remove-Item -Path $BackupPath -Force -ErrorAction SilentlyContinue
    }
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

$script:ExitCode = 0

try {
    # -Status 与 -Guard 是只读/进程内的，不需要管理员；改配置的两条路要。
    $needsAdmin = -not ($Status -or $Guard)
    if ($needsAdmin -and -not (Test-Administrator)) {
        $script:ExitCode = Invoke-SelfElevate -BoundParameters $PSBoundParameters
    } elseif ($Status) {
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
    $script:ExitCode = 2
}

# 被自己提权拉起来的窗口是新开的，跑完就没了。停住让人看到结果，
# 再把退出码交回父进程。
if ($Elevated) {
    Write-Host ''
    Write-Host '按任意键关闭此窗口…' -ForegroundColor DarkGray
    try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 20 }
}

exit $script:ExitCode
