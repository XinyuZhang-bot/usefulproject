<#
  ============================================================================
  AutoPowerPro.ps1  --  定时开关机 + 每 N 分钟自动重启
  ============================================================================

  两个功能：
    1) 定时开关机       每天 / 仅工作日 / 自定义星期，到点关机 + 到点唤醒
    2) 每 N 分钟自动重启 纯软件循环重启，不断电

  ---------------------------------------------------------------------------
  计划任务（全部以 SYSTEM 身份运行，不依赖登录密码）
  ---------------------------------------------------------------------------
    AutoPowerPro_ScheduledOff     定时关机 / 休眠 / 睡眠
    AutoPowerPro_ScheduledOn      定时唤醒（已勾选"唤醒计算机运行此任务"）
    AutoPowerPro_CycleRestart     每 N 分钟重启

  卸载：菜单选 [4]，会把以上 3 个任务全部删除，并可选清理数据目录。

  ---------------------------------------------------------------------------
  台式机 / 笔记本适配（本版重点）
  ---------------------------------------------------------------------------
    · 开屏先做"环境体检"：机型、供电（交流电/电池 + 电量）、系统版本、
      休眠是否可用、唤醒定时器在"接电源 / 用电池"下各自的策略、已装任务。
    · 检测全部是"多级兜底"：WMI → .NET → 注册表。精简系统里 WMI 服务不可用时
      也不会瞎猜（例如机型退化用"有没有电池"判断，系统版本退化读注册表）。
    · 三个任务的电池策略统一显式设置（AllowStartIfOnBatteries / StopIfGoingOnBatteries），
      笔记本用电池时同样生效。
      ※ 旧版循环重启用 schtasks /Create，它建出来的任务默认"只在交流电源下运行"，
        笔记本拔电后循环重启根本不触发 —— 本版改成 Register-ScheduledTask，已修掉。
    · 笔记本额外提醒：插电源、合盖设置、电池供电时唤醒定时器可能被机型限制。
    · 台式机额外提醒：休眠默认多为关闭（会自动尝试打开）、待机时别断插排。
    · 循环重启任务不唤醒休眠中的机器，也不补跑错过的触发点
      （否则机器一开机就被补跑重启一次 = 死循环）。

  ---------------------------------------------------------------------------
  界面与交互
  ---------------------------------------------------------------------------
    · 面板式布局；中文按"显示列数"计算宽度，边框不会被中文字符撑破。
    · 每一步都有 [ 第几步 / 共几步 ]，并提示"回车 = 默认值 / q = 取消"。
    · 安装完成、卸载完成都有结果卡片：装了什么、下次何时生效、怎么撤销。

  ---------------------------------------------------------------------------
  运行记录（什么时间关机 / 重启 / 唤醒了）
  ---------------------------------------------------------------------------
    · 三个任务的动作都改成外壳脚本（off-*.cmd / wake.cmd / restart.cmd）：
      外壳先往 %ProgramData%\AutoPowerPro\events.log 写一行带时间戳的事件，
      再执行真正的关机/休眠/重启 —— 于是"任务什么时候被触发"完全可追溯。
    · 菜单 [4]「运行记录」把这份记录与 Windows 系统事件日志里的**真实电源事件**
      合并，按时间倒序显示（最近 40 条 + 汇总）。覆盖的事件：
        User32 1074              谁发起了关机/重启（手动关机、Windows 更新都算）
        6005 / 6006 / 6008       系统启动完成 / 正常关机 / 异常关机
        Kernel-Power 42 / 107    进入睡眠 / 从睡眠唤醒
        Kernel-Power 506 / 507   进入、退出新式待机（Modern Standby，新笔记本常见）
        Power-Troubleshooter 1   从睡眠唤醒（含唤醒源）
        Kernel-Power 41          内核意外断电重启
    · 汇总部分给出：今天唤醒几次、关机类几次、重启几次、系统电源事件几条、
      最近一次唤醒时间。
    · 命令行也可以直接看：   AutoPowerPro.ps1 -Log

  ---------------------------------------------------------------------------
  ★ 关于"自动开机"能做到什么程度（先看这段，能省很多麻烦）
  ---------------------------------------------------------------------------
    关机 / 休眠 / 睡眠       纯软件就能做。
    从「休眠 / 睡眠」里唤醒  软件做得到 —— 本工具会自动打开电源方案里的
                             "允许唤醒定时器"，并给唤醒任务勾上 WakeToRun。
    从「完全关机」开机       软件做不到。完全关机后系统里没有任何东西在运行，
                             只有两条路：① BIOS 的 RTC 定时开机（只能设
                             "每天几点"，没有间隔选项）② 通电自动开机。
                            所以推荐用「休眠」：真正断电、状态保留、唤醒最可靠。

  ---------------------------------------------------------------------------
  文件编码说明（改这个脚本的人注意）
  ---------------------------------------------------------------------------
    本文件必须保存为 UTF-8 with BOM + CRLF。
    PowerShell 5.1 在中文 Windows 上读取【没有 BOM】的 .ps1 会按 GBK 解码，
    脚本里所有中文（包括中文正则）都会变成乱码。
  ============================================================================
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Uninstall,
    [switch]$Log,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Script:LastNativeExit = 0

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
$T_OFF     = 'AutoPowerPro_ScheduledOff'
$T_ON      = 'AutoPowerPro_ScheduledOn'
$T_RESTART = 'AutoPowerPro_CycleRestart'
$AllTasks  = @($T_OFF, $T_ON, $T_RESTART)

$DataDir = Join-Path $env:ProgramData 'AutoPowerPro'
$EventLog = Join-Path $DataDir 'events.log'   # 本工具自己的执行记录（任务何时被触发）
$LogCmd   = Join-Path $DataDir 'log.cmd'      # 写记录的助手脚本（纯 ASCII）

$SUB_SLEEP      = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$SET_WAKETIMERS = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'

# ---- 界面主题 -------------------------------------------------------------
$Script:UI_W   = 74     # 面板内容宽度（不含左右边框）
$Script:UI_PAD = 2      # 面板左右内边距

$C_Border  = 'DarkCyan'
$C_Title   = 'Cyan'
$C_Key     = 'White'
$C_Val     = 'Yellow'
$C_Accent  = 'Cyan'
$C_Dim     = 'DarkGray'
$C_Hint    = 'Gray'
$C_Ok      = 'Green'
$C_Warn    = 'Yellow'
$C_Err     = 'Red'

# ---------------------------------------------------------------------------
# 环境自检
# ---------------------------------------------------------------------------
function Stop-WithMessage([string]$Message) {
    Write-Host ''
    Write-Host ('  [ X ] ' + $Message) -ForegroundColor $C_Err
    Write-Host ''
    Read-Host '  按回车退出' | Out-Null
    exit 1
}

try {
    $null = & chcp.com 65001 2>&1
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Stop-WithMessage ('需要 PowerShell 5.1 或更高版本，当前为 ' +
        $PSVersionTable.PSVersion.ToString() + '。')
}
if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
    Stop-WithMessage '本系统没有计划任务模块，需要 Windows 8 / Server 2012 或更高版本。'
}

# ===========================================================================
#  一、文本宽度与排版
# ===========================================================================
function Get-DisplayWidth([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        $wide = $false
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0x303E) -or
            ($c -ge 0x3041 -and $c -le 0x33FF) -or
            ($c -ge 0x3400 -and $c -le 0x4DBF) -or
            ($c -ge 0x4E00 -and $c -le 0x9FFF) -or
            ($c -ge 0xA000 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $wide = $true }
        if ($wide) { $w += 2 } else { $w += 1 }
    }
    return $w
}

# 按"显示列数"裁剪，超长时用 .. 收尾，保证面板边框不被撑破
function Format-Clip([string]$Text, [int]$Max) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ((Get-DisplayWidth $Text) -le $Max) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cw = Get-DisplayWidth ([string]$ch)
        if ($w + $cw -gt ($Max - 2)) { break }
        [void]$sb.Append($ch)
        $w += $cw
    }
    return ($sb.ToString() + '..')
}

# 造一个带颜色标注的文本片段
function L([string]$t, [string]$c) { return @{ t = $t; c = $c } }

# 画一行面板内容：左内边距 + 若干着色片段 + 补白 + 右对齐文字 + 右内边距
function Write-Rich {
    param(
        [hashtable[]]$Parts = @(),
        [string]$Right = '',
        [string]$RightColor = 'DarkGray',
        [string]$BorderColor = 'DarkCyan',
        [switch]$Bare
    )
    $plain = ''
    foreach ($p in $Parts) { $plain += [string]$p.t }

    $inner = $Script:UI_W - 2 * $Script:UI_PAD
    $pad = $inner - (Get-DisplayWidth $plain) - (Get-DisplayWidth $Right)
    if ($pad -lt 0) { $pad = 0 }

    if (-not $Bare) {
        Write-Host '  ' -NoNewline
        Write-Host '|' -NoNewline -ForegroundColor $BorderColor
    }
    Write-Host (' ' * $Script:UI_PAD) -NoNewline
    foreach ($p in $Parts) {
        $t = [string]$p.t
        if ([string]::IsNullOrEmpty($t)) { continue }
        if ($p.c) { Write-Host $t -NoNewline -ForegroundColor $p.c }
        else      { Write-Host $t -NoNewline }
    }
    Write-Host (' ' * $pad) -NoNewline
    if ($Right -ne '') { Write-Host $Right -NoNewline -ForegroundColor $RightColor }
    Write-Host (' ' * $Script:UI_PAD) -NoNewline
    if ($Bare) { Write-Host '' } else { Write-Host '|' -ForegroundColor $BorderColor }
}

function Write-UiBlank { Write-Rich -Parts @() }

function Write-UiRule([string]$Color = 'DarkGray') {
    Write-Rich -Parts @((L ('-' * ($Script:UI_W - 2 * $Script:UI_PAD)) $Color))
}

function Write-PanelEdge([string]$Ch = '-', [string]$Color = 'DarkCyan') {
    Write-Host ('  +' + ($Ch * $Script:UI_W) + '+') -ForegroundColor $Color
}

function Write-UiText([string]$Text, [string]$Color = 'Gray', [string]$Right = '') {
    $max = $Script:UI_W - 2 * $Script:UI_PAD - (Get-DisplayWidth $Right)
    Write-Rich -Parts @((L (Format-Clip $Text $max) $Color)) -Right $Right
}

# 面板内的"键 / 值"行：键固定对齐，值着色，右侧可挂状态文字
function Write-Kv {
    param(
        [string]$Key,
        [string]$Value,
        [string]$ValueColor = 'Yellow',
        [string]$Right = '',
        [string]$RightColor = 'DarkGray',
        [string]$KeyColor = 'DarkGray'
    )
    $keyCol = 13
    $pad = $keyCol - (Get-DisplayWidth $Key)
    if ($pad -lt 1) { $pad = 1 }
    Write-Rich -Parts @(
        (L ('    ' + $Key + (' ' * $pad)) $KeyColor),
        (L $Value $ValueColor)
    ) -Right $Right -RightColor $RightColor
}

# 面板内的小标题行
function Write-SectionTitle([string]$Text, [string]$Color = 'Cyan') {
    Write-Rich -Parts @((L ('  ' + $Text) $Color))
}

# 通用结果卡片：标题 + 若干"键:值"行 + 结尾提示
function Write-ResultCard {
    param(
        [string]$Title,
        [hashtable[]]$Rows = @(),
        [string[]]$Notes = @(),
        [string]$TitleColor = 'Green'
    )
    Write-Host ''
    Write-PanelEdge '=' $C_Title
    Write-SectionTitle $Title $TitleColor
    Write-UiRule
    foreach ($r in $Rows) {
        $rc = 'Yellow'; if ($r.c) { $rc = $r.c }
        Write-Kv ([string]$r.k) ([string]$r.v) $rc
    }
    if ($Notes.Count -gt 0) {
        Write-UiRule
        foreach ($n in $Notes) { Write-UiText ('  ' + $n) $C_Hint }
    }
    Write-PanelEdge '=' $C_Title
}

# 三列的日志行：时间 | 来源 | 事件（列宽按显示列数算，中文不会错位）
function Write-LogRow([string]$Time, [string]$Source, [string]$Text, [string]$SourceColor = 'DarkGray') {
    $lead = 2; $tCol = 17; $sCol = 9
    $avail = $Script:UI_W - 2 * $Script:UI_PAD - $lead - $tCol - $sCol
    if ($avail -lt 10) { $avail = 10 }
    $t = Format-Clip $Time $tCol
    $s = Format-Clip $Source $sCol
    $tp = $tCol - (Get-DisplayWidth $t); if ($tp -lt 1) { $tp = 1 }
    $sp = $sCol - (Get-DisplayWidth $s); if ($sp -lt 1) { $sp = 1 }
    Write-Rich -Parts @(
        (L (' ' * $lead) $C_Dim),
        (L ($t + (' ' * $tp)) 'Gray'),
        (L ($s + (' ' * $sp)) $SourceColor),
        (L (Format-Clip $Text $avail) 'White')
    )
}

function Write-Banner {
    Write-Host ''
    Write-PanelEdge '=' $C_Title
    Write-UiBlank
    Write-Rich -Parts @((L '  A U T O P O W E R P R O   ' $C_Title), (L '自动开关机' $C_Dim))
    Write-Rich -Parts @((L '  定时开关机' $C_Hint), (L '  |  ' $C_Dim), (L '每 N 分钟自动重启' $C_Hint))
    Write-UiBlank
    Write-PanelEdge '=' $C_Title
}

function Write-StepHeader([int]$Index, [int]$Total, [string]$Title) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ('[ ' + $Index + ' / ' + $Total + ' ] ') -NoNewline -ForegroundColor $C_Accent
    Write-Host $Title -ForegroundColor $C_Key
}

function Write-Ok([string]$Text)   { Write-Host ('  [ OK ] ' + $Text) -ForegroundColor $C_Ok }
function Write-Warn2([string]$Text){ Write-Host ('  [ !! ] ' + $Text) -ForegroundColor $C_Warn }
function Write-Err2([string]$Text) { Write-Host ('  [ XX ] ' + $Text) -ForegroundColor $C_Err }
function Write-Info([string]$Text) { Write-Host ('  [ -- ] ' + $Text) -ForegroundColor $C_Hint }

function Pause-Back {
    Write-Host ''
    Read-Host '  回车返回主菜单' | Out-Null
}

# ===========================================================================
#  二、基础工具
# ===========================================================================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Exe @Arguments 2>&1 | Out-String)
        if ($null -eq $LASTEXITCODE) { $Script:LastNativeExit = 0 }
        else                         { $Script:LastNativeExit = [int]$LASTEXITCODE }
        return $text
    } catch {
        $Script:LastNativeExit = -1
        return ''
    } finally {
        $ErrorActionPreference = $prev
    }
}

# 只取标准输出，丢弃标准错误（避免报文被渲染成一大坨 PowerShell 错误记录）
function Invoke-NativeQuiet([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Exe @Arguments 2>$null | Out-String)
        if ($null -eq $LASTEXITCODE) { $Script:LastNativeExit = 0 }
        else                         { $Script:LastNativeExit = [int]$LASTEXITCODE }
        return $text
    } catch {
        $Script:LastNativeExit = -1
        return ''
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-NativeCode([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = (& $Exe @Arguments 2>&1)
        return $LASTEXITCODE
    } catch {
        return -1
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ===========================================================================
#  二·五、机器体检（台式机 / 笔记本自适应）
# ===========================================================================
$Script:Mach = $null

# 读取"允许唤醒定时器"策略（AC / DC）。
# powercfg 的输出是本地化的（中文系统显示"当前交流电源设置索引"），
# 所以这里只抓 0x 十六进制数值，不依赖任何界面文字。
function Get-WakeTimerPolicy {
    $txt = Invoke-NativeQuiet 'powercfg.exe' @('/q', 'SCHEME_CURRENT', $SUB_SLEEP, $SET_WAKETIMERS)
    $hex = [regex]::Matches($txt, '0x([0-9a-fA-F]{1,8})')
    $ac = $null; $dc = $null
    if ($hex.Count -ge 2) {
        $ac = [Convert]::ToInt32($hex[0].Groups[1].Value, 16)
        $dc = [Convert]::ToInt32($hex[1].Groups[1].Value, 16)
    } elseif ($hex.Count -eq 1) {
        $ac = [Convert]::ToInt32($hex[0].Groups[1].Value, 16)
    }
    return @{ Ac = $ac; Dc = $dc }
}

function Format-WakePolicy($Value) {
    if ($null -eq $Value) { return '未知' }
    if ($Value -eq 0) { return '禁止' }
    if ($Value -eq 2) { return '仅重要' }
    return '允许'
}

# 一次性采集本机信息并缓存（整个进程只查一遍）
# 每一类信息都是"多级兜底"：WMI → .NET → 注册表。这一点很重要 ——
# 精简系统 / 受限环境里 WMI 服务可能不可用，只靠 Get-CimInstance 会全部取空。
function Get-MachineInfo {
    if ($Script:Mach) { return $Script:Mach }

    $m = @{
        Chassis = '未知'; IsLaptop = $false; Vendor = ''; Model = ''
        HasBattery = $false; OnBattery = $false; BatteryPct = $null
        HibernateReady = $false; OS = ''
        WakeAc = $null; WakeDc = $null
    }

    # --- 电池 / 供电：优先 .NET PowerStatus（不依赖 WMI 服务）---
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        if ($ps.BatteryChargeStatus -ne [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) {
            $m.HasBattery = $true
            $pct = [double]$ps.BatteryLifePercent
            if ($pct -ge 0 -and $pct -le 1) { $m.BatteryPct = [int][math]::Round($pct * 100) }
            if ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline) { $m.OnBattery = $true }
        }
    } catch { }

    if (-not $m.HasBattery) {
        try {
            $bat = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
            if ($bat.Count -gt 0) {
                $m.HasBattery = $true
                if ($null -ne $bat[0].EstimatedChargeRemaining) { $m.BatteryPct = [int]$bat[0].EstimatedChargeRemaining }
                try {
                    $bs = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryStatus' -ErrorAction Stop)
                    if ($bs.Count -gt 0 -and $null -ne $bs[0].PowerOnline) { $m.OnBattery = -not [bool]$bs[0].PowerOnline }
                } catch { }
            }
        } catch { }
    }

    # --- 机型：机箱类型（WMI）优先；取不到就用"有没有电池"判断 ---
    try {
        $types = @()
        foreach ($e in @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop)) {
            if ($e.ChassisTypes) { foreach ($t in $e.ChassisTypes) { $types += [int]$t } }
        }
        $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
        $tower    = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24)
        if (@($types | Where-Object { $portable -contains $_ }).Count -gt 0) {
            $m.IsLaptop = $true
        } elseif (@($types | Where-Object { $tower -contains $_ }).Count -gt 0) {
            $m.IsLaptop = $false
        }
    } catch { }
    # 有电池就按笔记本对待：宁可多给电池相关的提醒，也不要漏掉那些坑
    if ($m.HasBattery) { $m.IsLaptop = $true }
    if ($m.IsLaptop) { $m.Chassis = '笔记本' } else { $m.Chassis = '台式机' }

    # --- 厂商 / 型号：WMI 优先，退化到注册表 BIOS 键 ---
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $m.Vendor = ([string]$cs.Manufacturer).Trim()
        $m.Model  = ([string]$cs.Model).Trim()
    } catch { }
    if ($m.Vendor -eq '' -or $m.Model -eq '') {
        try {
            $bios = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop
            if ($m.Vendor -eq '' -and $bios.SystemManufacturer) { $m.Vendor = ([string]$bios.SystemManufacturer).Trim() }
            if ($m.Model  -eq '' -and $bios.SystemProductName)  { $m.Model  = ([string]$bios.SystemProductName).Trim() }
        } catch { }
    }

    # --- 操作系统：WMI 优先，退化到注册表 CurrentVersion ---
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $m.OS = ([string]$os.Caption).Trim()
    } catch { }
    if ($m.OS -eq '') {
        try {
            $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $name = ([string]$cv.ProductName).Trim()
            $build = 0
            if ($cv.CurrentBuild) { $build = [int]$cv.CurrentBuild }
            # 注册表里的 ProductName 在 Win11 上常常还残留 "Windows 10"，按 build 号纠正
            if ($build -ge 22000 -and $name -match 'Windows 10') { $name = $name -replace 'Windows 10', 'Windows 11' }
            $m.OS = $name
            if ($cv.DisplayVersion) { $m.OS += '  ' + ([string]$cv.DisplayVersion) }
            if ($build -gt 0) { $m.OS += '  (Build ' + $build + ')' }
        } catch { }
    }
    if ($m.OS -eq '') { $m.OS = '未知' }

    # --- 休眠是否已启用：hiberfil.sys 在不在，与界面语言无关，最可靠 ---
    try { $m.HibernateReady = (Test-Path -LiteralPath ($env:SystemDrive + '\hiberfil.sys')) } catch { }

    # --- 唤醒定时器策略 ---
    $wp = Get-WakeTimerPolicy
    $m.WakeAc = $wp.Ac
    $m.WakeDc = $wp.Dc

    $Script:Mach = $m
    return $m
}

# 菜单里用的一行机型摘要
function Get-MachineLine {
    $m = Get-MachineInfo
    $line = $m.Chassis
    if ($m.HasBattery) {
        if ($m.OnBattery) { $line += ' · 使用电池' } else { $line += ' · 已接电源' }
    } else {
        $line += ' · 交流电'
    }
    if ($m.HibernateReady) { $line += ' · 休眠可用' } else { $line += ' · 休眠未启用' }
    return $line
}

# 开屏环境体检面板
function Show-EnvironmentPanel {
    $m = Get-MachineInfo
    $isAdmin = Test-IsAdmin

    Write-Host ''
    Write-PanelEdge '=' $C_Title
    Write-SectionTitle '环境体检' $C_Title
    Write-UiRule

    $model = (($m.Vendor + ' ' + $m.Model) -replace '\s+', ' ').Trim()
    $chassisTxt = $m.Chassis
    if ($model -ne '') { $chassisTxt = $chassisTxt + '   ' + (Format-Clip $model 36) }
    Write-Kv '机型' $chassisTxt 'White'

    if ($m.HasBattery) {
        $pwr = '正在使用电池'; $pwrCol = $C_Warn
        if (-not $m.OnBattery) { $pwr = '已接交流电'; $pwrCol = $C_Ok }
        if ($null -ne $m.BatteryPct) { $pwr = $pwr + '    电量 ' + $m.BatteryPct + '%' }
        Write-Kv '供电' $pwr $pwrCol
    } else {
        Write-Kv '供电' '交流电（无电池）' $C_Ok
    }

    Write-Kv '系统' (Format-Clip $m.OS 46) 'Gray'

    $permTxt = '普通用户（会自动提权）'; $permCol = $C_Warn
    if ($isAdmin) { $permTxt = '管理员'; $permCol = $C_Ok }
    Write-Kv '权限' $permTxt $permCol

    $hibTxt = '未启用（本工具会自动尝试打开）'; $hibCol = $C_Warn
    if ($m.HibernateReady) { $hibTxt = '可用'; $hibCol = $C_Ok }
    Write-Kv '休眠' $hibTxt $hibCol

    Write-Kv '唤醒定时器' ('接电源 ' + (Format-WakePolicy $m.WakeAc) + '      用电池 ' + (Format-WakePolicy $m.WakeDc)) 'Gray'

    $pb = Get-PlanBadge
    $cb = Get-CycleBadge
    Write-Kv '定时开关机' $pb.Text $pb.Color
    Write-Kv '循环重启' $cb.Text $cb.Color

    # --- 按机型给出针对性提醒（每条都控制在面板宽度内，避免被裁剪）---
    $tips = @()
    if ($m.IsLaptop) {
        $tips += '笔记本：定时唤醒建议插电源，电池下部分机型会限制唤醒。'
        if ($m.OnBattery) { $tips += '当前在用电池 —— 整夜唤醒测试前请先插上电源。' }
        $tips += '「合盖」设置会覆盖本计划：合盖睡眠/关机时唤醒任务不执行。'
    } else {
        if (-not $m.HibernateReady) { $tips += '本机休眠未启用，选「休眠」时工具会自动尝试打开。' }
        $tips += '台式机：待机时别断插排/电源开关，否则唤醒定时器失效。'
    }
    Write-UiRule
    foreach ($t in $tips) { Write-UiText ('  · ' + $t) $C_Hint }

    Write-PanelEdge '=' $C_Title
}

# ===========================================================================
#  三、输入解析
# ===========================================================================
function ConvertTo-TimeOfDay([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = ($Text.Trim() -replace '[：:．.。]', ':')
    if ($t -match '^(\d{1,2}):(\d{1,2}):(\d{1,2})$') { $t = $Matches[1] + ':' + $Matches[2] }

    $h = -1; $m = -1
    if ($t -match '^(\d{1,2}):(\d{1,2})$') { $h = [int]$Matches[1]; $m = [int]$Matches[2] }
    elseif ($t -match '^(\d{1,2})$')       { $h = [int]$Matches[1]; $m = 0 }
    elseif ($t -match '^(\d{3,4})$') {
        $d = $t.PadLeft(4, '0'); $h = [int]$d.Substring(0, 2); $m = [int]$d.Substring(2, 2)
    } else { return $null }

    if ($h -lt 0 -or $h -gt 23) { return $null }
    if ($m -lt 0 -or $m -gt 59) { return $null }
    return [datetime]::Today.AddHours($h).AddMinutes($m)
}

function Format-TimeOfDay([datetime]$Value) { $Value.ToString('HH:mm') }

$Script:WeekMap = @{
    '1' = [System.DayOfWeek]::Monday;    '2' = [System.DayOfWeek]::Tuesday
    '3' = [System.DayOfWeek]::Wednesday; '4' = [System.DayOfWeek]::Thursday
    '5' = [System.DayOfWeek]::Friday;    '6' = [System.DayOfWeek]::Saturday
    '7' = [System.DayOfWeek]::Sunday
}
$Script:WeekCn = @{
    '1' = '一'; '2' = '二'; '3' = '三'; '4' = '四'; '5' = '五'; '6' = '六'; '7' = '日'
}

function ConvertTo-Weekdays([string]$Text) {
    $list = New-Object System.Collections.ArrayList
    foreach ($piece in ($Text -split '[,，、\s]+')) {
        $p = $piece.Trim()
        if ($p -eq '') { continue }
        if (-not $Script:WeekMap.ContainsKey($p)) { throw "星期取值非法：'$p'（应为 1-7，1=周一）" }
        if (-not $list.Contains($Script:WeekMap[$p])) { [void]$list.Add($Script:WeekMap[$p]) }
    }
    if ($list.Count -eq 0) { throw '至少选择一天' }
    return $list.ToArray()
}

function Get-WeekdaysText([string]$Text) {
    $out = @()
    foreach ($piece in ($Text -split '[,，、\s]+')) {
        $p = $piece.Trim()
        if ($p -ne '' -and $Script:WeekCn.ContainsKey($p)) { $out += $Script:WeekCn[$p] }
    }
    if ($out.Count -eq 0) { return '未选择' }
    return ('周' + ($out -join ' 周'))
}

# --- 交互式输入（一律支持 q 取消，返回 $null）------------------------------
function Write-InputHint([string]$Extra = '') {
    $t = '回车 = 用默认值     q = 取消本项'
    if ($Extra -ne '') { $t = $Extra + '      ' + $t }
    Write-Host ('        ' + $t) -ForegroundColor $C_Dim
}

function Read-TimeOfDayInput([string]$Prompt, [string]$Default) {
    Write-InputHint '可写 23:00 或 2300 或 23'
    while ($true) {
        Write-Host '  ' -NoNewline
        Write-Host '>' -NoNewline -ForegroundColor $C_Accent
        $raw = Read-Host " $Prompt  [回车 = $Default]"
        if ($raw -eq 'q' -or $raw -eq 'Q') { return $null }
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $Default }
        $v = ConvertTo-TimeOfDay $raw
        if ($v) { return $v }
        Write-Warn2 "时间格式不对：请用 HH:mm（24 小时制），例如 $Default"
    }
}

function Read-IntInRange([string]$Prompt, [int]$Default, [int]$Min, [int]$Max, [string]$Hint = '') {
    $extra = ($Min.ToString() + ' ~ ' + $Max.ToString() + ' 之间的整数')
    if ($Hint -ne '') { $extra = $Hint }
    Write-InputHint $extra
    while ($true) {
        Write-Host '  ' -NoNewline
        Write-Host '>' -NoNewline -ForegroundColor $C_Accent
        $raw = Read-Host " $Prompt  [回车 = $Default]"
        if ($raw -eq 'q' -or $raw -eq 'Q') { return $null }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $v = 0
        if ([int]::TryParse($raw.Trim(), [ref]$v)) {
            if ($v -ge $Min -and $v -le $Max) { return $v }
        }
        Write-Warn2 ("超出范围：请输入 $Min ~ $Max 之间的整数")
    }
}

function Read-Choice([string]$Prompt, [string[]]$Keys, [string]$Default) {
    Write-InputHint ('可选 ' + ($Keys -join ' / '))
    while ($true) {
        Write-Host '  ' -NoNewline
        Write-Host '>' -NoNewline -ForegroundColor $C_Accent
        $raw = Read-Host " $Prompt  [回车 = $Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $Default }
        $k = $raw.Trim().ToLower()
        if ($k -eq 'q') { return 'q' }
        if ($Keys -contains $k) { return $k }
        Write-Warn2 ('输入无效：可选 ' + ($Keys -join ' / ') + '，或 q 取消')
    }
}

function Confirm-Yes([string]$Prompt = '确认执行？') {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host $Prompt -NoNewline -ForegroundColor $C_Key
    Write-Host '   [ Y = 是 / N = 否 / 回车 = 是 / q = 取消 ]' -ForegroundColor $C_Dim
    Write-Host '  ' -NoNewline
    Write-Host '>' -NoNewline -ForegroundColor $C_Accent
    $r = Read-Host ' '
    if ($r -eq 'q' -or $r -eq 'Q') { return $false }
    if ([string]::IsNullOrWhiteSpace($r)) { return $true }
    return ($r -match '^[Yy]')
}

# ===========================================================================
#  四、自动提权
# ===========================================================================
function Start-ElevatedSelf {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        Stop-WithMessage '无法定位 AutoPowerPro.ps1 的完整路径，提权中止。请把整个文件夹一起复制。'
    }
    # Start-Process -ArgumentList 是空格拼接且不加引号，路径含空格会被截断 → 自己补引号
    $quotedPath = '"' + $scriptPath + '"'
    $childArgs = New-Object System.Collections.ArrayList
    [void]$childArgs.Add('-NoProfile')
    [void]$childArgs.Add('-ExecutionPolicy'); [void]$childArgs.Add('Bypass')
    [void]$childArgs.Add('-File');            [void]$childArgs.Add($quotedPath)
    if ($PSBoundParameters -and $PSBoundParameters.Count -gt 0) {
        foreach ($key in $PSBoundParameters.Keys) {
            $value = $PSBoundParameters[$key]
            if ($value -is [switch]) {
                if ($value.IsPresent) { [void]$childArgs.Add('-' + $key) }
            } else {
                [void]$childArgs.Add('-' + $key)
                [void]$childArgs.Add('"' + ([string]$value) + '"')
            }
        }
    }
    Write-Host ''
    Write-Info '需要管理员权限，正在申请提权...'
    Write-Info '马上会弹出 UAC 窗口，请点「是」；随后会打开一个新的管理员窗口。'
    Write-Host ''
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $childArgs.ToArray() -ErrorAction Stop
        return $true
    } catch {
        Write-Host ''
        Write-Err2 ('提权失败或被取消：' + $_.Exception.Message)
        return $false
    }
}

# ===========================================================================
#  五、电源相关
# ===========================================================================
function Enable-WakeTimers {
    $r1 = Invoke-NativeQuiet 'powercfg.exe' @('/SETACVALUEINDEX', 'SCHEME_CURRENT', $SUB_SLEEP, $SET_WAKETIMERS, '1')
    $r2 = Invoke-NativeQuiet 'powercfg.exe' @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', $SUB_SLEEP, $SET_WAKETIMERS, '1')
    $r3 = Invoke-NativeQuiet 'powercfg.exe' @('/SETACTIVE', 'SCHEME_CURRENT')
    $out = @($r1, $r2, $r3) | Where-Object { $_ -and $_.Trim() -ne '' }
    if ($out.Count -gt 0) {
        Write-Warn2 '设置"允许唤醒定时器"时系统有提示（可能被组策略锁定），继续安装：'
        $out | ForEach-Object { Write-Host ('         ' + $_.Trim()) -ForegroundColor $C_Dim }
    } else {
        Write-Ok '已打开电源方案的「允许唤醒定时器」'
    }
}

function Ensure-Hibernation {
    $code = Invoke-NativeCode 'powercfg.exe' @('/hibernate', 'on')
    if ($code -eq 0) {
        Write-Ok '休眠功能可用'
        return $true
    }
    Write-Warn2 "无法启用休眠（powercfg 退出码 $code）：可能被组策略禁用 / 系统盘空间不足 / 精简系统"
    Write-Warn2 '这种情况下"休眠"会失败，建议改用「睡眠」。'
    return $false
}

# 写出"记录助手 + 每个任务的执行外壳"。
#
# 为什么要外壳脚本：计划任务的动作如果直接写 shutdown.exe，就没有地方插入记录。
# 外壳让"先记一笔时间戳，再执行真正的动作"成为可能，于是关机/重启/唤醒
# 三类操作全部可追溯。外壳内容保持纯 ASCII，任何区域设置的机器都能跑。
function Write-TaskScripts([int]$RestartBuffer = 60) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

    # 记录助手：追加一行 "yyyy-MM-dd HH:mm:ss TAG"（ISO 风格，便于排序和解析）
    $logLines = @(
        '@echo off',
        'rem AutoPowerPro - append one timestamped event line (internal).',
        'rem usage: log.cmd <TAG>',
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Add-Content -LiteralPath ''%~dp0events.log'' -Value ((Get-Date).ToString(''yyyy-MM-dd HH:mm:ss'') + '' %~1'')" >nul 2>&1'
    )
    Set-Content -LiteralPath $LogCmd -Value $logLines -Encoding ASCII

    $d = $DataDir
    $wrappers = [ordered]@{
        'off-hibernate.cmd' = @(
            '@echo off',
            'rem AutoPowerPro task: scheduled hibernate',
            'call "%~dp0log.cmd" off-hibernate',
            'shutdown.exe /h'
        )
        'off-sleep.cmd' = @(
            '@echo off',
            'rem AutoPowerPro task: scheduled sleep',
            'call "%~dp0log.cmd" off-sleep',
            'rundll32.exe powrprof.dll,SetSuspendState 0,1,0'
        )
        'off-shutdown.cmd' = @(
            '@echo off',
            'rem AutoPowerPro task: scheduled shutdown (120s grace)',
            'call "%~dp0log.cmd" off-shutdown',
            'shutdown.exe /s /t 120 /c "AutoPowerPro scheduled shutdown - run shutdown /a to cancel"'
        )
        'wake.cmd' = @(
            '@echo off',
            'rem AutoPowerPro task: scheduled wake (records the time only)',
            'call "%~dp0log.cmd" wake'
        )
        'restart.cmd' = @(
            '@echo off',
            'rem AutoPowerPro task: cycle restart',
            'call "%~dp0log.cmd" restart',
            ('shutdown.exe /r /t ' + $RestartBuffer.ToString() + ' /c "AutoPowerPro cycle restart"')
        )
    }
    foreach ($name in $wrappers.Keys) {
        Set-Content -LiteralPath (Join-Path $d $name) -Value $wrappers[$name] -Encoding ASCII
    }
    return $true
}

# 关机任务的动作 = 调外壳（外壳里先记录、再关机/休眠/睡眠）
function Get-OffAction([string]$Kind) {
    $wrap = 'off-hibernate.cmd'
    if ($Kind -eq 'Sleep')    { $wrap = 'off-sleep.cmd' }
    if ($Kind -eq 'Shutdown') { $wrap = 'off-shutdown.cmd' }
    return (New-ScheduledTaskAction -Execute 'cmd.exe' `
        -Argument ('/c "' + (Join-Path $DataDir $wrap) + '"'))
}

# ===========================================================================
#  六、任务组装
# ===========================================================================
function New-TriggerFor([datetime]$At, [string]$DaysKind, [System.DayOfWeek[]]$Dow) {
    switch ($DaysKind) {
        'Daily'    { return (New-ScheduledTaskTrigger -Daily -At $At) }
        'Weekdays' { return (New-ScheduledTaskTrigger -Weekly -At $At -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday) }
        'Custom'   { return (New-ScheduledTaskTrigger -Weekly -At $At -DaysOfWeek $Dow) }
        default    { throw "未知的 Days：$DaysKind" }
    }
}

function Get-PlanSettings([bool]$Wake) {
    $common = @{
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        Compatibility              = 'Win8'
        MultipleInstances          = 'IgnoreNew'
        ExecutionTimeLimit         = (New-TimeSpan -Minutes 30)
    }
    if ($Wake) {
        $common['WakeToRun'] = $true
        $common['StartWhenAvailable'] = $true
    } else {
        # 关机任务故意不补跑：否则机器关机期间"错过"的触发点会在下次开机时立刻执行，当场关机
        $common['StartWhenAvailable'] = $false
    }
    return (New-ScheduledTaskSettingsSet @common)
}

# 循环重启任务的设置。与开关机任务分开，因为这里有两个"必须为 false"的项：
#   StartWhenAvailable = false —— 绝不补跑。否则机器关机/休眠期间错过的那一次重启，
#                                 会在下次开机后立刻执行 → 每次开机都被重启一次 = 死循环。
#   WakeToRun          = false —— 绝不把休眠/睡眠中的机器叫醒来重启。
function Get-CycleSettings {
    $s = @{
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        Compatibility              = 'Win8'
        MultipleInstances          = 'IgnoreNew'
        ExecutionTimeLimit         = (New-TimeSpan -Minutes 30)
        StartWhenAvailable         = $false
        WakeToRun                  = $false
    }
    return (New-ScheduledTaskSettingsSet @s)
}

function Get-SystemPrincipal {
    return (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest)
}

# --- 状态摘要 ---------------------------------------------------------------
function Get-TaskSafe([string]$Name) {
    return (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue)
}

function Get-OffModeName([string]$Exe, [string]$Arguments) {
    $a = ''
    if ($Arguments) { $a = $Arguments }
    # 新版：动作是外壳脚本，按外壳文件名判模式
    if ($a -match 'off-hibernate')   { return '休眠' }
    if ($a -match 'off-sleep')       { return '睡眠' }
    if ($a -match 'off-shutdown')    { return '关机' }
    # 兼容旧版安装（动作直接是 shutdown.exe / rundll32）
    if ($a -match '^\s*/h\b')        { return '休眠' }
    if ($a -match 'SetSuspendState') { return '睡眠' }
    if ($a -match '^\s*/s\b')        { return '关机' }
    return '未知'
}

function ConvertFrom-IsoDuration([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
    if (-not $m.Success) { return $null }
    $min = 0.0
    if ($m.Groups[1].Success) { $min += [double]$m.Groups[1].Value * 1440 }
    if ($m.Groups[2].Success) { $min += [double]$m.Groups[2].Value * 60 }
    if ($m.Groups[3].Success) { $min += [double]$m.Groups[3].Value }
    if ($min -eq 0 -and $m.Groups[4].Success) { $min = [double]$m.Groups[4].Value / 60.0 }
    return $min
}

function Format-Minutes([double]$Minutes) {
    $m = [int][math]::Round($Minutes)
    if ($m -lt 60) { return ($m.ToString() + ' 分钟') }
    $h = [int][math]::Floor($m / 60)
    $r = $m % 60
    if ($r -eq 0) { return ($h.ToString() + ' 小时') }
    return ($h.ToString() + ' 小时 ' + $r.ToString() + ' 分钟')
}

function Get-PlanBadge {
    $t = Get-TaskSafe $T_OFF
    if (-not $t) { return @{ Text = '未安装'; Color = $C_Dim } }
    $mode = Get-OffModeName $t.Actions[0].Execute $t.Actions[0].Arguments
    return @{ Text = ('已安装 - ' + $mode); Color = $C_Ok }
}

function Get-CycleBadge {
    $t = Get-TaskSafe $T_RESTART
    if (-not $t) { return @{ Text = '未安装'; Color = $C_Dim } }
    $iv = $null
    try { $iv = $t.Triggers[0].Repetition.Interval } catch { }
    $min = $null
    if ($iv) { $min = ConvertFrom-IsoDuration ([string]$iv) }
    if ($min -and $min -gt 0) { return @{ Text = ('已安装 - 每 ' + (Format-Minutes $min)); Color = $C_Ok } }
    return @{ Text = '已安装'; Color = $C_Ok }
}

# ===========================================================================
#  七、功能 1 —— 定时开关机
# ===========================================================================
function Install-ScheduledPlan {
    Write-Host ''
    Write-Host '  定时开关机' -ForegroundColor $C_Title
    Write-Host '  到点关机，到点唤醒。中途随时输入 q 可以取消。' -ForegroundColor $C_Dim

    # --- 步骤 1/4：关机时间 ---
    Write-StepHeader 1 4 '每天几点关机？'
    Write-Host '        例如 23:00，也可以直接打 2300' -ForegroundColor $C_Dim
    $off = Read-TimeOfDayInput '关机时间' '23:00'
    if (-not $off) { Write-Info '已取消'; return }

    # --- 步骤 2/4：开机时间 ---
    Write-StepHeader 2 4 '每天几点开机（唤醒）？'
    $on = Read-TimeOfDayInput '开机时间' '07:30'
    if (-not $on) { Write-Info '已取消'; return }

    # --- 步骤 3/4：关机方式 ---
    Write-StepHeader 3 4 '到点后怎么"关"？'
    Write-Host '        [1] 休眠   真正断电，状态完整保留，唤醒最可靠   - 推荐' -ForegroundColor $C_Key
    Write-Host '        [2] 睡眠   唤醒只要 1~2 秒，但内存一直供电耗电' -ForegroundColor $C_Hint
    Write-Host '        [3] 关机   最省电，但必须靠 BIOS 定时开机才能自己起来' -ForegroundColor $C_Hint
    $modeKey = Read-Choice '选择' @('1', '2', '3') '1'
    if ($modeKey -eq 'q') { Write-Info '已取消'; return }
    $mode = switch ($modeKey) { '1' { 'Hibernate' } '2' { 'Sleep' } '3' { 'Shutdown' } }

    # --- 步骤 4/4：生效日 ---
    Write-StepHeader 4 4 '哪几天生效？'
    Write-Host '        [1] 每天' -ForegroundColor $C_Key
    Write-Host '        [2] 仅工作日（周一 ~ 周五）   - 推荐' -ForegroundColor $C_Key
    Write-Host '        [3] 自定义星期' -ForegroundColor $C_Hint
    $dayKey = Read-Choice '选择' @('1', '2', '3') '2'
    if ($dayKey -eq 'q') { Write-Info '已取消'; return }

    $daySel = @{ Kind = 'Weekdays'; Dow = $null; Text = '' }
    if ($dayKey -eq '1') { $daySel = @{ Kind = 'Daily'; Dow = $null; Text = '' } }
    elseif ($dayKey -eq '3') {
        while ($true) {
            Write-Host '        输入星期数字，逗号分隔。1=周一 2=周二 ... 7=周日' -ForegroundColor $C_Dim
            Write-Host '  ' -NoNewline
            Write-Host '>' -NoNewline -ForegroundColor $C_Accent
            $w = Read-Host ' 例如 1,3,5   [回车 = 1,2,3,4,5]'
            if ($w -eq 'q' -or $w -eq 'Q') { Write-Info '已取消'; return }
            if ([string]::IsNullOrWhiteSpace($w)) { $w = '1,2,3,4,5' }
            try {
                $daySel = @{ Kind = 'Custom'; Dow = (ConvertTo-Weekdays $w); Text = $w }
                break
            } catch {
                Write-Warn2 $_.Exception.Message
            }
        }
    }

    # --- 确认卡片 ---
    $now = Get-Date
    $offNext = $off; if ($offNext -le $now) { $offNext = $offNext.AddDays(1) }
    $onNext  = $on;  if ($onNext  -le $now) { $onNext  = $onNext.AddDays(1) }
    $offLabel = '明天'; if ($offNext.Date -eq $now.Date) { $offLabel = '今天' }
    $onLabel  = '明天'; if ($onNext.Date  -eq $now.Date) { $onLabel  = '今天' }

    $dayText = '每天'
    if ($daySel.Kind -eq 'Weekdays') { $dayText = '仅工作日（周一 ~ 周五）' }
    if ($daySel.Kind -eq 'Custom')   { $dayText = '自定义：' + (Get-WeekdaysText $daySel.Text) }

    $modeName = @{ 'Hibernate' = '休眠'; 'Sleep' = '睡眠'; 'Shutdown' = '关机' }[$mode]

    Write-Host ''
    Write-PanelEdge '-' $C_Border
    Write-UiText '  即将安装' $C_Title
    Write-UiRule
    Write-Rich -Parts @((L '    关机时间    ' $C_Dim), (L (Format-TimeOfDay $off) $C_Val))
    Write-Rich -Parts @((L '    开机时间    ' $C_Dim), (L (Format-TimeOfDay $on)  $C_Val))
    Write-Rich -Parts @((L '    关机方式    ' $C_Dim), (L $modeName $C_Val))
    Write-Rich -Parts @((L '    生效日      ' $C_Dim), (L $dayText $C_Val))
    Write-UiRule
    Write-Rich -Parts @((L '    首次触发    ' $C_Dim),
                        (L ($offLabel + ' ' + (Format-TimeOfDay $off) + ' 关机') $C_Hint))
    Write-Rich -Parts @((L '                ' $C_Dim),
                        (L ($onLabel  + ' ' + (Format-TimeOfDay $on)  + ' 唤醒') $C_Hint))
    Write-PanelEdge '-' $C_Border

    if ($mode -eq 'Shutdown') {
        Write-Host ''
        Write-Warn2 '你选了「关机」：关机之后软件就叫不醒它了，'
        Write-Warn2 '必须去 BIOS 开 RTC 定时开机（每天那个时间点），否则关了就起不来。'
    }
    if ($daySel.Kind -eq 'Weekdays') {
        Write-Host ''
        Write-Warn2 '选了「仅工作日」：周五晚关机后，下一次自动开机是周一早上，'
        Write-Warn2 '整个周末电脑都是关着的。如果要周末也开机，请选「每天」。'
    }
    if ($off -le $now) {
        Write-Host ''
        Write-Warn2 (('关机时间 ' + (Format-TimeOfDay $off) + ' 今天已经过了，首次触发顺延到明天。'))
        Write-Warn2 ('想马上试一次，就填一个还没到的时间，例如 ' + $now.AddMinutes(3).ToString('HH:mm') + '。')
    }

    # --- 机型 / 电源能力预检：在确认之前就把"这台机器会怎样"说清楚 ---
    $m = Get-MachineInfo
    Write-Host ''
    if ($mode -eq 'Hibernate' -and -not $m.HibernateReady) {
        Write-Warn2 '本机休眠当前是关闭的：安装时会自动尝试打开（会在系统盘生成 hiberfil.sys）。'
        Write-Warn2 '若打不开，休眠会失败、机器不会自动关，届时请改用「睡眠」。'
    }
    if ($mode -eq 'Sleep' -and $m.IsLaptop) {
        Write-Warn2 '笔记本选「睡眠」：唤醒最快，但内存持续供电，拔电会丢状态。'
    }
    if ($m.IsLaptop) {
        Write-Warn2 '笔记本提醒：做整夜唤醒测试前请插上电源；'
        Write-Warn2 '合盖若设为「睡眠/关机」，唤醒任务不会执行 —— 请确认合盖设置。'
        if ($m.OnBattery) { Write-Warn2 '当前正在用电池，唤醒定时器可能被机型限制。' }
    } else {
        Write-Warn2 '台式机提醒：待机时别断插排/电源开关，否则唤醒定时器失效。'
    }
    if ($null -ne $m.WakeDc -and $m.WakeDc -eq 0 -and $m.IsLaptop) {
        Write-Warn2 '检测到「用电池时的唤醒定时器」当前是禁止的，安装会自动打开它。'
    }

    if (-not (Confirm-Yes '确认安装？')) { Write-Info '已取消'; return }

    # --- 落地 ---
    Write-Host ''
    if ($mode -eq 'Hibernate') { $null = Ensure-Hibernation }
    Enable-WakeTimers
    Write-TaskScripts | Out-Null
    Write-Info ('运行记录：' + $EventLog)

    $principal = Get-SystemPrincipal

    Write-Info ('创建任务 ' + $T_OFF + ' ...')
    Register-ScheduledTask -TaskName $T_OFF -Force `
        -Action (Get-OffAction $mode) `
        -Trigger (New-TriggerFor -At $off -DaysKind $daySel.Kind -Dow $daySel.Dow) `
        -Settings (Get-PlanSettings $false) -Principal $principal `
        -Description 'AutoPowerPro：定时关机/休眠/睡眠' | Out-Null
    Write-Ok ('已创建  ' + $T_OFF + '    ' + (Format-TimeOfDay $off) + '  ' + $modeName)

    Write-Info ('创建任务 ' + $T_ON + ' ...')
    Register-ScheduledTask -TaskName $T_ON -Force `
        -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + (Join-Path $DataDir 'wake.cmd') + '"')) `
        -Trigger (New-TriggerFor -At $on -DaysKind $daySel.Kind -Dow $daySel.Dow) `
        -Settings (Get-PlanSettings $true) -Principal $principal `
        -Description 'AutoPowerPro：定时唤醒（仅在休眠/睡眠状态下有效）' | Out-Null
    Write-Ok ('已创建  ' + $T_ON + '    ' + (Format-TimeOfDay $on) + '  到点唤醒')

    # --- 结果卡片：装了什么、什么时候生效、怎么撤 ---
    $offT = Get-TaskSafe $T_OFF
    $onT  = Get-TaskSafe $T_ON
    $offNextRun = '（读取失败）'
    $onNextRun  = '（读取失败）'
    try { $offNextRun = [string](($offT | Get-ScheduledTaskInfo).NextRunTime) } catch { }
    try { $onNextRun  = [string](($onT  | Get-ScheduledTaskInfo).NextRunTime) } catch { }

    $notes = @()
    if ($mode -eq 'Hibernate') {
        $notes += '到点是「休眠」：真正断电、状态保留，靠唤醒定时器自己醒来。'
    } elseif ($mode -eq 'Sleep') {
        $notes += '到点是「睡眠」：唤醒最快，但一直耗电；拔电会丢状态。'
    } else {
        $notes += '到点是「关机」：必须先在 BIOS 开 RTC 定时开机，否则关了就起不来。'
    }
    $notes += ('彻底取消：主菜单 [5] 卸载全部（或运行  schtasks /Delete /TN ' + $T_OFF + ' /F）')
    $notes += '想回看什么时候执行的：主菜单 [4] 运行记录。'

    Write-ResultCard -Title '安装完成' -Rows @(
        @{ k = '关机任务'; v = ((Format-TimeOfDay $off) + '  ' + $modeName + '    ' + $dayText) },
        @{ k = '下次关机'; v = $offNextRun },
        @{ k = '唤醒任务'; v = ((Format-TimeOfDay $on) + '  唤醒    ' + $dayText) },
        @{ k = '下次唤醒'; v = $onNextRun },
        @{ k = '运行记录'; v = $EventLog; c = 'Gray' }
    ) -Notes $notes
}

# ===========================================================================
#  八、功能 2 —— 每 N 分钟自动重启
# ===========================================================================
function Install-RestartCycle {
    Write-Host ''
    Write-Host '  每 N 分钟自动重启' -ForegroundColor $C_Title
    Write-Host '  纯软件实现，等于"关机 + 自动开机"，但全程不断电。' -ForegroundColor $C_Dim

    Write-StepHeader 1 2 '每隔多少分钟重启一次？'
    Write-Host '        常见：30 分钟 / 60 分钟 / 120 分钟' -ForegroundColor $C_Dim
    $n = Read-IntInRange '间隔分钟数' 30 5 1439 '不小于 5（太小会导致机器刚起来就被重启）'
    if (-not $n) { Write-Info '已取消'; return }

    Write-StepHeader 2 2 '重启前留多少秒缓冲？'
    Write-Host '        缓冲期内可以执行  shutdown /a  取消本次重启' -ForegroundColor $C_Dim
    $buffer = Read-IntInRange '缓冲秒数' 60 5 600 '不小于 5（0 秒等于没机会取消）'
    if ($null -eq $buffer) { Write-Info '已取消'; return }

    # --- 确认卡片 ---
    $startAt = (Get-Date).AddMinutes($n)
    Write-Host ''
    Write-PanelEdge '-' $C_Border
    Write-UiText '  即将安装' $C_Title
    Write-UiRule
    Write-Rich -Parts @((L '    重启间隔    ' $C_Dim), (L (Format-Minutes $n) $C_Val))
    Write-Rich -Parts @((L '    缓冲时间    ' $C_Dim), (L ($buffer.ToString() + ' 秒') $C_Val))
    Write-UiRule
    Write-Rich -Parts @((L '    执行动作    ' $C_Dim),
                        (L ('restart.cmd  ->  shutdown.exe /r /t ' + $buffer.ToString()) $C_Hint))
    Write-Rich -Parts @((L '    首次重启    ' $C_Dim), (L ($startAt.ToString('MM-dd HH:mm')) $C_Val))
    Write-Rich -Parts @((L '    运行身份    ' $C_Dim), (L 'SYSTEM（不依赖登录密码）' $C_Hint))
    Write-Rich -Parts @((L '    运行记录    ' $C_Dim), (L '每次触发都会记进「运行记录」' $C_Hint))
    Write-PanelEdge '-' $C_Border

    # --- 机型相关提醒 ---
    $m = Get-MachineInfo
    Write-Host ''
    Write-Warn2 '装好后工作会周期性中断，请先保存好文档、关掉不必要的程序。'
    if ($m.IsLaptop) {
        Write-Warn2 '笔记本：反复重启会持续消耗电池，建议插着电源使用本功能。'
        if ($m.OnBattery) { Write-Warn2 '当前正在用电池 —— 建议插上电源再安装。' }
    }

    # --- 与定时开关机冲突检查（原来是只警告不拦，现在让用户明确选择）---
    if (Get-TaskSafe $T_OFF) {
        Write-Host ''
        Write-Warn2 ('检测到已安装「定时开关机」（' + $T_OFF + '）：')
        Write-Warn2 '两者同时生效会互相打断（刚休眠就被叫起来重启之类），建议二选一。'
        if (-not (Confirm-Yes '仍要同时安装循环重启？')) { Write-Info '已取消'; return }
    }

    if (-not (Confirm-Yes '确认安装？')) { Write-Info '已取消'; return }

    # --- 落地 ---
    # 这里从 schtasks 换成 Register-ScheduledTask，原因是 schtasks /Create 建出来的任务
    # 默认「只在交流电源下运行」（DisallowStartIfOnBatteries=true）且拿不到统一的设置，
    # 笔记本用电池时循环重启根本不会触发 —— 这正是"笔记本不适配"的根源。
    Write-Host ''
    # 外壳里要写死缓冲秒数，所以每次安装都重写一遍外壳（同时保证记录助手存在）
    Write-TaskScripts -RestartBuffer $buffer | Out-Null
    $trigger = New-ScheduledTaskTrigger -Once -At $startAt `
        -RepetitionInterval (New-TimeSpan -Minutes $n)
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' `
        -Argument ('/c "' + (Join-Path $DataDir 'restart.cmd') + '"')

    Write-Info ('创建任务 ' + $T_RESTART + ' ...')
    try {
        Register-ScheduledTask -TaskName $T_RESTART -Force `
            -Action $action -Trigger $trigger `
            -Settings (Get-CycleSettings) -Principal (Get-SystemPrincipal) `
            -Description ('AutoPowerPro：每 ' + (Format-Minutes $n) + '自动重启一次（缓冲 ' + $buffer.ToString() + ' 秒）') `
            -ErrorAction Stop | Out-Null
    } catch {
        Write-Err2 ('创建任务失败：' + $_.Exception.Message)
        Write-Info '可以退而求其次，用「任务计划程序」(taskschd.msc) 手动新建：'
        Write-Info ('   触发器：一次性，之后每 ' + (Format-Minutes $n) + '重复一次（持续时间：无限期）')
        Write-Info ('   操作  ：启动程序 shutdown.exe  参数 /r /t ' + $buffer.ToString())
        Write-Info '   常规  ：使用 SYSTEM 账户，勾选"使用最高权限运行"'
        return
    }

    $t = Get-TaskSafe $T_RESTART
    if (-not $t) {
        Write-Err2 '创建后没能在系统里找到该任务，请打开「任务计划程序」(taskschd.msc) 确认。'
        return
    }
    Write-Ok ('已创建  ' + $T_RESTART)

    $info = $t | Get-ScheduledTaskInfo
    Write-ResultCard -Title '安装完成' -Rows @(
        @{ k = '循环重启'; v = ((Format-Minutes $n) + '一次') },
        @{ k = '缓冲时间'; v = ($buffer.ToString() + ' 秒') },
        @{ k = '首次重启'; v = $startAt.ToString('MM-dd HH:mm') },
        @{ k = '下次运行'; v = ([string]$info.NextRunTime) },
        @{ k = '取消本次'; v = 'shutdown /a    （只在缓冲期内有效）'; c = 'Gray' },
        @{ k = '运行记录'; v = $EventLog; c = 'Gray' }
    ) -Notes @(
        ('彻底停止：主菜单 [5] 卸载全部，或执行  schtasks /End /TN ' + $T_RESTART),
        '每次触发的时间都记在「运行记录」里（主菜单 [4] 查看），可回看一共重启过几次。',
        '循环重启不会唤醒休眠中的机器：机器睡着后它就不再触发（有意设计，避免半夜被叫醒重启）。'
    )
}

# ===========================================================================
#  八·五、运行记录（本工具执行记录 + Windows 事件日志）
# ===========================================================================
$Script:LogTagText = @{
    'off-hibernate' = '进入休眠（定时任务触发）'
    'off-sleep'     = '进入睡眠（定时任务触发）'
    'off-shutdown'  = '执行关机（定时任务触发）'
    'wake'          = '定时唤醒触发'
    'restart'       = '循环重启触发'
}

# 读本工具自己的记录：每行 "yyyy-MM-dd HH:mm:ss TAG"
# 时间用手工分组解析，不用 [datetime]::TryParseExact ——
# 把未声明类型的数组当格式串传给它会选错重载，是踩过的坑。
function Get-OwnEvents([int]$Days = 30) {
    $rows = New-Object System.Collections.ArrayList
    if (-not (Test-Path $EventLog)) { return $rows }
    $since = (Get-Date).AddDays(-$Days)
    try {
        foreach ($line in @(Get-Content -LiteralPath $EventLog -ErrorAction Stop)) {
            $s = ([string]$line).Trim()
            if ($s -eq '') { continue }
            $m = [regex]::Match($s, '^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\s+(\S+)$')
            if (-not $m.Success) { continue }
            $t = [datetime]::new(
                [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value,
                [int]$m.Groups[4].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value)
            if ($t -lt $since) { continue }
            $tag = $m.Groups[7].Value
            $text = $tag
            if ($Script:LogTagText.ContainsKey($tag)) { $text = $Script:LogTagText[$tag] }
            [void]$rows.Add([pscustomobject]@{ Time = $t; Source = '本工具'; Text = $text })
        }
    } catch { }
    return $rows
}

# 读 Windows 事件日志：关机 / 重启 / 睡眠 / 唤醒 / 异常断电的真实记录。
# 这是权威来源 —— 手动重启、系统更新重启、断电也都在里面，不只是本工具的动作。
function Get-SystemHistory([int]$Days = 30) {
    $rows = New-Object System.Collections.ArrayList
    $since = (Get-Date).AddDays(-$Days)

    $queries = @(
        @{ LogName = 'System'; Id = 1074, 6005, 6006, 6008, 41, 42, 107, 109, 506, 507; StartTime = $since }
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $since }
    )
    foreach ($q in $queries) {
        $evts = $null
        try { $evts = @(Get-WinEvent -FilterHashtable $q -ErrorAction Stop) } catch { continue }
        foreach ($e in $evts) {
            $id = [int]$e.Id
            $prov = [string]$e.ProviderName
            $text = ''
            $src = '系统'
            if ($prov -eq 'Microsoft-Windows-Power-Troubleshooter' -and $id -eq 1) {
                $text = '从睡眠/休眠唤醒（含唤醒源）'
            } elseif ($id -eq 1074) {
                $proc = ''
                try {
                    $mm = [regex]::Match([string]$e.Message, '([^\\\s]+\.exe)')
                    if ($mm.Success) { $proc = $mm.Groups[1].Value }
                } catch { }
                $text = '发起关机/重启'
                if ($proc -ne '') { $text = $text + '（' + $proc + '）' }
            } elseif ($id -eq 6005) { $text = '系统启动完成' }
            elseif ($id -eq 6006) { $text = '系统正常关机' }
            elseif ($id -eq 6008) { $text = '异常关机（断电或死机）'; $src = '异常' }
            elseif ($id -eq 41)   { $text = '内核意外断电重启';       $src = '异常' }
            elseif ($id -eq 42)   { $text = '进入睡眠/休眠' }
            elseif ($id -eq 107)  { $text = '从睡眠/休眠唤醒' }
            elseif ($id -eq 109)  { $text = '内核发起关机转换' }
            elseif ($id -eq 506)  { $text = '进入新式待机（Modern Standby）' }
            elseif ($id -eq 507)  { $text = '退出新式待机（被唤醒）' }
            if ($text -eq '') { continue }
            [void]$rows.Add([pscustomobject]@{ Time = $e.TimeCreated; Source = $src; Text = $text })
        }
    }
    return $rows
}

function Show-RunLog {
    Write-Host ''
    Write-Host '  运行记录' -ForegroundColor $C_Title
    Write-Host '  本工具的执行记录 + Windows 事件日志，看什么时候关机/重启/唤醒了' -ForegroundColor $C_Dim

    $own = @(Get-OwnEvents)
    $sys = @(Get-SystemHistory)
    $all = New-Object System.Collections.ArrayList
    foreach ($r in $own) { [void]$all.Add($r) }
    foreach ($r in $sys) { [void]$all.Add($r) }

    if ($all.Count -eq 0) {
        Write-Host ''
        Write-PanelEdge '-' $C_Border
        Write-UiText '  最近 30 天没有任何记录。' $C_Dim
        Write-UiText '  如果任务已经装好但这里是空的，说明还没触发过；' $C_Dim
        Write-UiText '  也可能是系统事件日志被清理过（本工具自己的记录不会被清）。' $C_Dim
        Write-PanelEdge '-' $C_Border
        return
    }

    $sorted = @($all | Sort-Object -Property Time -Descending)
    $limit = 40
    $shown = @($sorted | Select-Object -First $limit)

    Write-Host ''
    Write-PanelEdge '=' $C_Title
    Write-SectionTitle ('最近 ' + $shown.Count + ' 条（共 ' + $sorted.Count + ' 条，按时间倒序）') $C_Title
    Write-UiRule
    Write-LogRow '时间' '来源' '事件' $C_Dim
    Write-UiRule
    foreach ($r in $shown) {
        $col = 'Gray'
        if ($r.Source -eq '异常') { $col = $C_Err }
        elseif ($r.Source -eq '本工具') { $col = $C_Ok }
        Write-LogRow ($r.Time.ToString('MM-dd HH:mm:ss')) ([string]$r.Source) ([string]$r.Text) $col
    }
    if ($sorted.Count -gt $limit) {
        Write-UiRule
        Write-UiText ('  还有 ' + ($sorted.Count - $limit) + ' 条更早的记录没有显示（完整记录见上面的文件）。') $C_Dim
    }
    Write-PanelEdge '=' $C_Title

    # --- 汇总（只统计本工具的动作，避免和系统事件重复计数）---
    $todayStart = (Get-Date).Date
    $todayOwn = @($sorted | Where-Object { $_.Time -ge $todayStart -and $_.Source -eq '本工具' })
    $todaySys = @($sorted | Where-Object { $_.Time -ge $todayStart -and $_.Source -ne '本工具' })
    $nWake = @($todayOwn | Where-Object { $_.Text -like '*唤醒*' }).Count
    $nOff = @($todayOwn | Where-Object { $_.Text -like '*休眠*' -or $_.Text -like '*睡眠*' -or $_.Text -like '*关机*' }).Count
    $nRe = @($todayOwn | Where-Object { $_.Text -like '*重启*' }).Count

    $lastWake = @($sorted | Where-Object { $_.Source -eq '本工具' -and $_.Text -like '*唤醒*' } | Select-Object -First 1)
    $lastWakeTxt = '（没有记录）'
    if ($lastWake.Count -gt 0) { $lastWakeTxt = $lastWake[0].Time.ToString('MM-dd HH:mm:ss') }

    Write-ResultCard -Title '汇总' -Rows @(
        @{ k = '今天唤醒'; v = ($nWake.ToString() + ' 次（任务触发）') },
        @{ k = '今天关机类'; v = ($nOff.ToString() + ' 次（任务触发）') },
        @{ k = '今天重启'; v = ($nRe.ToString() + ' 次（任务触发）') },
        @{ k = '今天系统电源事件'; v = ($todaySys.Count.ToString() + ' 条') },
        @{ k = '最近一次唤醒'; v = $lastWakeTxt },
        @{ k = '本工具记录'; v = $EventLog; c = 'Gray' }
    ) -Notes @(
        '「本工具」= 计划任务被触发的时刻；「系统」= Windows 记录的真实电源事件。',
        '循环重启用的是"关机前缓冲"：触发记录会比真正重启早一个缓冲秒数（默认 60 秒）。',
        '只有休眠/睡眠才能被软件唤醒；「关机」模式下系统里不会出现唤醒记录。'
    )
}

# ===========================================================================
#  九、查看状态
# ===========================================================================
function Show-Status {
    Write-Host ''
    Write-Host '  当前状态' -ForegroundColor $C_Title

    # --- 本机概况：机型 / 供电 / 休眠 / 唤醒定时器策略 ---
    $m = Get-MachineInfo
    Write-PanelEdge '-' $C_Border
    $model = (($m.Vendor + ' ' + $m.Model) -replace '\s+', ' ').Trim()
    $chassisTxt = $m.Chassis
    if ($model -ne '') { $chassisTxt = $chassisTxt + '   ' + (Format-Clip $model 34) }
    Write-Kv '机型' $chassisTxt 'White'
    if ($m.HasBattery) {
        $pwr = '正在使用电池'; $pwrCol = $C_Warn
        if (-not $m.OnBattery) { $pwr = '已接交流电'; $pwrCol = $C_Ok }
        if ($null -ne $m.BatteryPct) { $pwr = $pwr + '    电量 ' + $m.BatteryPct + '%' }
        Write-Kv '供电' $pwr $pwrCol
    } else {
        Write-Kv '供电' '交流电（无电池）' $C_Ok
    }
    $hibTxt = '未启用'; $hibCol = $C_Warn
    if ($m.HibernateReady) { $hibTxt = '可用'; $hibCol = $C_Ok }
    Write-Kv '休眠' $hibTxt $hibCol
    Write-Kv '唤醒定时器' ('接电源 ' + (Format-WakePolicy $m.WakeAc) + '      用电池 ' + (Format-WakePolicy $m.WakeDc)) 'Gray'
    Write-PanelEdge '-' $C_Border

    $any = $false
    foreach ($name in @($T_OFF, $T_ON)) {
        $t = Get-TaskSafe $name
        if (-not $t) { continue }
        $any = $true
        $info = $t | Get-ScheduledTaskInfo
        $mode = Get-OffModeName $t.Actions[0].Execute $t.Actions[0].Arguments
        $head = '定时关机'
        if ($name -eq $T_ON) { $head = '定时唤醒' }
        Write-Host ''
        Write-PanelEdge '-' $C_Border
        Write-Rich -Parts @((L ('  ' + $head) $C_Key), (L ('   ' + $name) $C_Dim)) `
                   -Right ([string]$t.State) -RightColor $C_Ok
        Write-UiRule
        $lastRun = [string]$info.LastRunTime
        $wakeRun = [string]$t.Settings.WakeToRun
        $wakeCol = $C_Dim
        if ($t.Settings.WakeToRun) { $wakeCol = $C_Ok }
        Write-Rich -Parts @((L '    执行动作    ' $C_Dim), (L $mode $C_Val))
        Write-UiText ('      ' + $t.Actions[0].Execute + ' ' + $t.Actions[0].Arguments) $C_Dim
        Write-Rich -Parts @((L '    下次运行    ' $C_Dim), (L ([string]$info.NextRunTime) $C_Val))
        Write-Rich -Parts @((L '    上次运行    ' $C_Dim), (L $lastRun $C_Hint))
        Write-Rich -Parts @((L '    唤醒运行    ' $C_Dim), (L $wakeRun $wakeCol))
    }

    $rt = Get-TaskSafe $T_RESTART
    if ($rt) {
        $any = $true
        $info = $rt | Get-ScheduledTaskInfo
        $iv = $null
        try { $iv = $rt.Triggers[0].Repetition.Interval } catch { }
        $minTxt = '未知'
        if ($iv) { $minTxt = Format-Minutes (ConvertFrom-IsoDuration ([string]$iv)) }
        Write-Host ''
        Write-PanelEdge '-' $C_Border
        Write-Rich -Parts @((L '  每 N 分钟自动重启' $C_Key), (L ('   ' + $T_RESTART) $C_Dim)) `
                   -Right ([string]$rt.State) -RightColor $C_Ok
        Write-UiRule
        Write-Rich -Parts @((L '    执行动作    ' $C_Dim), (L '重启' $C_Val))
        Write-UiText ('      ' + $rt.Actions[0].Execute + ' ' + $rt.Actions[0].Arguments) $C_Dim
        Write-Rich -Parts @((L '    重复间隔    ' $C_Dim), (L $minTxt $C_Val))
        Write-Rich -Parts @((L '    下次运行    ' $C_Dim), (L ([string]$info.NextRunTime) $C_Val))
        Write-Rich -Parts @((L '    上次运行    ' $C_Dim), (L ([string]$info.LastRunTime) $C_Hint))
    }

    if (-not $any) {
        Write-Host ''
        Write-PanelEdge '-' $C_Border
        Write-UiText '  当前没有安装任何任务' $C_Dim
        Write-PanelEdge '-' $C_Border
        Write-Info '回主菜单选 [1] 或 [2] 开始安装。'
    } else {
        Write-PanelEdge '-' $C_Border
    }

    # --- 唤醒能力自检 ---
    Write-Host ''
    Write-Host '  唤醒能力自检' -ForegroundColor $C_Title
    Write-PanelEdge '-' $C_Border

    $wt = Invoke-NativeQuiet 'powercfg.exe' @('/waketimers')
    $wtCode = $Script:LastNativeExit
    $wtLines = @(($wt -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
    if ($wtCode -ne 0) {
        Write-UiText '  读取唤醒定时器失败（该命令需要管理员权限）' $C_Warn
    } elseif ($wtLines.Count -gt 0) {
        Write-UiText '  已武装的唤醒定时器：' $C_Dim
        foreach ($ln in $wtLines) { Write-UiText ('    ' + $ln.Trim()) $C_Hint }
    } else {
        Write-UiText '  当前没有被武装的唤醒定时器（系统空闲时会清空，属正常）' $C_Dim
    }

    Write-UiBlank
    if (Test-Path $EventLog) {
        Write-UiText '  运行记录（本工具触发的最新 5 条，完整历史见主菜单 [4]）：' $C_Dim
        Get-Content -LiteralPath $EventLog -Tail 5 | ForEach-Object { Write-UiText ('    ' + $_) $C_Hint }
    } else {
        Write-UiText '  运行记录：暂无（任务还没触发过）' $C_Dim
    }

    Write-UiBlank
    $av = Invoke-NativeQuiet 'powercfg.exe' @('/a')
    $avCode = $Script:LastNativeExit
    $hiber = @(($av -split "`r?`n") | Where-Object { $_ -match '休眠|Hibernate' })
    if ($avCode -ne 0) {
        Write-UiText '  无法读取休眠状态（该命令需要管理员权限）' $C_Warn
    } elseif ($hiber.Count -gt 0) {
        foreach ($ln in $hiber) { Write-UiText ('  ' + $ln.Trim()) $C_Hint }
    } else {
        Write-UiText '  未检测到休眠条目，说明本机休眠不可用' $C_Warn
    }
    Write-PanelEdge '-' $C_Border
}

# ===========================================================================
#  十、卸载
# ===========================================================================
function Uninstall-All {
    Write-Host ''
    Write-Host '  卸载' -ForegroundColor $C_Title

    $found = @()
    foreach ($name in $AllTasks) {
        if (Get-TaskSafe $name) { $found += $name }
    }
    if ($found.Count -eq 0) {
        Write-Info '没有找到本工具创建的任务，无需卸载。'
        return
    }
    Write-Host ''
    Write-PanelEdge '-' $C_Border
    Write-UiText '  将要删除以下计划任务' $C_Key
    Write-UiRule
    foreach ($name in $found) { Write-Rich -Parts @((L ('    ' + $name) $C_Warn)) }
    Write-PanelEdge '-' $C_Border

    if (-not (Confirm-Yes '确认卸载？')) { Write-Info '已取消'; return }

    Write-Host ''
    $removed = @()
    $failed = @()
    foreach ($name in $found) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        if (Get-TaskSafe $name) { $failed += $name } else { $removed += $name }
    }
    foreach ($name in $removed) { Write-Ok ('已删除  ' + $name) }
    foreach ($name in $failed)  { Write-Err2 ('删除失败  ' + $name + '   （可手动运行 taskschd.msc 删除）') }

    $purge = Confirm-Yes ('同时删除数据目录 ' + $DataDir + ' ？')
    $purged = $false
    if ($purge) {
        if (Test-Path $DataDir) {
            Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
            $purged = -not (Test-Path $DataDir)
            if ($purged) { Write-Ok ('已清理  ' + $DataDir) }
            else         { Write-Warn2 ('未能完全删除  ' + $DataDir) }
        }
    }

    Write-ResultCard -Title '卸载完成' -Rows @(
        @{ k = '已删除任务'; v = $(if ($removed.Count -gt 0) { $removed -join ' , ' } else { '无' }) },
        @{ k = '残留任务'; v = $(if ($failed.Count -gt 0) { $failed -join ' , ' } else { '无' }); c = $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' }) },
        @{ k = '数据目录'; v = $(if ($purged) { '已清理' } elseif (Test-Path $DataDir) { '保留（' + $DataDir + '）' } else { '不存在' }); c = 'Gray' }
    ) -Notes @(
        '电源方案里的「允许唤醒定时器」保持原样，没有回滚（它本身是系统正常设置，不影响日常使用）。',
        '如果之前改过休眠设置，hiberfil.sys 仍会保留；想彻底关掉可执行  powercfg /hibernate off'
    )
}

# ===========================================================================
#  十一、主菜单
# ===========================================================================
function Start-Menu {
    # 开屏体检只做一次；之后菜单里用一行摘要常驻显示当前机型与电源状态
    if (-not $Script:EnvShown) {
        Show-EnvironmentPanel
        $Script:EnvShown = $true
    }

    while ($true) {
        Write-Banner

        $planBadge  = Get-PlanBadge
        $cycleBadge = Get-CycleBadge

        Write-UiBlank
        Write-Rich -Parts @((L '  [1]  ' $C_Accent), (L '定时开关机' $C_Key)) `
                   -Right $planBadge.Text -RightColor $planBadge.Color
        Write-UiText '       每天 / 仅工作日，到点关机 + 到点唤醒' $C_Hint
        Write-UiBlank
        Write-Rich -Parts @((L '  [2]  ' $C_Accent), (L '每 N 分钟自动重启' $C_Key)) `
                   -Right $cycleBadge.Text -RightColor $cycleBadge.Color
        Write-UiText '       纯软件循环重启，不断电，系统程序全部重新加载' $C_Hint
        Write-UiBlank
        Write-PanelEdge '-' $C_Border
        Write-UiBlank
        Write-Rich -Parts @((L '  [3]  ' $C_Accent), (L '查看当前状态' $C_Key),
                            (L '        ' $C_Dim),
                            (L '[4]  ' $C_Accent), (L '运行记录' $C_Key))
        Write-Rich -Parts @((L '  [5]  ' $C_Accent), (L '卸载全部' $C_Key),
                            (L '            ' $C_Dim),
                            (L '[0]  ' $C_Accent), (L '退出' $C_Key))
        Write-UiBlank
        Write-UiRule
        Write-UiText ('  本机：' + (Get-MachineLine)) $C_Dim
        Write-PanelEdge '=' $C_Title
        Write-Host ''

        Write-Host '  ' -NoNewline
        Write-Host '> ' -NoNewline -ForegroundColor $C_Accent
        Write-Host '请选择' -NoNewline -ForegroundColor $C_Key
        Write-Host '  [0-5]' -NoNewline -ForegroundColor $C_Dim
        Write-Host '  ' -NoNewline
        $c = Read-Host

        switch ($c.Trim().ToLower()) {
            '1' { Install-ScheduledPlan; Pause-Back }
            '2' { Install-RestartCycle;   Pause-Back }
            '3' { Show-Status;            Pause-Back }
            '4' { Show-RunLog;            Pause-Back }
            '5' { Uninstall-All;          Pause-Back }
            '0' { return }
            ''  { }
            default { Write-Warn2 '请输入 0、1、2、3、4 或 5' }
        }
    }
}

# ===========================================================================
#  十二、入口
# ===========================================================================
try {
    if ($Help) {
        Write-Banner
        Write-UiBlank
        Write-UiText '  用法：双击「启动-自动开关机.cmd」即可打开本菜单。' $C_Key
        Write-UiBlank
        Write-UiText '  管理员 PowerShell 命令行参数：' $C_Dim
        Write-UiText '    -Status      只查看状态（只读，不改系统）' $C_Hint
        Write-UiText '    -Log         只查看运行记录（关机/重启/唤醒历史）' $C_Hint
        Write-UiText '    -Uninstall   卸载全部计划任务' $C_Hint
        Write-UiText '    -Help        显示本帮助' $C_Hint
        Write-PanelEdge '=' $C_Title
        Write-Host ''
        Read-Host '  按回车退出' | Out-Null
        exit 0
    }

    if (-not (Test-IsAdmin)) {
        if (Start-ElevatedSelf) { exit 0 }
        Stop-WithMessage '没有管理员权限，无法创建计划任务。请重新运行并在 UAC 弹窗点「是」。'
    }

    if ($Status)    { Show-Status;   Read-Host '  按回车退出' | Out-Null; exit 0 }
    if ($Log)       { Show-RunLog;   Read-Host '  按回车退出' | Out-Null; exit 0 }
    if ($Uninstall) { Uninstall-All; Read-Host '  按回车退出' | Out-Null; exit 0 }

    Start-Menu
    exit 0
} catch {
    Write-Host ''
    Write-Err2 ("出错了：" + $_.Exception.Message)
    Write-Host ('         ' + $_.ScriptStackTrace) -ForegroundColor $C_Dim
    Write-Host ''
    Read-Host '  按回车退出' | Out-Null
    exit 1
}
