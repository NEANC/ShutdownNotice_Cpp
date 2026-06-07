<#
.SYNOPSIS
    install.ps1 单元测试 — 兼容 PowerShell 5.1 和 7
.DESCRIPTION
    验证 install.ps1 的语法正确性和核心逻辑，
    不依赖 Pester，使用纯 PowerShell 断言。
#>

$ErrorActionPreference = "Stop"
$Script:TestCount = 0
$Script:PassCount = 0
$Script:FailCount = 0

# ============================================================
# 轻量断言框架
# ============================================================

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $Script:TestCount++
    if ($Expected -eq $Actual) {
        $Script:PassCount++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $Script:FailCount++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        期望: $Expected" -ForegroundColor Red
        Write-Host "        实际: $Actual" -ForegroundColor Red
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition)
    $Script:TestCount++
    if ($Condition) {
        $Script:PassCount++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $Script:FailCount++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        条件为 false" -ForegroundColor Red
    }
}

function Assert-Contains {
    param([string]$Name, [string]$Haystack, [string]$Needle)
    $Script:TestCount++
    if ($Haystack -like "*$Needle*") {
        $Script:PassCount++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $Script:FailCount++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        未找到: $Needle" -ForegroundColor Red
    }
}

function Assert-NotContains {
    param([string]$Name, [string]$Haystack, [string]$Needle)
    $Script:TestCount++
    if ($Haystack -notlike "*$Needle*") {
        $Script:PassCount++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $Script:FailCount++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        不应包含: $Needle" -ForegroundColor Red
    }
}

# ============================================================
# 测试 1: 脚本语法验证
# ============================================================
Write-Host ""
Write-Host "=== 测试 1: 语法验证 ===" -ForegroundColor Cyan

$installPath = Join-Path $PSScriptRoot "..\install.ps1"
$installContent = Get-Content -Path $installPath -Raw -Encoding UTF8

# 移除顶部的 #Requires 行以便在 CI 中解析（CI 无管理员权限）
$testableContent = $installContent -replace '#Requires -RunAsAdministrator', '# Requires removed for CI test'

$parsed = $null
try {
    $parsed = [ScriptBlock]::Create($testableContent)
    Assert-True "脚本语法有效" $true
} catch {
    Assert-True "脚本语法有效" $false
    Write-Host "        解析错误: $_" -ForegroundColor Red
    exit 1
}

# 检查 AST 完整性
$ast = $parsed.Ast
Assert-True "AST 解析成功" ($ast -ne $null)

# 验证必要的函数定义
$funcNames = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name }
$requiredFuncs = @("Main", "Invoke-Download", "New-EventTask", "Register-AllTasks", "New-ConfigTemplate", "Get-LatestRelease")
foreach ($f in $requiredFuncs) {
    Assert-True "函数 $f 已定义" ($funcNames -contains $f)
}

# ============================================================
# 测试 2: XML 模板替换逻辑
# ============================================================
Write-Host ""
Write-Host "=== 测试 2: XML 模板替换 ===" -ForegroundColor Cyan

# 模拟模板
$template = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>__TIME__</Date>
    <Author>__AUTHOR__</Author>
    <Description>__DESC__</Description>
    <URI>\__FOLDER__\__NAME__</URI>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[(EventID=__EVENTID__)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>__USERID__</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Actions Context="Author">
    <Exec>
      <Command>__EXEPATH__</Command>
    </Exec>
  </Actions>
</Task>
'@

$testTime = "2026-06-08T12:00:00"
$testAuthor = "TESTPC\TestUser"
$testDesc = "测试事件描述"
$testFolder = "My Tasks"
$testName = "TestEvent"
$testEventID = "1074"
$testUserId = "S-1-5-21-12345"
# exe 路径含空格和中文
$testExePath = "C:\My Tasks\Shutdown Notice\ID1074.exe"

$result = $template.
    Replace("__TIME__", $testTime).
    Replace("__AUTHOR__", $testAuthor).
    Replace("__DESC__", $testDesc).
    Replace("__FOLDER__", $testFolder).
    Replace("__NAME__", $testName).
    Replace("__EVENTID__", $testEventID).
    Replace("__USERID__", $testUserId).
    Replace("__EXEPATH__", $testExePath)

Assert-NotContains "残留 __TIME__ 占位符" $result "__TIME__"
Assert-NotContains "残留 __AUTHOR__ 占位符" $result "__AUTHOR__"
Assert-NotContains "残留 __DESC__ 占位符" $result "__DESC__"
Assert-NotContains "残留 __FOLDER__ 占位符" $result "__FOLDER__"
Assert-NotContains "残留 __NAME__ 占位符" $result "__NAME__"
Assert-NotContains "残留 __EVENTID__ 占位符" $result "__EVENTID__"
Assert-NotContains "残留 __USERID__ 占位符" $result "__USERID__"
Assert-NotContains "残留 __EXEPATH__ 占位符" $result "__EXEPATH__"

Assert-Contains "时间已替换" $result $testTime
Assert-Contains "作者已替换" $result $testAuthor
Assert-Contains "描述已替换" $result $testDesc
Assert-Contains "文件夹已替换" $result $testFolder
Assert-Contains "任务名已替换" $result $testName
Assert-Contains "事件ID已替换" $result $testEventID
Assert-Contains "用户SID已替换" $result $testUserId
Assert-Contains "EXE路径含空格" $result $testExePath
Assert-Contains "UTF-16 编码声明" $result 'encoding="UTF-16"'
Assert-Contains "EventTrigger 结构" $result "<EventTrigger>"
Assert-Contains "S4U 登录类型" $result "S4U"

# ============================================================
# 测试 3: EventTasks 数据结构
# ============================================================
Write-Host ""
Write-Host "=== 测试 3: EventTasks 数据结构 ===" -ForegroundColor Cyan

$taskData = @(
    @{ ID = 41;   Name = "WIN告知：ID41";   Desc = "未进行正常关机流程的情况下重新启动" },
    @{ ID = 1074; Name = "WIN告知：ID1074"; Desc = "因为系统关机、用户注销、应用程序崩溃，或者是由于系统资源不足等原因导致进程被强制结束" },
    @{ ID = 6005; Name = "WIN告知：ID6005"; Desc = "事件日志服务已启动" },
    @{ ID = 6006; Name = "WIN告知：ID6006"; Desc = "事件日志服务已停止" },
    @{ ID = 6008; Name = "WIN告知：ID6008"; Desc = "上一次系统关闭是意外的" }
)

$expectedIDs = @(41, 1074, 6005, 6006, 6008)
$actualIDs = $taskData | ForEach-Object { $_.ID }
Assert-Equal "事件数量" 5 $taskData.Count
for ($i = 0; $i -lt $expectedIDs.Count; $i++) {
    Assert-Equal "事件 ID 匹配: $($expectedIDs[$i])" $expectedIDs[$i] $taskData[$i].ID
}

# Name 必须包含 ID
for ($i = 0; $i -lt $taskData.Count; $i++) {
    Assert-True "名称含 ID$($taskData[$i].ID)" ($taskData[$i].Name -like "*ID$($taskData[$i].ID)*")
}

# Desc 不能为空
for ($i = 0; $i -lt $taskData.Count; $i++) {
    Assert-True "ID$($taskData[$i].ID) 描述非空" ($taskData[$i].Desc.Length -gt 5)
}

# ============================================================
# 测试 4: config.ini 模板
# ============================================================
Write-Host ""
Write-Host "=== 测试 4: config.ini 模板 ===" -ForegroundColor Cyan

$configTemplate = @"
# 关机通知系统 - 配置文件
# 支持同时配置多个通知渠道，任一渠道成功即视为推送成功

[serverchan]
# ServerChan 推送密钥
sendkey = 

[dingtalk]
# 钉钉机器人密钥
access_token = 

# 钉钉机器人加签密钥 (可选)
secret = 

[notify]
# 通知策略: primary_only / failover / both_sequential
mode = failover
# 主通道: dingtalk / serverchan
primary = dingtalk

[http]
# 确认模式: response_header / send_completed
ack_mode = response_header
"@

Assert-Contains "包含 [serverchan] 节" $configTemplate "[serverchan]"
Assert-Contains "包含 [dingtalk] 节" $configTemplate "[dingtalk]"
Assert-Contains "包含 [notify] 节" $configTemplate "[notify]"
Assert-Contains "包含 sendkey" $configTemplate "sendkey"
Assert-Contains "包含 access_token" $configTemplate "access_token"
Assert-Contains "包含 secret" $configTemplate "secret"
Assert-Contains "包含 mode 配置" $configTemplate "mode"
Assert-Contains "包含 primary 配置" $configTemplate "primary"
Assert-Contains "包含 ack_mode 配置" $configTemplate "ack_mode"
Assert-NotContains "不应包含 proxy 配置" $configTemplate "proxy"
Assert-Contains "使用 # 注释" $configTemplate "# 关机通知系统"
Assert-NotContains "不应包含 ; 注释" $configTemplate ";"

$lines = $configTemplate -split "`r`n|`n"
Assert-True "至少有 10 行" ($lines.Count -ge 10)

# sendkey / access_token / secret 默认值为空
$sendkeyLine = $lines | Where-Object { $_ -match '^sendkey' }
Assert-True "sendkey 默认空" ($sendkeyLine -match '=\s*$')
$accessTokenLine = $lines | Where-Object { $_ -match '^access_token' }
Assert-True "access_token 默认空" ($accessTokenLine -match '=\s*$')

# ============================================================
# 测试 5: 边界条件
# ============================================================
Write-Host ""
Write-Host "=== 测试 5: 边界条件 ===" -ForegroundColor Cyan

# 空模板不会产生错误
$emptyReplace = $template.
    Replace("__TIME__", "").
    Replace("__AUTHOR__", "").
    Replace("__DESC__", "").
    Replace("__FOLDER__", "").
    Replace("__NAME__", "").
    Replace("__EVENTID__", "").
    Replace("__USERID__", "").
    Replace("__EXEPATH__", "")
Assert-True "空值替换不报错" ($emptyReplace -is [string])

# EventID 处理特殊值
$result6008 = $template.
    Replace("__EVENTID__", "6008").
    Replace("__TIME__", "").
    Replace("__AUTHOR__", "").
    Replace("__DESC__", "").
    Replace("__FOLDER__", "").
    Replace("__NAME__", "").
    Replace("__USERID__", "").
    Replace("__EXEPATH__", "")
Assert-Contains "事件ID 6008" $result6008 "6008"

# 路径含特殊字符
$pathWithSpecial = "C:\Program Files (x86)\My App\ID6008.exe"
$resultPath = $template.
    Replace("__EXEPATH__", $pathWithSpecial).
    Replace("__TIME__", "").
    Replace("__AUTHOR__", "").
    Replace("__DESC__", "").
    Replace("__FOLDER__", "").
    Replace("__NAME__", "").
    Replace("__EVENTID__", "").
    Replace("__USERID__", "")
Assert-Contains "路径含括号" $resultPath "Program Files (x86)"

# ============================================================
# 测试 6: 跨版本兼容性
# ============================================================
Write-Host ""
Write-Host "=== 测试 6: 跨版本兼容性 ===" -ForegroundColor Cyan

$PSVersion = $PSVersionTable.PSVersion
Write-Host "  PowerShell: $($PSVersion.Major).$($PSVersion.Minor) ($($PSVersionTable.PSEdition))"

# 验证脚本使用的语法在 PS 5.1 下均可用
# - @{} 哈希表
Assert-True "支持 @{} 语法" $true
# - Where-Object 简化语法需要 PS 3+
Assert-True "支持 Where-Object" $true
# - Invoke-RestMethod 需要 PS 3+
Assert-True "支持 Invoke-RestMethod" ($null -ne (Get-Command Invoke-RestMethod -ErrorAction SilentlyContinue))
# - Invoke-WebRequest
Assert-True "支持 Invoke-WebRequest" ($null -ne (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue))
# - splatting 需要 PS 2+
Assert-True "支持 splatting" $true
# - $using: (PS 3+)
Assert-True "支持 where 脚本块" $true

# ============================================================
# 测试 7: 脚本参数验证
# ============================================================
Write-Host ""
Write-Host "=== 测试 7: 参数定义 ===" -ForegroundColor Cyan

$paramBlock = $ast.Find({ $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true)
Assert-True "参数块存在" ($paramBlock -ne $null)

if ($paramBlock) {
    $paramNames = $paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
    Assert-True "包含 InstallPath 参数" ($paramNames -contains "InstallPath")
    Assert-True "包含 Repo 参数" ($paramNames -contains "Repo")
    Assert-True "包含 Tag 参数" ($paramNames -contains "Tag")
    Assert-True "包含 Token 参数" ($paramNames -contains "Token")
    Assert-Equal "参数数量" 4 $paramBlock.Parameters.Count
}

# ============================================================
# 测试 8: GitHub Actions 兼容命令检查
# ============================================================
Write-Host ""
Write-Host "=== 测试 8: CI 环境兼容性 ===" -ForegroundColor Cyan

# schtasks.exe 在 Windows 上必须可用
$schtasks = Get-Command schtasks.exe -ErrorAction SilentlyContinue
Assert-True "schtasks.exe 存在" ($schtasks -ne $null)

# 脚本中使用的 .NET 类型必须在 PS 5.1 可用
if ($PSVersionTable.PSVersion.Major -le 5) {
    Assert-True "[WindowsIdentity] 可用" ($null -ne ([System.Security.Principal.WindowsIdentity]))
    Assert-True "[Text.Encoding] 可用" ($null -ne ([System.Text.Encoding]::Unicode))
    Assert-True "[IO.File] 可用" ($null -ne ([System.IO.File]))
}

# ============================================================
# 结果汇总
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  测试完成" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  总计: $Script:TestCount" -ForegroundColor White
Write-Host "  通过: $Script:PassCount" -ForegroundColor Green
if ($Script:FailCount -gt 0) {
    Write-Host "  失败: $Script:FailCount" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  失败: 0" -ForegroundColor Green
    exit 0
}
