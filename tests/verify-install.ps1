# CI 验证脚本: 检查计划任务注册是否正确
# 独立 .ps1 文件 (UTF-8 BOM) 避免 YAML run: | 在 PS 5.1 下的 UTF-8 无 BOM 解析问题

param(
    [string]$TaskFolder = "Shutdown Notice",
    [string]$InstallPath = ""
)

$ErrorActionPreference = "Stop"

$expectedTasks = @(
    @{ Name = "WIN告知：ID41";   Exe = "ID41.exe";   EventID = 41 },
    @{ Name = "WIN告知：ID1074"; Exe = "ID1074.exe"; EventID = 1074 },
    @{ Name = "WIN告知：ID6005"; Exe = "ID6005.exe"; EventID = 6005 },
    @{ Name = "WIN告知：ID6006"; Exe = "ID6006.exe"; EventID = 6006 },
    @{ Name = "WIN告知：ID6008"; Exe = "ID6008.exe"; EventID = 6008 }
)

# ============================================================
# Part 1: 验证计划任务配置
# ============================================================
Write-Host "=== 验证计划任务 ==="

$errors = 0

foreach ($t in $expectedTasks) {
    $fullName = "$TaskFolder\$($t.Name)"
    Write-Host "---"
    Write-Host "检查: $fullName"

    $info = schtasks /query /tn $fullName /v /fo list 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAIL] 任务不存在: $fullName" -ForegroundColor Red
        $errors++
        continue
    }

    $info | ForEach-Object {
        if ($_ -match "^(TaskName|Schedule Type|Status|Logon Mode|Run As User|Start In|Task To Run|Comment):") {
            Write-Host "  $_"
        }
    }

    $xmlInfo = schtasks /query /tn $fullName /xml 2>&1
    $xml = $xmlInfo -join "`n"

    if ($xml -match "<EventTrigger>") {
        Write-Host "  [OK] 包含 EventTrigger" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] 缺少 EventTrigger" -ForegroundColor Red
        $errors++
    }

    if ($xml -match "EventID=$($t.EventID)") {
        Write-Host "  [OK] EventID 正确" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] EventID 不匹配, 预期 EventID=$($t.EventID)" -ForegroundColor Red
        $errors++
    }

    if ($xml -match "<ValueQueries>") {
        Write-Host "  [OK] 包含 ValueQueries" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] 缺少 ValueQueries" -ForegroundColor Red
        $errors++
    }

    if ($xml -match "Queue") {
        Write-Host "  [OK] MultipleInstancesPolicy = Queue" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] MultipleInstancesPolicy 不是 Queue" -ForegroundColor Red
        $errors++
    }

    # LogonType 在 schtasks /query 中报告为 Interactive/Background
    # 实际 S4U 应在 XML 中验证
    if ($xml -match "<LogonType>S4U</LogonType>") {
        Write-Host "  [OK] LogonType = S4U (XML 确认)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] LogonType 不是 S4U" -ForegroundColor Red
        $errors++
    }
}

Write-Host ""
Write-Host "=== 验证结果 ==="
if ($errors -eq 0) {
    Write-Host "全部 5 个任务配置正确" -ForegroundColor Green
} else {
    Write-Host "$errors 个任务配置异常" -ForegroundColor Red
    throw "计划任务验证失败"
}


# ============================================================
# Part 2: 验证 Arguments 参数
# ============================================================
Write-Host ""
Write-Host "=== 验证 Exec Action 参数 ==="

$errors = 0

$xmlLines = schtasks /query /tn "$TaskFolder\WIN告知：ID1074" /xml 2>&1
if ($LASTEXITCODE -ne 0) {
    $xmlLines | ForEach-Object { Write-Host $_ }
    throw "无法读取任务 XML"
}

# 关键: join 成单个字符串，否则 -notmatch 对数组返回非匹配行，永远非空
$xml = $xmlLines -join "`n"

if ($xml -notmatch "--event-id\s+1074") {
    Write-Host "[FAIL] 缺少 --event-id 1074 参数" -ForegroundColor Red; $errors++
} else {
    Write-Host "[OK] --event-id 1074 参数存在" -ForegroundColor Green
}

if ($xml -notmatch '\$\(EventRecordID\)') {
    Write-Host '[FAIL] 缺少 $(EventRecordID) 变量' -ForegroundColor Red; $errors++
} else {
    Write-Host '[OK] $(EventRecordID) 变量存在' -ForegroundColor Green
}

if ($xml -notmatch '\$\(SystemTime\)') {
    Write-Host '[FAIL] 缺少 $(SystemTime) 变量' -ForegroundColor Red; $errors++
} else {
    Write-Host '[OK] $(SystemTime) 变量存在' -ForegroundColor Green
}

if ($xml -notmatch '\$\(Computer\)') {
    Write-Host '[FAIL] 缺少 $(Computer) 变量' -ForegroundColor Red; $errors++
} else {
    Write-Host '[OK] $(Computer) 变量存在' -ForegroundColor Green
}

if ($xml -notmatch '\$\(Provider\)') {
    Write-Host '[FAIL] 缺少 $(Provider) 变量' -ForegroundColor Red; $errors++
} else {
    Write-Host '[OK] $(Provider) 变量存在' -ForegroundColor Green
}

if ($errors -gt 0) {
    Write-Host "=== 实际 XML ==="
    Write-Host $xml
    throw "任务参数验证失败: $errors 处异常"
}
Write-Host ""
Write-Host "[OK] 所有参数验证通过" -ForegroundColor Green
