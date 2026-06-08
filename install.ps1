# Shutdown Notice - IEX bootstrap installer
#
# Usage:
#   Install (default):
#     irm https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1 | iex
#
#   Custom path:
#     $SN_INSTALL_PATH='D:\Tools\Shutdown Notice'; irm https://raw.../install.ps1 | iex
#
#   Specific version:
#     $SN_TAG='v0.1.0'; irm https://raw.../install.ps1 | iex
#
#   Uninstall (tasks only):
#     $SN_UNINSTALL=$true; irm https://raw.../install.ps1 | iex
#
#   Full uninstall (tasks + files):
#     $SN_UNINSTALL=$true; $SN_REMOVE_FILES=$true; irm https://raw.../install.ps1 | iex
#
# Available variables (all optional):
#   $SN_INSTALL_PATH  - Install directory (default "C:\Shutdown Notice")
#   $SN_TAG           - Release tag (default Latest)
#   $SN_REPO          - GitHub repo (default "NEANC/ShutdownNotice_Cpp")
#   $SN_BRANCH        - Branch (default "master")
#   $SN_TOKEN         - GitHub PAT (optional)
#   $SN_UNINSTALL     - Uninstall mode ($true = uninstall)
#   $SN_REMOVE_FILES  - Delete install dir during uninstall

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

# Download install-core.ps1
$repo   = Get-SNValue -Name 'SN_REPO'   -DefaultValue 'NEANC/ShutdownNotice_Cpp'
$branch = Get-SNValue -Name 'SN_BRANCH' -DefaultValue 'master'
$coreUrl = "https://raw.githubusercontent.com/$repo/$branch/install-core.ps1"
$tmp = Join-Path $env:TEMP 'ShutdownNotice-install-core.ps1'

Write-Host ">>> Downloading install-core.ps1..."
Write-Host "    $coreUrl"

$client = New-Object Net.WebClient
$bytes = $client.DownloadData($coreUrl)
$code = [System.Text.Encoding]::UTF8.GetString($bytes)

# Normalize CR-only line endings
$code = $code -replace "`r(?!`n)", "`r`n"

# Write UTF-8 with BOM for Windows PowerShell 5.1 compatibility
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($tmp, $code, $utf8Bom)

# Build splat table and execute install-core.ps1
$params = @{}
$installPath = Get-SNValue -Name 'SN_INSTALL_PATH' -DefaultValue $null
if ($installPath) { $params['InstallPath'] = $installPath }
$tag = Get-SNValue -Name 'SN_TAG' -DefaultValue $null
if ($tag) { $params['Tag'] = $tag }
$token = Get-SNValue -Name 'SN_TOKEN' -DefaultValue $null
if ($token) { $params['Token'] = $token }
if (Test-SNTrue -Name 'SN_UNINSTALL')    { $params['Uninstall']    = $true }
if (Test-SNTrue -Name 'SN_REMOVE_FILES') { $params['RemoveFiles']  = $true }

Write-Host ">>> Executing install-core.ps1..."
& $tmp @params
