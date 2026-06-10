#Requires -Version 3

# CI 适配版 install.ps1 — 使用本地 exe，跳过 GitHub 下载
# 用于 test-install.yml，与正式 install.ps1 共享相同 XML 任务模板

param(
    [string]$InstallPath = "C:\ShutdownNotice",
    [string]$ExeSource = "",
    [switch]$Uninstall,
    [switch]$RemoveFiles
)

$TaskFolder = "Shutdown Notice"

$EventTasks = @(
    @{ ID = 41;   Name = "WIN告知：ID41";   Desc = "未进行正常关机流程的情况下重新启动" },
    @{ ID = 1074; Name = "WIN告知：ID1074"; Desc = "因为系统关机、用户注销、应用程序崩溃，或者是由于系统资源不足等原因导致进程被强制结束" },
    @{ ID = 6005; Name = "WIN告知：ID6005"; Desc = "事件日志服务已启动" },
    @{ ID = 6006; Name = "WIN告知：ID6006"; Desc = "事件日志服务已停止" },
    @{ ID = 6008; Name = "WIN告知：ID6008"; Desc = "上一次系统关闭是意外的" }
)

function Write-Step { param($M) Write-Host ">>> $M" -ForegroundColor Cyan }
function Write-OK   { param($M) Write-Host "    [OK] $M" -ForegroundColor Green }
function Write-Err  { param($M) Write-Host "    [错误] $M" -ForegroundColor Red }
function Write-Warn { param($M) Write-Host "    [警告] $M" -ForegroundColor Yellow }

# 与 install.ps1 完全一致的 XML 任务模板
$TaskTemplate = @'
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

function Register-AllTasks {
    Write-Step "注册计划任务..."

    # 检查任务文件夹是否已存在（首次安装必然失败，用 cmd.exe 隔离）
    cmd.exe /c "schtasks /query /tn `"$TaskFolder`" >nul 2>nul"
    $folderExists = ($LASTEXITCODE -eq 0)
    if ($folderExists) {
        Write-Warn "任务文件夹 '$TaskFolder' 已存在，将覆盖同名任务"
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userId = $currentUser.User.Value
    $author = $currentUser.Name
    $timeStr = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")

    foreach ($task in $EventTasks) {
        $exeName = "ID$($task.ID).exe"
        $exePath = Join-Path $InstallPath $exeName

        if (-not (Test-Path $exePath)) {
            Write-Warn "跳过 $($task.Name): 找不到 $exePath"
            continue
        }

        $taskFullName = "$TaskFolder\$($task.Name)"
        $xmlFile = Join-Path $env:TEMP "$($task.Name).xml"

        $xml = $TaskTemplate.
            Replace("__TIME__", $timeStr).
            Replace("__AUTHOR__", $author).
            Replace("__DESC__", $task.Desc).
            Replace("__FOLDER__", $TaskFolder).
            Replace("__NAME__", $task.Name).
            Replace("__EVENTID__", [string]$task.ID).
            Replace("__USERID__", $userId).
            Replace("__EXEPATH__", $exePath)

        $utf16 = [System.Text.Encoding]::Unicode
        [System.IO.File]::WriteAllText($xmlFile, $xml, $utf16)

        try {
            # 确保文件夹存在（预期可能失败，用 cmd.exe 隔离）
            cmd.exe /c "schtasks /create /tn `"$TaskFolder`" /f >nul 2>nul"
            $null = $LASTEXITCODE

            $result = schtasks /create /tn $taskFullName /xml $xmlFile /f 2>&1
            $createExit = $LASTEXITCODE
            if ($createExit -eq 0) {
                Write-OK "已注册: $taskFullName"
            } else {
                Write-Err "注册失败: $taskFullName — $result"
                throw "schtasks 创建失败: $taskFullName"
            }
        } finally {
            Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-ShutdownNotice {
    Write-Step "卸载..."

    foreach ($task in $EventTasks) {
        $taskFullName = "$TaskFolder\$($task.Name)"
        cmd.exe /c "schtasks /delete /tn `"$taskFullName`" /f >nul 2>nul"
        $delExit = $LASTEXITCODE
        if ($delExit -eq 0) {
            Write-OK "已删除: $taskFullName"
        } else {
            Write-Warn "任务不存在: $taskFullName"
        }
    }

    cmd.exe /c "schtasks /delete /tn `"$TaskFolder`" /f >nul 2>nul"
    $null = $LASTEXITCODE

    if ($RemoveFiles) {
        if (Test-Path $InstallPath) {
            Remove-Item -Path $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "已删除目录: $InstallPath"
        }
    }
}

# --- 主逻辑 ---
if ($Uninstall) {
    Uninstall-ShutdownNotice
    exit 0
}

if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

Write-Step "复制 exe 到 $InstallPath"
$sourceDir = if ($ExeSource) { $ExeSource } else { Join-Path $PSScriptRoot "ci-install" }
Copy-Item "$sourceDir\*.exe" $InstallPath -Force
Get-ChildItem $InstallPath -Filter *.exe | ForEach-Object {
    Write-OK "  $($_.Name)"
}

Register-AllTasks
