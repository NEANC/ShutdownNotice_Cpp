# GPO Scripts 部署 — 通过注册表配置开关机通知程序
#
# 警告: 此脚本直接操作 HKLM 注册表组策略脚本节点，属于高危操作。
# 仅在通过 install.ps1 / install-core.ps1 -DeployGpoScripts 调用时才会运行。
#
# 用法:
#   安装 (由 install-core.ps1 调用):
#     & "$PSScriptRoot\gpo-scripts.ps1" -InstallPath "C:\Shutdown Notice"
#
#   卸载 (由 install-core.ps1 -Uninstall 调用):
#     & "$PSScriptRoot\gpo-scripts.ps1" -InstallPath "C:\Shutdown Notice" -Uninstall

param(
    [string]$InstallPath = "C:\Shutdown Notice",
    [switch]$Uninstall,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# PS 5.1 兼容: 确保 console 能输出 Unicode 特殊字符
if ($PSVersionTable.PSVersion.Major -le 5) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

# 注册表路径常量
$GPO_BASE = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy'
$SCRIPT_ROOTS = @{
    Startup  = "$GPO_BASE\Scripts\Startup"
    Shutdown = "$GPO_BASE\Scripts\Shutdown"
}
$STATE_ROOTS = @{
    Startup  = "$GPO_BASE\State\Machine\Scripts\Startup"
    Shutdown = "$GPO_BASE\State\Machine\Scripts\Shutdown"
}

# 部署目标: 事件类型 → exe 文件名
$GPO_TARGETS = @(
    @{ Type = 'Shutdown'; Exe = 'poweroff.exe' }
    @{ Type = 'Startup';  Exe = 'poweron.exe' }
)

# 辅助函数
function Resolve-PathSafe {
    param([string]$Path)
    try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { return $Path }
}

function Same-Path {
    param([string]$A, [string]$B)
    return ((Resolve-PathSafe $A).TrimEnd('\') -ieq (Resolve-PathSafe $B).TrimEnd('\'))
}

function Set-RegString {
    param([string]$Path, [string]$Name, [string]$Value)
    $null = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    $null = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force
}

function Set-RegQwordZero {
    param([string]$Path, [string]$Name)
    # gpedit.msc 导出为 hex(b): 00,00,...  → 用 QWord 类型写入 0
    $null = New-ItemProperty -Path $Path -Name $Name -Value 0 -PropertyType QWord -Force
}

# 高危操作警告 + 二次确认
function Confirm-HighRisk {
    if ($Yes) { return }

    $WARN = [char]0x26A0  # ⚠
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Red
    Write-Host "║                  ${WARN}  高 危 操 作 警 告  ${WARN}                     ║" -ForegroundColor Red
    Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Red
    Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Yellow
    Write-Host '║                                                              ║' -ForegroundColor Yellow
    Write-Host '║  将通过写入 GPO 注册表注册开关机程序。                       ║' -ForegroundColor Yellow
    Write-Host '║  会修改系统组策略配置 (HKLM 注册表)。                        ║' -ForegroundColor Yellow
    Write-Host '║                                                              ║' -ForegroundColor Yellow
    if ($Uninstall) {
        Write-Host '║  操作内容：将移除已注册的开关机通知程序。                    ║' -ForegroundColor Yellow
    } else {
        Write-Host '║  操作内容：将添加开关机通知程序。                            ║' -ForegroundColor Yellow
    }
    Write-Host '║                                                              ║' -ForegroundColor Yellow
    Write-Host "║  ${WARN} 错误配置可能导致系统启动/关机异常。                       ║" -ForegroundColor Yellow
    Write-Host "║  ${WARN} 请确认你已了解影响，并已做好回滚准备。                    ║" -ForegroundColor Yellow
    Write-Host '║                                                              ║' -ForegroundColor Yellow
    Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Yellow
    Write-Host ''

    $answer = Read-Host '是否继续？(YES/NO)'
    while ($answer -notmatch '^(YES|yes|Yes|NO|no|No|N|n)$') {
        Write-Host "  无效输入 '$answer'，请输入 YES 或 NO" -ForegroundColor Yellow
        $answer = Read-Host '是否继续？(YES/NO)'
    }
    if ($answer -match '^(NO|no|No|N|n)$') {
        Write-Host ''
        Write-Host '操作已取消。' -ForegroundColor Green
        Write-Host ''
        exit 0
    }
    Write-Host ''
}

# GPO 容器创建: ...\Scripts\{Type}\0 (元数据)
function Ensure-GpoContainer {
    param([string]$Root)

    $null = New-Item -Path $Root -Force | Out-Null

    # gpedit.msc 反推: 父级 GPO 容器 ...\Startup\0 或 ...\Shutdown\0
    $gpoKey = Join-Path $Root '0'
    $null = New-Item -Path $gpoKey -Force | Out-Null

    Set-RegString $gpoKey 'GPO-ID'      'LocalGPO'
    Set-RegString $gpoKey 'SOM-ID'      'Local'
    Set-RegString $gpoKey 'FileSysPath' "$env:WINDIR\System32\GroupPolicy\Machine"
    Set-RegString $gpoKey 'DisplayName' '本地组策略'
    Set-RegString $gpoKey 'GPOName'     '本地组策略'
    Set-RegDword  $gpoKey 'PSScriptOrder' 1

    return $gpoKey
}

# 脚本条目创建: ...\Scripts\{Type}\0\{N}
function Set-GpoScriptChild {
    param(
        [string]$ChildKey,
        [string]$ScriptPath,
        [string]$Parameters = ''
    )

    $null = New-Item -Path $ChildKey -Force | Out-Null
    Set-RegString    $ChildKey 'Script'       $ScriptPath
    Set-RegString    $ChildKey 'Parameters'   $Parameters
    # 注册表导出为 IsPowershell (小写 s)，按实际拼写写入
    Set-RegDword     $ChildKey 'IsPowershell' 0
    # gpedit.msc 导出为 hex(b): 00,... → 用 QWord 类型
    Set-RegQwordZero $ChildKey 'ExecTime'
}

# 读取某个脚本类型下所有已注册条目
function Get-GpoScriptEntries {
    param([string]$ScriptRoot)

    $entries = @()
    if (-not (Test-Path $ScriptRoot)) { return $entries }

    foreach ($gpo in (Get-ChildItem -Path $ScriptRoot -ErrorAction SilentlyContinue)) {
        $gpoKey = $gpo.PSPath
        $gpoIndex = $gpo.PSChildName

        # 兼容旧脚本写出的扁平结构: ...\Startup\0 直接带 Script
        $flatProps = Get-ItemProperty -Path $gpoKey -ErrorAction SilentlyContinue
        if ($flatProps.PSObject.Properties.Name -contains 'Script') {
            $entries += [PSCustomObject]@{
                GpoIndex      = $gpoIndex
                ScriptIndex   = $null
                ParentKeyPath = $gpoKey
                ScriptKeyPath = $gpoKey
                Script        = $flatProps.Script
                LegacyFlat    = $true
            }
        }

        # 标准两层结构: ...\Startup\0\0
        foreach ($child in (Get-ChildItem -Path $gpoKey -ErrorAction SilentlyContinue)) {
            $childProps = Get-ItemProperty -Path $child.PSPath -ErrorAction SilentlyContinue
            if ($childProps.PSObject.Properties.Name -contains 'Script') {
                $entries += [PSCustomObject]@{
                    GpoIndex      = $gpoIndex
                    ScriptIndex   = $child.PSChildName
                    ParentKeyPath = $gpoKey
                    ScriptKeyPath = $child.PSPath
                    Script        = $childProps.Script
                    LegacyFlat    = $false
                }
            }
        }
    }

    return $entries
}

function Get-NextChildIndex {
    param([string]$GpoKey)

    $indexes = @()
    if (Test-Path $GpoKey) {
        foreach ($child in (Get-ChildItem -Path $GpoKey -ErrorAction SilentlyContinue)) {
            $n = 0
            if ([int]::TryParse($child.PSChildName, [ref]$n)) { $indexes += $n }
        }
    }

    if ($indexes.Count -eq 0) { return 0 }
    return (($indexes | Measure-Object -Maximum).Maximum + 1)
}

# 安装: 在 GPO 容器 (0\N) 中追加
function Register-GpoScripts {
    Write-Host '=== 扫描现有 GPO 脚本配置 ===' -ForegroundColor Cyan

    $registered = 0
    $skipped = 0
    $already = 0

    foreach ($target in $GPO_TARGETS) {
        $exePath = Join-Path $InstallPath $target.Exe
        $scriptRoot = $SCRIPT_ROOTS[$target.Type]
        $stateRoot  = $STATE_ROOTS[$target.Type]

        if (-not (Test-Path -LiteralPath $exePath)) {
            Write-Host "  [跳过] $($target.Type): 找不到 $exePath" -ForegroundColor Yellow
            $skipped++
            continue
        }

        # 检查是否已注册
        $existing = Get-GpoScriptEntries -ScriptRoot $scriptRoot
        $alreadyRegistered = $existing | Where-Object { $_.Script -and (Same-Path $_.Script $exePath) }
        if ($alreadyRegistered) {
            Write-Host "  [已存在] $($target.Type) → $exePath" -ForegroundColor Gray
            $already++
            continue
        }

        # 创建 GPO 容器 + 找到下一个可用索引
        $scriptGpoKey = Ensure-GpoContainer -Root $scriptRoot
        $stateGpoKey  = Ensure-GpoContainer -Root $stateRoot
        $nextIdx = Get-NextChildIndex -GpoKey $scriptGpoKey

        $scriptKey = Join-Path $scriptGpoKey $nextIdx.ToString()
        $stateKey  = Join-Path $stateGpoKey  $nextIdx.ToString()

        Write-Host "  注册 $($target.Type) [$nextIdx]: $exePath"
        Set-GpoScriptChild -ChildKey $scriptKey -ScriptPath $exePath
        Set-GpoScriptChild -ChildKey $stateKey  -ScriptPath $exePath

        $registered++
    }

    Write-Host ''
    if ($registered -gt 0) {
        $msg = "已注册 $registered 项"
        if ($already -gt 0) { $msg += "，$already 项已存在无需重复" }
        $msg += "。"
        Write-Host $msg -ForegroundColor Green
    } elseif ($skipped -gt 0 -and $already -eq 0) {
        Write-Host '未注册任何 GPO 脚本 (exe 文件缺失)。' -ForegroundColor Yellow
        Write-Host "请确认 $InstallPath 下存在 poweroff.exe 和 poweron.exe" -ForegroundColor Gray
    } elseif ($already -gt 0) {
        Write-Host "GPO 脚本已全部就绪 ($already 项已存在，无需操作)。" -ForegroundColor Green
    } else {
        Write-Host '未注册任何 GPO 脚本。' -ForegroundColor Yellow
    }
}

# 卸载: 精确比对 Script 路径后移除
function Unregister-GpoScripts {
    Write-Host '=== 扫描现有 GPO 脚本配置 ===' -ForegroundColor Cyan

    $removed = 0
    $toRemove = @()

    foreach ($target in $GPO_TARGETS) {
        $exePath = Join-Path $InstallPath $target.Exe

        foreach ($rootType in @('Scripts', 'State')) {
            $rootName = if ($rootType -eq 'State') {
                $STATE_ROOTS[$target.Type]
            } else {
                $SCRIPT_ROOTS[$target.Type]
            }

            $entries = Get-GpoScriptEntries -ScriptRoot $rootName
            foreach ($entry in ($entries | Where-Object { $_.Script -and (Same-Path $_.Script $exePath) })) {
                Write-Host "  ★ 匹配: $($target.Type) → $($entry.Script) (key: $($entry.ScriptKeyPath))" -ForegroundColor Yellow
                $toRemove += $entry.ScriptKeyPath
            }
        }
    }

    if ($toRemove.Count -eq 0) {
        Write-Host ''
        Write-Host '未找到与当前安装路径匹配的 GPO 脚本条目，无需移除。' -ForegroundColor Green
        return
    }

    # 二次确认
    Write-Host ''
    Write-Host "以上 $($toRemove.Count) 个注册表条目将被移除。" -ForegroundColor Yellow
    if (-not $Yes) {
        $confirm = Read-Host '是否继续？(YES/NO)'
        while ($confirm -notmatch '^(YES|yes|Yes|NO|no|No|N|n)$') {
            Write-Host "  无效输入 '$confirm'，请输入 YES 或 NO" -ForegroundColor Yellow
            $confirm = Read-Host '是否继续？(YES/NO)'
        }
        if ($confirm -match '^(NO|no|No|N|n)$') {
            Write-Host ''
            Write-Host '卸载已取消，未修改任何注册表。' -ForegroundColor Green
            return
        }
    }

    # 执行移除
    foreach ($keyPath in $toRemove) {
        Remove-Item -Path $keyPath -Recurse -Force
        $removed++
    }

    Write-Host ''
    Write-Host "已删除 $removed 个注册表脚本条目。" -ForegroundColor Green
}

# 主入口
if (-not $Yes) { Confirm-HighRisk }

if ($Uninstall) {
    Unregister-GpoScripts
} else {
    Register-GpoScripts
}

# 操作成功后立即刷新组策略
Write-Host ''
Write-Host '正在刷新组策略...' -ForegroundColor Cyan
try {
    cmd.exe /c "gpupdate /target:computer /force >nul 2>nul"
    if ($LASTEXITCODE -eq 0) {
        Write-Host '组策略已刷新。' -ForegroundColor Green
    } else {
        Write-Host '组策略刷新失败，请手动执行: gpupdate /target:computer /force' -ForegroundColor Yellow
    }
} catch {
    Write-Host '组策略刷新失败，请手动执行: gpupdate /target:computer /force' -ForegroundColor Yellow
}
