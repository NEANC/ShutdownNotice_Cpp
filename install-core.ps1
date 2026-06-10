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
.PARAMETER Mirror
    国内加速镜像域名（可选），如 "ghfast.top"。仅用于下载 .exe，API 查询始终直连。
.PARAMETER Uninstall
    卸载模式：移除所有计划任务，可选删除安装目录。
.PARAMETER RemoveFiles
    与 -Uninstall 配合使用，同时删除安装目录下的所有文件。
.PARAMETER SendKey
    Server酱 SendKey（可选）。安装时直接写入 config.ini，无需手动编辑。
.PARAMETER AccessToken
    钉钉机器人 access_token（可选）。安装时直接写入 config.ini。
.PARAMETER Secret
    钉钉机器人加签密钥（可选）。安装时直接写入 config.ini。
.PARAMETER NotifyMode
    通知策略: primary_only / failover / both_sequential（可选，默认 failover）。
.PARAMETER NotifyPrimary
    主通道: dingtalk / serverchan（可选，默认 dingtalk）。
.PARAMETER AckMode
    确认模式: response_header / send_completed（可选，默认 response_header）。
.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -InstallPath "D:\Tools\Shutdown Notice" -Tag "v1.0.0"
.EXAMPLE
    .\install.ps1 -SendKey "SCT123" -AccessToken "abc" -Secret "sec"
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
    [string]$Mirror = "",
    [string]$SendKey = "",
    [string]$AccessToken = "",
    [string]$Secret = "",
    [string]$NotifyMode = "failover",
    [string]$NotifyPrimary = "dingtalk",
    [string]$AckMode = "response_header",
    [switch]$Uninstall,
    [switch]$RemoveFiles
)


# 控制台编码: 避免 exe 中文输出在 PS 5.1 下显示为乱码
if ($PSVersionTable.PSVersion.Major -le 5) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

# 硬编码参数
$Script:TaskFolder = "Shutdown Notice"
$Script:MaxRetries = 3
$Script:RetryDelaySeconds = 2

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
      <WorkingDirectory>__WORKDIR__</WorkingDirectory>
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

# 计算文件 SHA256 哈希
function Get-FileSha256 {
    param([string]$FilePath)
    try {
        $hash = (Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash
        return $hash.ToLowerInvariant()
    } catch {
        Write-Err "无法计算文件哈希: $FilePath — $_"
        return $null
    }
}

# 镜像 URL 包装（国内加速用，如 ghfast.top）
function Get-MirroredUrl {
    param([string]$Url, [string]$MirrorHost)
    if ($MirrorHost) {
        return "https://$MirrorHost/$Url"
    }
    return $Url
}

# 带重试的 HTTP 下载
function Invoke-DownloadWithRetry {
    param(
        [string]$Url,
        [string]$OutFile,
        [hashtable]$Headers = @{},
        [string]$MirrorHost = $Mirror,
        [int]$MaxRetries = $Script:MaxRetries,
        [int]$BaseDelay = $Script:RetryDelaySeconds
    )

    $urls = @(Get-MirroredUrl -Url $Url -MirrorHost $MirrorHost)

    # 如果配置了镜像，直连作为 fallback
    if ($MirrorHost) { $urls += $Url }

    foreach ($tryUrl in $urls) {
        if ($tryUrl -ne $urls[0]) {
            Write-Host "    尝试直连: $tryUrl" -ForegroundColor Gray
        }
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Invoke-WebRequest -Uri $tryUrl -Headers $Headers -OutFile $OutFile -ErrorAction Stop
                return $true
            } catch {
                if ($attempt -ge $MaxRetries) { break }
                $delay = $BaseDelay * [Math]::Pow(2, $attempt - 1)
                Write-Host "    等待 ${delay}s 后重试..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $delay
            }
        }
        # 移除失败的部分下载文件
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    }
    return $false
}

# 下载构建产物
function Get-LatestRelease {
    $headers = @{ "Accept" = "application/vnd.github+json" }
    if ($Token) {
        $headers["Authorization"] = "Bearer $Token"
    }

    if ($Tag) {
        $apiPath = "repos/$Repo/releases/tags/$Tag"
    } else {
        $apiPath = "repos/$Repo/releases/latest"
    }
    $url = "https://api.github.com/$apiPath"

    Write-Step "正在通过 GitHub API 查询对应版本 Release"
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
    Write-Step "下载构建产物"

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

    $Script:VerifiedExes = @()

    foreach ($asset in $exeAssets) {
        $dest = Join-Path $InstallPath $asset.name
        Write-Host "    下载: $($asset.name) ($('{0:N0}' -f $asset.size) bytes)"
        $success = Invoke-DownloadWithRetry -Url $asset.browser_download_url -OutFile $dest -Headers $headers -MirrorHost $Mirror
        if (-not $success) {
            Write-Err "下载失败: $($asset.name)"
            continue
        }

        # SHA256 完整性校验（利用 GitHub API 返回的 digest 字段）
        $expectedDigest = $asset.digest
        if ($expectedDigest -and $expectedDigest -match '^sha256:([0-9a-fA-F]{64})$') {
            $expected = $matches[1]
            $actual = Get-FileSha256 -FilePath $dest
            if ($actual -eq $expected) {
                Write-OK "校验通过: $dest"
                $Script:VerifiedExes += $dest
            } else {
                Write-Err "SHA256 校验失败: $($asset.name)"
                Write-Err "  云端: $expected"
                Write-Err "  本地: $actual"
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-OK "已保存: $dest"
            $Script:VerifiedExes += $dest
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
    $workDir = Split-Path -Parent $ExePath
    $xml = $Script:TaskTemplate.
        Replace("__TIME__", $timeStr).
        Replace("__AUTHOR__", $author).
        Replace("__DESC__", $Description).
        Replace("__FOLDER__", $TaskFolder).
        Replace("__NAME__", $TaskName).
        Replace("__EVENTID__", [string]$EventID).
        Replace("__USERID__", $userId).
        Replace("__EXEPATH__", $ExePath).
        Replace("__WORKDIR__", $workDir)

    # 写入临时文件
    $utf16 = [System.Text.Encoding]::Unicode
    [System.IO.File]::WriteAllText($xmlFile, $xml, $utf16)

    try {
        # 创建任务文件夹（预期可能失败，用 cmd.exe 隔离）
        cmd.exe /c "schtasks /create /tn `"$TaskFolder`" /f >nul 2>nul"
        $null = $LASTEXITCODE

        # 注册任务
        $result = schtasks /create /tn $taskFullName /xml $xmlFile /f 2>&1
        $createExit = $LASTEXITCODE
        if ($createExit -eq 0) {
            Write-OK "已注册: $taskFullName"
        } else {
            Write-Err "注册失败: $taskFullName — $result"
        }
    } finally {
        Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
    }
}

function Register-AllTasks {
    Write-Step "注册计划任务"

    # 检查任务文件夹是否已存在（首次安装必然失败，用 cmd.exe 隔离）
    cmd.exe /c "schtasks /query /tn `"$TaskFolder`" >nul 2>nul"
    $folderExists = ($LASTEXITCODE -eq 0)
    if ($folderExists) {
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

    # poweroff.exe / poweron.exe — 开关机脚本，无事件触发器，仅提示
    $poweroffExe = Join-Path $InstallPath "poweroff.exe"
    if (Test-Path $poweroffExe) {
        Write-Warn "poweroff.exe 需通过组策略配置为关机脚本，详见 README.md"
    }
    $poweronExe = Join-Path $InstallPath "poweron.exe"
    if (Test-Path $poweronExe) {
        Write-Warn "poweron.exe 需通过组策略配置为开机脚本，详见 README.md"
    }
}

# 卸载
function Uninstall-ShutdownNotice {
    Write-Step "卸载 Shutdown Notice"

    $removedCount = 0
    foreach ($task in $Script:EventTasks) {
        $taskFullName = "$TaskFolder\$($task.Name)"
        cmd.exe /c "schtasks /delete /tn `"$taskFullName`" /f >nul 2>nul"
        $delExit = $LASTEXITCODE
        if ($delExit -eq 0) {
            Write-OK "已删除任务: $taskFullName"
            $removedCount++
        } else {
            Write-Warn "任务不存在或删除失败: $taskFullName"
        }
    }

    # 尝试删除任务文件夹（如果已空）
    cmd.exe /c "schtasks /delete /tn `"$TaskFolder`" /f >nul 2>nul"
    $null = $LASTEXITCODE

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

    # 初始化配置文件：若已存在则校验完整性，不完整则重建
    if ($Script:VerifiedExes) {
        Write-Host "  初始化配置文件..."
        $configPath = Join-Path $InstallPath 'config.ini'

        # 必需的节及其键（用于校验已有文件是否完整）
        $requiredConfig = @{
            'serverchan' = @('sendkey')
            'dingtalk'   = @('access_token', 'secret')
            'notify'     = @('mode', 'primary')
            'http'       = @('ack_mode')
        }

        $needRegenerate = $true
        if (Test-Path $configPath) {
            $existingLines = Get-Content $configPath -Encoding UTF8
            $existingSections = @{}
            $currentSec = ''
            foreach ($line in $existingLines) {
                if ($line -match '^\s*\[(.+)\]\s*$') {
                    $currentSec = $Matches[1]
                    $existingSections[$currentSec] = @()
                } elseif ($line -match '^\s*([^#;=]+)\s*=' -and $currentSec) {
                    $existingSections[$currentSec] += $Matches[1].Trim()
                }
            }

            # 逐节比对
            $missing = @()
            foreach ($sec in $requiredConfig.Keys) {
                if (-not $existingSections.ContainsKey($sec)) {
                    $missing += "[$sec] (节缺失)"
                    continue
                }
                foreach ($key in $requiredConfig[$sec]) {
                    if ($key -notin $existingSections[$sec]) {
                        $missing += "[$sec] $key (键缺失)"
                    }
                }
            }

            if ($missing.Count -eq 0) {
                Write-OK "config.ini 已存在且结构完整，跳过生成"
                $needRegenerate = $false
            } else {
                Write-Warn "config.ini 不完整，将重建"
                foreach ($m in $missing) { Write-Host "    缺少: $m" -ForegroundColor Gray }
                Remove-Item $configPath -Force
            }
        }

        if ($needRegenerate) {
            $null = & $Script:VerifiedExes[0] 1>$null 2>$null
        }

        if (Test-Path $configPath) {
            if ($needRegenerate) {
                Write-OK "config.ini 已自动生成"
            }

            # 写入用户通过命令行传递的配置（覆盖模板默认值）
            $configLines = Get-Content $configPath -Encoding UTF8
            $section = ""
            for ($i = 0; $i -lt $configLines.Count; $i++) {
                $line = $configLines[$i]
                if ($line -match '^\s*\[(.+)\]\s*$') {
                    $section = $Matches[1]
                    continue
                }
                if ($line -match '^\s*([^#;=]+)\s*=\s*.*$') {
                    $key = $Matches[1].Trim()
                    $newVal = $null
                    switch ("$section.$key") {
                        'serverchan.sendkey'  { if ($SendKey)      { $newVal = $SendKey } }
                        'dingtalk.access_token' { if ($AccessToken) { $newVal = $AccessToken } }
                        'dingtalk.secret'      { if ($Secret)      { $newVal = $Secret } }
                        'notify.mode'          { if ($NotifyMode -ne 'failover')   { $newVal = $NotifyMode } }
                        'notify.primary'       { if ($NotifyPrimary -ne 'dingtalk') { $newVal = $NotifyPrimary } }
                        'http.ack_mode'        { if ($AckMode -ne 'response_header') { $newVal = $AckMode } }
                    }
                    if ($newVal) {
                        $configLines[$i] = "$key = $newVal"
                        Write-OK "  已配置 [$section] $key = $newVal"
                    }
                }
            }
            Set-Content $configPath -Value $configLines -Encoding UTF8
        } else {
            Write-Warn "config.ini 未生成，请检查 exe 是否运行正常"
        }
    }

    # 注册任务
    Register-AllTasks

    Write-Host ""
    Write-Host "  安装完成！" -ForegroundColor Green
    Write-Host "----------------------------------------" -ForegroundColor Magenta
    Write-Host ""
    if (-not $SendKey -and -not $AccessToken) {
        Write-Host "  后续步骤:" -ForegroundColor Yellow
        Write-Host "  1. 编辑 $InstallPath\config.ini 填写通知渠道配置" -ForegroundColor White
        Write-Host "  2. 打开 任务计划程序 确认任务已注册" -ForegroundColor White
    } else {
        Write-Host "  config.ini 已完成预配置" -ForegroundColor Green
        Write-Host "  请打开 任务计划程序 确认任务已注册" -ForegroundColor White
    }
    Write-Host ""
}

Main
