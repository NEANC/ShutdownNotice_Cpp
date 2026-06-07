#Requires -RunAsAdministrator
<#
.SYNOPSIS
    下载 Shutdown Notice 构建产物并安装 Windows 计划任务。
.DESCRIPTION
    从 GitHub Releases 下载最新版本，解压到指定目录，
    然后基于 XML 模板自动生成并注册所有事件触发任务。
.PARAMETER InstallPath
    安装目录，默认为 "C:\Shutdown Notice"。
.PARAMETER Repo
    GitHub 仓库，格式为 "owner/repo"，默认为 "NEANC/ShutdownNotice_Cpp"。
.PARAMETER Tag
    指定下载版本标签（如 v1.0.0）。留空则下载最新 Release。
.PARAMETER Token
    GitHub Personal Access Token（可选）。用于避免 API 速率限制。
.PARAMETER Uninstall
    卸载模式：移除所有计划任务，可选删除安装目录。
.PARAMETER RemoveFiles
    与 -Uninstall 配合使用，同时删除安装目录下的所有文件。
.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -InstallPath "D:\Tools\Shutdown Notice" -Tag "v1.0.0"
.EXAMPLE
    .\install.ps1 -Uninstall
.EXAMPLE
    .\install.ps1 -Uninstall -RemoveFiles
.NOTES
    必须以管理员身份运行。
#>

param(
    [string]$InstallPath = "C:\Shutdown Notice",
    [string]$Repo = "NEANC/ShutdownNotice_Cpp",
    [string]$Tag = "",
    [string]$Token = "",
    [switch]$Uninstall,
    [switch]$RemoveFiles
)


# 硬编码参数
$Script:TaskFolder = "Shutdown Notice"

# 事件 ID → 描述映射
$Script:EventTasks = @(
    @{ ID = 41;   Name = "WIN告知：ID41";   Desc = "未进行正常关机流程的情况下重新启动" },
    @{ ID = 1074; Name = "WIN告知：ID1074"; Desc = "因为系统关机、用户注销、应用程序崩溃，或者是由于系统资源不足等原因导致进程被强制结束" },
    @{ ID = 6005; Name = "WIN告知：ID6005"; Desc = "事件日志服务已启动" },
    @{ ID = 6006; Name = "WIN告知：ID6006"; Desc = "事件日志服务已停止" },
    @{ ID = 6008; Name = "WIN告知：ID6008"; Desc = "上一次系统关闭是意外的" }
)

# XML 任务模板
$Script:TaskTemplate = @'
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
      <ValueQueries>
        <Value name="EventRecordID">Event/System/EventRecordID</Value>
        <Value name="SystemTime">Event/System/TimeCreated/@SystemTime</Value>
        <Value name="Computer">Event/System/Computer</Value>
        <Value name="Provider">Event/System/Provider/@Name</Value>
      </ValueQueries>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>__USERID__</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>__EXEPATH__</Command>
      <Arguments>--event-id __EVENTID__ --record "$(EventRecordID)" --time "$(SystemTime)" --computer "$(Computer)" --provider "$(Provider)"</Arguments>
    </Exec>
  </Actions>
</Task>
'@

# 辅助函数
function Write-Step {
    param([string]$Message)
    Write-Host ">>> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Err {
    param([string]$Message)
    Write-Host "    [错误] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [警告] $Message" -ForegroundColor Yellow
}

# 下载构建产物
function Get-LatestRelease {
    $headers = @{ "Accept" = "application/vnd.github+json" }
    if ($Token) {
        $headers["Authorization"] = "Bearer $Token"
    }

    if ($Tag) {
        $url = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    } else {
        $url = "https://api.github.com/repos/$Repo/releases/latest"
    }

    Write-Step "查询 GitHub Release: $url"
    try {
        $release = Invoke-RestMethod -Uri $url -Headers $headers -ErrorAction Stop
        Write-OK "找到版本: $($release.tag_name)"
        return $release
    } catch {
        Write-Err "无法获取 Release 信息: $_"
        Write-Warn "请确认仓库 $Repo 已有 Release，或使用 -Tag 指定版本"
        return $null
    }
}

function Invoke-Download {
    Write-Step "下载构建产物..."

    $release = Get-LatestRelease
    if (-not $release -or -not $release.assets) {
        Write-Err "未找到可下载的构建产物"
        exit 1
    }

    # 筛选 .exe 文件
    $exeAssets = $release.assets | Where-Object { $_.name -match '\.exe$' }
    if (-not $exeAssets) {
        Write-Err "Release 中未找到 .exe 文件"
        exit 1
    }

    # 创建安装目录
    if (-not (Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Write-OK "已创建目录: $InstallPath"
    }

    $headers = @{ "Accept" = "application/octet-stream" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    foreach ($asset in $exeAssets) {
        $dest = Join-Path $InstallPath $asset.name
        Write-Host "    下载: $($asset.name) ($('{0:N0}' -f $asset.size) bytes)"
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $dest -ErrorAction Stop
            Write-OK "已保存: $dest"
        } catch {
            Write-Err "下载失败: $($asset.name) - $_"
        }
    }
}

# 生成并注册计划任务
function New-EventTask {
    param(
        [int]$EventID,
        [string]$TaskName,
        [string]$Description,
        [string]$ExePath
    )

    $taskFullName = "$TaskFolder\$TaskName"
    $xmlFile = Join-Path $env:TEMP "$TaskName.xml"

    # 获取当前用户 SID
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userId = $currentUser.User.Value
    $author = $currentUser.Name

    # 填充模板
    $timeStr = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $xml = $Script:TaskTemplate.
        Replace("__TIME__", $timeStr).
        Replace("__AUTHOR__", $author).
        Replace("__DESC__", $Description).
        Replace("__FOLDER__", $TaskFolder).
        Replace("__NAME__", $TaskName).
        Replace("__EVENTID__", [string]$EventID).
        Replace("__USERID__", $userId).
        Replace("__EXEPATH__", $ExePath)

    # 写入临时文件
    $utf16 = [System.Text.Encoding]::Unicode
    [System.IO.File]::WriteAllText($xmlFile, $xml, $utf16)

    try {
        # 创建任务文件夹
        $null = schtasks /create /tn $TaskFolder /f 2>$null

        # 注册任务
        $result = schtasks /create /tn $taskFullName /xml $xmlFile /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "已注册: $taskFullName"
        } else {
            Write-Err "注册失败: $taskFullName — $result"
        }
    } finally {
        Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
    }
}

function Register-AllTasks {
    Write-Step "注册计划任务..."

    $null = schtasks /query /tn $TaskFolder 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Warn "任务文件夹 '$TaskFolder' 已存在，将覆盖同名任务"
    }

    foreach ($task in $Script:EventTasks) {
        $exeName = "ID$($task.ID).exe"
        $exePath = Join-Path $InstallPath $exeName

        if (-not (Test-Path $exePath)) {
            Write-Warn "跳过 $($task.Name): 找不到 $exePath"
            continue
        }

        New-EventTask -EventID $task.ID `
                      -TaskName $task.Name `
                      -Description $task.Description `
                      -ExePath $exePath
    }

    # down.exe — 关机脚本，无事件触发器，仅提示
    $downExe = Join-Path $InstallPath "down.exe"
    if (Test-Path $downExe) {
        Write-Warn "down.exe 需通过组策略配置为关机脚本，详见 README.md"
    }
}

# 创建 config.ini 模板
function New-ConfigTemplate {
    $configPath = Join-Path $InstallPath "config.ini"
    if (Test-Path $configPath) {
        Write-OK "config.ini 已存在，跳过生成"
        return
    }

    $template = @"
# 关机通知系统 - 配置文件
# 支持同时配置多个通知渠道，任一渠道成功即视为推送成功

[serverchan]
# 留空则不启用 ServerChan 推送
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
# 确认模式: response_header (等待服务器返回状态码) / send_completed (发送后立即终止程序，不保证信息送达)
ack_mode = response_header
"@

    Set-Content -Path $configPath -Value $template -Encoding UTF8
    Write-Warn "已生成 config.ini 模板，请填写通知渠道配置: $configPath"
}


# 卸载
function Uninstall-ShutdownNotice {
    Write-Step "卸载 Shutdown Notice..."

    $removedCount = 0
    foreach ($task in $Script:EventTasks) {
        $taskFullName = "$TaskFolder\$($task.Name)"
        $result = schtasks /delete /tn $taskFullName /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "已删除任务: $taskFullName"
            $removedCount++
        } else {
            Write-Warn "任务不存在或删除失败: $taskFullName"
        }
    }

    # 尝试删除任务文件夹（如果已空）
    $null = schtasks /delete /tn $TaskFolder /f 2>$null

    Write-OK "已移除 $removedCount 个计划任务"

    if ($RemoveFiles) {
        if (Test-Path $InstallPath) {
            Write-Step "删除安装目录: $InstallPath"
            try {
                Remove-Item -Path $InstallPath -Recurse -Force -ErrorAction Stop
                Write-OK "已删除安装目录"
            } catch {
                Write-Err "删除安装目录失败: $_"
            }
        } else {
            Write-Warn "安装目录不存在: $InstallPath"
        }
    } else {
        Write-Host "    提示: 使用 -RemoveFiles 同时删除安装目录" -ForegroundColor Gray
        Write-Host "    安装目录: $InstallPath" -ForegroundColor Gray
    }
}


# 主流程
function Main {
    if ($Uninstall) {
        Write-Host ""
        Write-Host "  Shutdown Notice 卸载脚本" -ForegroundColor Magenta
        Write-Host "----------------------------------------" -ForegroundColor Magenta
        if ($RemoveFiles) {
            Write-Host "  模式: 完整卸载（任务 + 文件）" -ForegroundColor Yellow
        } else {
            Write-Host "  模式: 仅移除计划任务" -ForegroundColor Yellow
        }
        Write-Host "  安装路径: $InstallPath" -ForegroundColor Gray
        Write-Host "----------------------------------------" -ForegroundColor Magenta
        Write-Host ""

        Uninstall-ShutdownNotice

        Write-Host ""
        Write-Host "  卸载完成！" -ForegroundColor Green
        Write-Host "----------------------------------------" -ForegroundColor Magenta
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "  Shutdown Notice 安装脚本" -ForegroundColor Magenta
    Write-Host "----------------------------------------" -ForegroundColor Magenta
    Write-Host "  安装路径: $InstallPath" -ForegroundColor Gray
    Write-Host "  仓库:     $Repo" -ForegroundColor Gray
    if ($Tag) {
        Write-Host "  版本:     $Tag" -ForegroundColor Gray
    } else {
        Write-Host "  版本:     最新 Release" -ForegroundColor Gray
    }
    Write-Host ""

    # 下载构建产物
    Invoke-Download

    # 生成配置模板
    New-ConfigTemplate

    # 注册任务
    Register-AllTasks

    Write-Host ""
    Write-Host "  安装完成！" -ForegroundColor Green
    Write-Host "----------------------------------------" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  后续步骤:" -ForegroundColor Yellow
    Write-Host "  1. 编辑 $InstallPath\config.ini 填写通知渠道配置" -ForegroundColor White
    Write-Host "  2. 打开 任务计划程序 确认任务已注册" -ForegroundColor White
    Write-Host ""
}

Main
