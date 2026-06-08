> [!WARNING]
> 本项目使用 TRAE IDE 生成与迭代

> [!CAUTION]
> 请注意：由 AI 生成的代码可能有：不可预知的风险和错误！  
> 如您需要直接使用本项目，请**审查并测试后再使用**；  
> 如您要将本项目引用到其他项目，请**重构后再使用**。

# Shutdown Notice (C++)

Windows 系统事件日志监控与通知工具，通过 Server酱 / 钉钉机器人推送关机、重启等关键事件通知。

## 特性

- **零依赖分发**：静态链接 MSVC 运行时，单文件 `.exe` 即可运行
- **多事件支持**：监控 5 种系统事件（ID 41 / 1074 / 6005 / 6006 / 6008）+ 关机脚本
- **双渠道推送**：支持 Server酱 和钉钉机器人，默认 failover 策略（主通道失败后自动切换备用）
- **一键安装**：PowerShell 脚本自动下载、注册计划任务、生成配置文件
- **钉钉加签**：自动计算 HMAC-SHA256 签名，无需额外配置

## 监控事件

| 程序         | 事件 ID | 说明                                 |
| ------------ | ------- | ------------------------------------ |
| `ID41.exe`   | 41      | 系统未正常关机即重启                 |
| `ID1074.exe` | 1074    | 用户或程序发起关机                   |
| `ID6005.exe` | 6005    | 事件日志服务已启动                   |
| `ID6006.exe` | 6006    | 事件日志服务已停止                   |
| `ID6008.exe` | 6008    | 上一次系统关闭是意外的               |
| `down.exe`   | —       | 获取当前计算机名和时间，发送关机通知 |

## 配置

首次运行任一程序时，会自动生成 `config.ini` 。填写配置后重新运行即可。

### 方法一：任务计划程序

1. 打开"任务计划程序"
2. 创建任务 → 触发器 → 新建 → "发生事件时"
3. 日志：`系统`，源：按需选择，事件 ID：对应事件
4. 操作 → 启动程序 → 选择对应的 `.exe`

### 方法二：组策略关机脚本

1. `gpedit.msc` → 计算机配置 → Windows 设置 → 脚本（启动/关机）
2. 添加 `down.exe` 为关机脚本

---

## 部署

### 一键安装

```powershell
irm https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1 | iex
```

### 卸载

```powershell
# 完整卸载
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1'))) -Uninstall -RemoveFiles

# 仅移除计划任务
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1'))) -Uninstall
```

### 自定义参数

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/NEANC/ShutdownNotice_Cpp/master/install.ps1'))) `
    -InstallPath "D:\Tools\Shutdown Notice" -Tag "v1.0.0"
```

---

## 构建

### 依赖

- CMake ≥ 3.15
- Visual Studio 2019+ 或 Build Tools for Visual Studio
- Windows SDK（包含 wevtapi.lib / winhttp.lib）

### 编译

```powershell
cd cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --parallel
```

---

## License

[WTFPL](./LICENSE)