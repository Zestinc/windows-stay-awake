# StayAwake

关闭 Windows 的全部自动休眠 / 自动关屏 / 自动锁屏，让机器保持唤醒、屏幕持续显示当前界面。

无依赖，Windows PowerShell 5.1 起可用，不装服务、不改 UAC、不留后台常驻进程。

## 用法

把 `StayAwake.ps1` 和 `StayAwake.cmd` 放同一个目录，然后：

- **双击 `StayAwake.cmd`** — 自动请求管理员权限，应用预设层，逐项读回验证。
- `StayAwake.cmd -Status` — 只读查看当前状态，不需要管理员。
- `StayAwake.cmd -Restore` — 回滚到最近一次备份。
- `StayAwake.cmd -Guard` — 前台守护模式（见下）。
- `StayAwake.cmd -DisableLockScreen` — 额外关闭锁屏与唤醒密码（见下）。

也可以直接调脚本：`powershell -ExecutionPolicy Bypass -File .\StayAwake.ps1 -Status`

## 两层设计

安全边界不会被静默降低，所以分成两层。

**预设层（默认，只关“自动发生”的行为）**

- 空闲后关闭显示器 → 从不
- 空闲后进入睡眠 → 从不
- 空闲后休眠 → 从不
- 无人值守睡眠超时 → 从不
- 锁屏后关闭显示器 → 从不（这项在“电源选项”界面里默认是隐藏的）
- 空闲后关闭硬盘 → 从不
- 屏幕保护程序 → 关闭
- 不活动自动锁定（InactivityTimeoutSecs）→ 0
- 动态锁（手机蓝牙走开就锁屏）→ 关闭
- 休眠功能本身 → `powercfg /hibernate off`

交流和电池两侧都会写。

**`-DisableLockScreen`（显式选择，会降低这台机器的物理安全性）**

- 唤醒时需要密码 → 否
- 屏保恢复需要密码 → 否
- 锁屏界面 → 禁用
- 手动锁定 Win+L → 禁用

不加这个参数时，上面四项保持原样——预设层不会碰它们。

## 守护模式

`-Guard` 在前台持续声明 `ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED`（和视频播放器让屏幕不灭是同一个机制）。

什么时候需要它：域策略、OEM 电源工具或 Modern Standby 机器会把 `powercfg` 的设置改回去或直接忽略超时。守护模式是运行时的保险，不依赖任何设置项。

窗口开着即生效，Ctrl+C 退出后系统立刻恢复正常空闲计时——它不改任何持久状态。

## 备份与回滚

每次 Apply 都会先把每一项的原值（含“原本就未设置”这个状态）写进：

```
%ProgramData%\StayAwake\backup-<时间戳>.json
%ProgramData%\StayAwake\backup-latest.json
```

`-Restore` 默认读 `backup-latest.json`，也可以 `-Restore -BackupFile <路径>` 指定任意一次。原本未设置的项会被删除而不是写 0，回到电源方案的默认值。

回滚同样逐项读回验证，不一致就以退出码 1 失败。

## 验证

Apply 和 Restore 都不会只打印“已完成”：写完后重新读一遍注册表，逐项比对期望值，任何一项对不上就打印差异并返回非零退出码。

`.github/workflows/ci.yml` 在 windows-2022 和 windows-2025 两个真实 Windows 上跑：只读性（`-Status` 不改配置）、Apply 后独立复查注册表、预设层不得动认证相关项、幂等、Restore 精确回到原值、`-DisableLockScreen` 层的应用与回滚、守护模式持有 power request、`.cmd` 入口转发参数。

## 退出码

- `0` 成功
- `1` 写入成功但读回验证不通过
- `2` 执行出错（缺少管理员权限、powercfg 调用失败等）

## 已知边界

- 提权后 `HKCU` 指向管理员账户而不是正在用这台机器的人。脚本会通过 `Win32_ComputerSystem.UserName` 解析交互登录用户的 SID，改写 `HKEY_USERS\<SID>` 下的屏保设置。无人交互登录时（例如纯 SSH 会话）回落到当前用户，并在 `-Status` 的“目标用户”一行标注。
- 只作用于**当前活动的电源方案**。切换电源方案后需要重新运行。
- 设置项通过注册表读回，不解析 `powercfg` 的文字输出——后者在中文系统上是中文的，按英文关键字解析会静默失配。
- 回滚恢复的是**有效值**而不是注册表键的存在性：`powercfg` 没有「取消设置」这个操作，删掉键之后 `/setactive` 会立刻按当前生效值把它重建。方案键里缺项时，备份记录的是该项的方案默认值。
- 休眠开关（`powercfg /hibernate`）是尽力而为的额外收紧，不是必要条件——超时全零已经杜绝自动休眠。不支持休眠的机器（VM、部分 OEM 配置）上会跳过并打印原因，不影响其余项。
- **改脚本请保留 UTF-8 BOM。** Windows PowerShell 5.1 读无 BOM 的 UTF-8 文件时按系统 ANSI 代码页解码，中文会乱码并撑坏字符串边界，整个脚本直接解析失败。CI 有字节级断言守着这条。
