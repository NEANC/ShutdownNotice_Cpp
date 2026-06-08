# Shutdown Notice - IEX bootstrap installer
#
# 用法:
#   一键安装:
#     irm https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1 | iex
#
#   自定义安装路径:
#     $SN_INSTALL_PATH='D:\Tools\Shutdown Notice'; irm https://raw.../install.ps1 | iex
#
#   指定版本:
#     $SN_TAG='v0.1.0'; irm https://raw.../install.ps1 | iex
#
#   卸载 (仅任务):
#     $SN_UNINSTALL=$true; irm https://raw.../install.ps1 | iex
#
#   完整卸载 (任务+文件):
#     $SN_UNINSTALL=$true; $SN_REMOVE_FILES=$true; irm https://raw.../install.ps1 | iex
#
# 环境变量 (所有均为可选):
#   $SN_INSTALL_PATH  - 安装目录, 默认 "C:\Shutdown Notice"
#   $SN_TAG           - 指定版本标签, 默认 Latest
#   $SN_REPO          - GitHub 仓库, 默认 "NEANC/ShutdownNotice_Cpp"
#   $SN_BRANCH        - 分支, 默认 "master"
#   $SN_TOKEN         - GitHub PAT (可选)
#   $SN_UNINSTALL     - 卸载模式 ($true=卸载)
#   $SN_REMOVE_FILES  - 配合卸载, $true=删除安装目录

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# 辅助: 读取 $SN_* 变量, 优先级: 当前作用域 > 环境变量 > 默认值
# ------------------------------------------------------------
function Get-SNValue {
    param([string]$Name, [object]$DefaultValue = $null)
    $var = Get-Variable -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $var -and $null -ne $var.Value -and "$($var.Value)" -ne '') {
        return $var.Value
    }
    $envValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
    return $DefaultValue
}

function Test-SNTrue {
    param([string]$Name)
    $value = Get-SNValue -Name $Name -DefaultValue $false
    if ($value -is [bool]) { return $value }
    return "$value" -match '^(1|true|yes|y)$'
}

# ------------------------------------------------------------
# 基础环境设置
# ------------------------------------------------------------
try { Set-ExecutionPolicy -Scope Process Bypass -Force -ErrorAction SilentlyContinue } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ------------------------------------------------------------
# 管理员权限检查
# ------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请使用管理员身份运行 PowerShell 并重新执行安装命令。'
}

# ------------------------------------------------------------
# 解析参数
# ------------------------------------------------------------
$repo   = Get-SNValue -Name 'SN_REPO'   -DefaultValue 'NEANC/ShutdownNotice_Cpp'
$branch = Get-SNValue -Name 'SN_BRANCH' -DefaultValue 'master'
$coreUrl = "https://raw.githubusercontent.com/$repo/$branch/install-core.ps1"
$tmp = Join-Path $env:TEMP 'ShutdownNotice-install-core.ps1'

Write-Host ">>> 下载安装脚本..."
Write-Host "    $coreUrl"

$client = New-Object Net.WebClient
$bytes = $client.DownloadData($coreUrl)
$code = [System.Text.Encoding]::UTF8.GetString($bytes)

# 兼容 CR-only 行尾
$code = $code -replace "`r(?!`n)", "`r`n"

# Windows PowerShell 5.1: 写入 UTF-8 with BOM
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($tmp, $code, $utf8Bom)

# ------------------------------------------------------------
# 构建参数表并执行 install-core.ps1
# ------------------------------------------------------------
$params = @{}
$installPath = Get-SNValue -Name 'SN_INSTALL_PATH' -DefaultValue $null
if ($installPath) { $params['InstallPath'] = $installPath }
$tag = Get-SNValue -Name 'SN_TAG' -DefaultValue $null
if ($tag) { $params['Tag'] = $tag }
$token = Get-SNValue -Name 'SN_TOKEN' -DefaultValue $null
if ($token) { $params['Token'] = $token }
if (Test-SNTrue -Name 'SN_UNINSTALL')    { $params['Uninstall']    = $true }
if (Test-SNTrue -Name 'SN_REMOVE_FILES') { $params['RemoveFiles']  = $true }

Write-Host ">>> 执行安装脚本..."
& $tmp @params
