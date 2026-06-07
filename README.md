# Shutdown Notice (C++)

Windows 系统事件日志监控与通知工具，通过 Server酱 / 钉钉机器人推送关机、重启等关键事件通知。

## 特性

- **极速执行**：本地处理 2–5ms，含网络推送 12–55ms（取决于网络延迟）
- **零依赖分发**：静态链接 MSVC 运行时，单文件 `.exe` 即可运行
- **多事件支持**：监控 5 种系统事件（ID 41 / 1074 / 6005 / 6006 / 6008）
- **双渠道推送**：同时支持 Server酱 和钉钉机器人，任一成功即视为推送成功
- **钉钉加签**：自动计算 HMAC-SHA256 签名，无需额外配置
- **CI 自动构建**：GitHub Actions 自动编译并上传产物

## 监控事件

| 程序         | 事件 ID | 说明                                 |
| ------------ | ------- | ------------------------------------ |
| `ID41.exe`   | 41      | 系统未正常关机即重启                 |
| `ID1074.exe` | 1074    | 用户或程序发起关机                   |
| `ID6005.exe` | 6005    | 事件日志服务已启动                   |
| `ID6006.exe` | 6006    | 事件日志服务已停止                   |
| `ID6008.exe` | 6008    | 上一次系统关闭是意外的               |
| `down.exe`   | —       | 获取当前计算机名和时间，发送关机通知 |

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

产物输出至 `build/Release/` 目录。

## 配置

首次运行任一程序时，若 `config.ini` 不存在，会自动生成模板文件并终止。填写配置后重新运行即可。

```ini
[serverchan]
; Server酱 SendKey，从 https://sct.ftqq.com/ 获取
; 留空则不启用
sendkey = SCT********************

[dingtalk]
; 钉钉机器人 access_token（只需填 token 部分，无需完整 URL）
webhook = *********************************

; 加签密钥（可选），从钉钉机器人安全设置获取
secret = SECxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## 部署

### 方法一：任务计划程序

1. 打开"任务计划程序"
2. 创建任务 → 触发器 → 新建 → "发生事件时"
3. 日志：`系统`，源：按需选择，事件 ID：对应事件
4. 操作 → 启动程序 → 选择对应的 `.exe`

### 方法二：组策略关机脚本

1. `gpedit.msc` → 计算机配置 → Windows 设置 → 脚本（启动/关机）
2. 添加 `down.exe` 为关机脚本

## 项目结构

```
cpp/
├── CMakeLists.txt               # CMake 构建配置
├── config.ini                   # 通知渠道配置
├── README.md
├── .github/workflows/build.yml  # GitHub Actions CI
├── include/
│   └── common.h                 # 公共接口声明
└── src/
    ├── common.cpp               # 核心实现（事件查询 + 通知推送）
    ├── down.cpp                 # 关机通知
    ├── ID41.cpp                 # 事件 41 通知
    ├── ID1074.cpp               # 事件 1074 通知
    ├── ID6005.cpp               # 事件 6005 通知
    ├── ID6006.cpp               # 事件 6006 通知
    └── ID6008.cpp               # 事件 6008 通知
```

## 性能优化

- **配置缓存**：`config.ini` 全局单次读取，后续调用零 I/O
- **EvtRenderEventValues**：直接提取属性值，替代全量 XML 序列化+解析
- **字符串预分配**：JSON 体构建使用 `reserve()` 避免内存重分配
- **BCrypt 硬件加速**：HMAC-SHA256 加签使用 Windows 原生加密 API
