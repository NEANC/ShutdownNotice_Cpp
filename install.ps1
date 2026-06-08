# Shutdown Notice IEX bootstrap - irm https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1 | iex
# 国内加速: $SN_MIRROR='ghfast.top'; irm https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1 | iex

$ErrorActionPreference = 'Stop'

# Resolve $SN_* variable: current scope > environment > default
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

# Bootstrap environment
try { Set-ExecutionPolicy -Scope Process Bypass -Force -ErrorAction SilentlyContinue } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Admin check
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run as Administrator.'
}

# Download install-core.ps1 (镜像失败/缓存过期时自动 fallback 直连)
$repo   = Get-SNValue -Name 'SN_REPO'   -DefaultValue 'NEANC/ShutdownNotice_Cpp'
$branch = Get-SNValue -Name 'SN_BRANCH' -DefaultValue 'master'
$mirror = Get-SNValue -Name 'SN_MIRROR' -DefaultValue ''
$baseUrl = "https://raw.githubusercontent.com/$repo/$branch/install-core.ps1"
$tmp = Join-Path $env:TEMP 'ShutdownNotice-install-core.ps1'

# 构建尝试 URL 列表：镜像优先，直连作 fallback
$coreUrls = @()
if ($mirror) {
    $coreUrls += "https://$mirror/$baseUrl"
    $coreUrls += $baseUrl
} else {
    $coreUrls += $baseUrl
}

$downloaded = $false
$client = New-Object Net.WebClient
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

foreach ($tryUrl in $coreUrls) {
    Write-Host ">>> Downloading install-core.ps1..."
    Write-Host "    $tryUrl"
    try {
        $bytes = $client.DownloadData($tryUrl)
    } catch {
        if ($tryUrl -ne $coreUrls[-1]) {
            Write-Host "    下载失败，尝试下一源..." -ForegroundColor DarkYellow
        }
        continue
    }

    $code = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Strip BOM character preserved by GetString (otherwise WriteAllText adds second BOM)
    $code = $code -replace "^\uFEFF", ""
    # Normalize all line endings to CRLF (fix CR-only / LF-only / mixed)
    $code = $code -replace "(`r`n|`n|`r)", "`r`n"

    # 内容结构校验：排除镜像缓存截断/损坏（避免 PSParser 误报 param() 赋值）
    $hasParam   = $code -match '\bparam\s*\('
    $hasMain    = $code -match '\bfunction\s+Main\b'
    $hasHereStr = $code -match "@'[\s\S]*'@"
    $lineCount  = ($code -split "`r`n").Count
    if (-not $hasParam -or -not $hasMain -or -not $hasHereStr -or $lineCount -lt 50) {
        $missing = @()
        if (-not $hasParam)   { $missing += 'param' }
        if (-not $hasMain)    { $missing += 'Main' }
        if (-not $hasHereStr) { $missing += 'here-string' }
        if ($lineCount -lt 50) { $missing += "仅 $lineCount 行" }
        Write-Host "    内容结构异常 (缺少: $($missing -join ', '))，尝试下一源..." -ForegroundColor DarkYellow
        continue
    }

    # Write UTF-8 with BOM for Windows PowerShell 5.1 compatibility
    [System.IO.File]::WriteAllText($tmp, $code, $utf8Bom)
    $downloaded = $true
    break
}

if (-not $downloaded) {
    throw "无法下载有效的 install-core.ps1"
}

# Build splat table and execute install-core.ps1
$params = @{}
$installPath = Get-SNValue -Name 'SN_INSTALL_PATH' -DefaultValue $null
if ($installPath) { $params['InstallPath'] = $installPath }
$tag = Get-SNValue -Name 'SN_TAG' -DefaultValue $null
if ($tag) { $params['Tag'] = $tag }
$token = Get-SNValue -Name 'SN_TOKEN' -DefaultValue $null
if ($token) { $params['Token'] = $token }
if ($mirror) { $params['Mirror'] = $mirror }
if (Test-SNTrue -Name 'SN_UNINSTALL')    { $params['Uninstall']    = $true }
if (Test-SNTrue -Name 'SN_REMOVE_FILES') { $params['RemoveFiles']  = $true }

Write-Host ">>> Executing install-core.ps1..."
& $tmp @params
