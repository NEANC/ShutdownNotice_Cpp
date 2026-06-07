#include "common.h"

#include <windows.h>
#include <winevt.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <wincrypt.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <sstream>
#include <vector>

#pragma comment(lib, "wevtapi.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")


// 硬编码参数
static constexpr const wchar_t* EVENT_CHANNEL = L"System";            ///< 事件日志通道
static constexpr const wchar_t* SERVER_HOST = L"sctapi.ftqq.com";     ///< Server酱 API 主机
static constexpr const wchar_t* CONFIG_FILE = L"config.ini";          ///< 配置文件名
static constexpr unsigned long HTTP_RESOLVE_TIMEOUT_MS = 300;         ///< DNS 解析超时
static constexpr unsigned long HTTP_CONNECT_TIMEOUT_MS = 500;         ///< 连接超时
static constexpr unsigned long HTTP_SEND_TIMEOUT_MS = 500;            ///< 发送超时
static constexpr unsigned long HTTP_RECEIVE_TIMEOUT_MS = 800;         ///< 接收超时

// 耗时统计（仅在 define SN_DEBUG_TIMING 时启用）
#ifdef SN_DEBUG_TIMING
class ScopeTimer {
public:
    explicit ScopeTimer(const char* name) : name_(name) {
        QueryPerformanceFrequency(&freq_);
        QueryPerformanceCounter(&start_);
    }
    ~ScopeTimer() {
        LARGE_INTEGER end;
        QueryPerformanceCounter(&end);
        double ms = 1000.0 * static_cast<double>(end.QuadPart - start_.QuadPart)
                  / static_cast<double>(freq_.QuadPart);
        wchar_t buf[128];
        int len = swprintf_s(buf, L"[耗时] %hs: %.3f ms\n", name_, ms);
        if (len > 0) {
            DWORD written = 0;
            WriteConsoleW(GetStdHandle(STD_ERROR_HANDLE), buf,
                          static_cast<DWORD>(len), &written, nullptr);
        }
    }
private:
    const char* name_;
    LARGE_INTEGER freq_{};
    LARGE_INTEGER start_{};
};
#define SN_TIMER(name) ScopeTimer timer_##__LINE__(name)
#else
#define SN_TIMER(name) ((void)0)
#endif

/** 诊断版本等待用户按键。使用 WriteConsoleW 避免中文乱码 */
void debug_wait_if_enabled() {
    // 首次调用时设置控制台 UTF-8 代码页，确保 printf 中文正常显示
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);

    const wchar_t msg[] = L"\n[诊断] 按 Enter 键退出...";
    DWORD written = 0;
    WriteConsoleW(GetStdHandle(STD_ERROR_HANDLE), msg,
                  static_cast<DWORD>(wcslen(msg)), &written, nullptr);
    std::getchar();
}


// 配置缓存
struct ConfigCache {
    // [serverchan]
    std::string serverchan_sendkey;
    // [dingtalk]
    std::string dingtalk_webhook;
    std::string dingtalk_secret;
    // [notify]
    std::string notify_mode = "failover";            ///< primary_only | failover | both_sequential
    std::string notify_primary = "dingtalk";       ///< dingtalk | serverchan

    bool loaded = false;
};
static ConfigCache g_config;


/** 去除字符串首尾空白字符 */
static std::string trim(std::string_view s) {
    auto start = s.find_first_not_of(" \t\r\n");
    if (start == std::string_view::npos) return {};
    auto end = s.find_last_not_of(" \t\r\n");
    return std::string(s.substr(start, end - start + 1));
}


/** 配置文件模板内容 */
static constexpr const char* CONFIG_TEMPLATE =
    "# 关机通知系统 - 配置文件\n"
    "# 支持同时配置多个通知渠道，任一渠道成功即视为推送成功\n"
    "\n"
    "[serverchan]\n"
    "# ServerChan 推送密钥\n"
    "sendkey = \n"
    "\n"
    "[dingtalk]\n"
    "# 钉钉机器人 Webhook\n"
    "webhook = \n"
    "\n"
    "# 钉钉机器人加签密钥 (可选)，留空则不启用加签\n"
    "secret = \n"
    "\n"
    "[notify]\n"
    "# 通知策略: primary_only (仅主通道) / failover (主通道失败后备用) / both_sequential (串行双通道)\n"
    "mode = failover\n"
    "# 主通道: dingtalk / serverchan\n"
    "primary = dingtalk\n";


/** 钉钉 Webhook 基础 URL */
static constexpr const char* DINGTALK_BASE_URL =
    "https://oapi.dingtalk.com/robot/send?access_token=";


/** 一次性读取配置文件并缓存所有键值 */
static void load_config() {
    if (g_config.loaded) return;
    g_config.loaded = true;

    wchar_t exe_path[MAX_PATH] = {};
    DWORD len = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return;

    std::wstring_view exe_view(exe_path, len);
    auto last_sep = exe_view.find_last_of(L"\\/");
    if (last_sep == std::wstring_view::npos) return;

    std::wstring config_path(exe_view.substr(0, last_sep + 1));
    config_path += CONFIG_FILE;

    std::ifstream file(config_path);
    if (!file.is_open()) {
        std::ofstream out(config_path);
        if (out.is_open()) {
            out << CONFIG_TEMPLATE;
            out.close();
            std::fprintf(stderr,
                "[配置] 已生成模板配置文件 config.ini，请填写后重新运行\n");
        } else {
            std::fprintf(stderr,
                "[错误] 无法创建配置文件 config.ini\n");
        }
        std::exit(1);
    }

    std::string line;
    std::string section;
    while (std::getline(file, line)) {
        line = trim(line);
        if (line.empty() || line[0] == ';' || line[0] == '#') continue;

        if (line[0] == '[' && line.back() == ']') {
            section = line;
            continue;
        }

        auto eq = line.find('=');
        if (eq == std::string::npos) continue;

        auto key = trim(std::string_view(line.data(), eq));
        auto val = trim(std::string_view(line.data() + eq + 1,
                                          line.size() - eq - 1));

        if (section == "[serverchan]" && key == "sendkey")
            g_config.serverchan_sendkey = val;
        else if (section == "[dingtalk]") {
            if (key == "webhook" && !val.empty()) {
                if (val.compare(0, 4, "http") != 0)
                    g_config.dingtalk_webhook = DINGTALK_BASE_URL + val;
                else
                    g_config.dingtalk_webhook = val;
            } else if (key == "secret")
                g_config.dingtalk_secret = val;
        } else if (section == "[notify]") {
            if (key == "mode")  g_config.notify_mode = val;
            else if (key == "primary") g_config.notify_primary = val;
        }
    }
}


/** 获取 SendKey：优先从缓存读取，其次从环境变量 SC_SENDKEY */
static const std::string& get_sendkey() {
    load_config();
    if (!g_config.serverchan_sendkey.empty())
        return g_config.serverchan_sendkey;

    static const char* env_key = std::getenv("SC_SENDKEY");
    static std::string env_val = env_key ? env_key : "";
    return env_val;
}


// 辅助函数

/** 将宽字符串转换为 UTF-8 编码字符串 */
std::string wide_to_utf8(std::wstring_view wstr) {
    if (wstr.empty()) return {};

    int size_needed = WideCharToMultiByte(
        CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
        nullptr, 0, nullptr, nullptr);
    if (size_needed <= 0) return {};

    std::string result(size_needed, '\0');
    WideCharToMultiByte(
        CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
        result.data(), size_needed, nullptr, nullptr);
    return result;
}


/** HMAC-SHA256，返回 Base64 编码结果。SHA-256 输出固定 32 字节，无需查询 */
static std::string hmac_sha256_base64(const std::string& key,
                                      const std::string& data) {
    BCRYPT_ALG_HANDLE hAlg = nullptr;
    BCRYPT_HASH_HANDLE hHash = nullptr;

    NTSTATUS status = BCryptOpenAlgorithmProvider(
        &hAlg, BCRYPT_SHA256_ALGORITHM, nullptr,
        BCRYPT_ALG_HANDLE_HMAC_FLAG);
    if (!BCRYPT_SUCCESS(status)) return {};

    status = BCryptCreateHash(
        hAlg, &hHash, nullptr, 0,
        reinterpret_cast<PUCHAR>(const_cast<char*>(key.data())),
        static_cast<ULONG>(key.size()), 0);
    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(hAlg, 0);
        return {};
    }

    status = BCryptHashData(
        hHash,
        reinterpret_cast<PUCHAR>(const_cast<char*>(data.data())),
        static_cast<ULONG>(data.size()), 0);

    // SHA-256 固定 32 字节，省去 BCryptGetProperty 查询
    std::array<BYTE, 32> hash{};
    status = BCryptFinishHash(hHash, hash.data(), static_cast<ULONG>(hash.size()), 0);

    BCryptDestroyHash(hHash);
    BCryptCloseAlgorithmProvider(hAlg, 0);

    if (!BCRYPT_SUCCESS(status)) return {};

    DWORD base64_size = 0;
    CryptBinaryToStringA(hash.data(), static_cast<DWORD>(hash.size()),
                         CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                         nullptr, &base64_size);
    if (base64_size == 0) return {};

    std::string result(base64_size, '\0');
    CryptBinaryToStringA(hash.data(), static_cast<DWORD>(hash.size()),
                         CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                         result.data(), &base64_size);
    while (!result.empty() && result.back() == '\0') result.pop_back();
    return result;
}


/** URL 编码（保留字母数字和 -_.~） */
static std::string url_encode(const std::string& s) {
    std::string result;
    result.reserve(s.size() * 3);
    char buf[4];

    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            result += static_cast<char>(c);
        } else {
            std::snprintf(buf, sizeof(buf), "%%%02X", c);
            result += buf;
        }
    }
    return result;
}


/** JSON 字符串转义 — 直接追加到目标 buffer（避免临时 std::string） */
static void append_json_escaped(std::string& out, std::string_view s) {
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[7];
                    std::snprintf(buf, sizeof(buf), "\\u%04X",
                                  static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out += c;
                }
                break;
        }
    }
}


/**
 * 通用 HTTP POST JSON 请求
 */
static bool http_post_json(const std::wstring& host, WORD port,
                           const std::wstring& path, bool use_ssl,
                           const std::string& json_body) {
    HINTERNET hSession = WinHttpOpen(
        L"ShutdownNotice/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return false;

    HINTERNET hConnect = WinHttpConnect(hSession, host.c_str(), port, 0);
    if (!hConnect) {
        WinHttpCloseHandle(hSession);
        return false;
    }

    DWORD flags = use_ssl ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hRequest = WinHttpOpenRequest(
        hConnect, L"POST", path.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hRequest) {
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    WinHttpSetTimeouts(hRequest,
                       HTTP_RESOLVE_TIMEOUT_MS,
                       HTTP_CONNECT_TIMEOUT_MS,
                       HTTP_SEND_TIMEOUT_MS,
                       HTTP_RECEIVE_TIMEOUT_MS);

    const wchar_t* headers = L"Content-Type: application/json; charset=utf-8\r\n";
    DWORD header_len = static_cast<DWORD>(wcslen(headers));

    BOOL ok = WinHttpSendRequest(
        hRequest, headers, header_len,
        const_cast<char*>(json_body.data()),
        static_cast<DWORD>(json_body.size()),
        static_cast<DWORD>(json_body.size()), 0);

    if (!ok) {
        std::fprintf(stderr, "[错误] HTTP 请求失败: %lu\n", GetLastError());
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    ok = WinHttpReceiveResponse(hRequest, nullptr);
    DWORD status_code = 0;
    DWORD status_size = sizeof(status_code);
    if (ok) {
        WinHttpQueryHeaders(
            hRequest,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX,
            &status_code, &status_size, WINHTTP_NO_HEADER_INDEX);
    }

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);

    if (!ok) {
        std::fprintf(stderr, "[错误] 未收到服务器响应\n");
        return false;
    }

    if (status_code < 200 || status_code >= 300) {
        std::fprintf(stderr, "[错误] 服务器返回 HTTP %lu\n", status_code);
        return false;
    }

    return true;
}


// 事件日志查询

/** EvtRenderEventValues 属性路径 */
static constexpr const wchar_t* EVT_PROP_TIME = L"Event/System/TimeCreated/@SystemTime";
static constexpr const wchar_t* EVT_PROP_COMPUTER = L"Event/System/Computer";
static constexpr const wchar_t* EVT_PROP_PROVIDER = L"Event/System/Provider/@Name";


/** 是否需要完整的事件消息 (仅 1074 用户关机原因需原文) */
static bool need_full_event_message(unsigned long event_id) {
    return event_id == 1074;
}


/** 固定事件描述 (非 1074 事件跳过 EvtFormatMessage 开销) */
static const wchar_t* fast_event_desc_w(unsigned long event_id) {
    switch (event_id) {
        case 41:   return L"系统未正常关机即重启";
        case 6005: return L"事件日志服务已启动";
        case 6006: return L"事件日志服务已停止";
        case 6008: return L"上一次系统关闭是意外的";
        default:   return L"系统事件已触发";
    }
}


/**
 * 通用事件查询核心 — 执行 EvtQuery→EvtNext→EvtRender→EvtFormatMessage 流水线
 *
 * @param xpath     XPath 查询表达式
 * @param flags     EvtQuery 标志 (EvtQueryChannelPath 自动追加)
 * @param info      输出 EventInfo
 * @param event_id  事件 ID (用于决定是否执行 EvtFormatMessage)
 * @return true 成功
 */
static bool query_event_core(const wchar_t* xpath, DWORD flags,
                             EventInfo& info, unsigned long event_id) {
    EVT_HANDLE hResults = EvtQuery(
        nullptr, EVENT_CHANNEL, xpath,
        EvtQueryChannelPath | flags);
    if (!hResults) {
        std::fprintf(stderr, "[错误] EvtQuery 失败: GLE=%lu\n", GetLastError());
        return false;
    }

    EVT_HANDLE hEvent = nullptr;
    DWORD dwReturned = 0;
    BOOL ok = EvtNext(hResults, 1, &hEvent, 0, 0, &dwReturned);
    DWORD evtNextErr = GetLastError();
    EvtClose(hResults);

    if (!ok) {
        if (evtNextErr == ERROR_NO_MORE_ITEMS || evtNextErr == ERROR_TIMEOUT)
            return false;
        std::fprintf(stderr, "[错误] EvtNext 失败: GLE=%lu\n", evtNextErr);
        return false;
    }
    if (dwReturned == 0) return false;

    const wchar_t* properties[] = {EVT_PROP_TIME, EVT_PROP_COMPUTER, EVT_PROP_PROVIDER};
    EVT_HANDLE hContext = EvtCreateRenderContext(3, properties, EvtRenderContextValues);
    if (!hContext) {
        std::fprintf(stderr, "[错误] EvtCreateRenderContext 失败: GLE=%lu\n", GetLastError());
        EvtClose(hEvent);
        return false;
    }

    DWORD render_size = 0;
    DWORD props = 0;
    BOOL render_ok = EvtRender(hContext, hEvent, EvtRenderEventValues,
                               0, nullptr, &render_size, &props);
    if (!render_ok && GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
        std::fprintf(stderr, "[错误] EvtRender 获取缓冲区失败: GLE=%lu\n", GetLastError());
        EvtClose(hContext);
        EvtClose(hEvent);
        return false;
    }

    std::vector<BYTE> render_buffer(render_size);
    render_ok = EvtRender(hContext, hEvent, EvtRenderEventValues,
                          render_size, render_buffer.data(), &render_size, &props);
    EvtClose(hContext);
    if (!render_ok || props < 3) {
        std::fprintf(stderr, "[错误] EvtRender 失败: GLE=%lu\n", GetLastError());
        EvtClose(hEvent);
        return false;
    }

    auto* values = reinterpret_cast<PEVT_VARIANT>(render_buffer.data());

    if (values[0].Type == EvtVarTypeFileTime && values[0].FileTimeVal) {
        FILETIME ft;
        ULONGLONG ft_val = values[0].FileTimeVal;
        ft.dwLowDateTime = static_cast<DWORD>(ft_val & 0xFFFFFFFF);
        ft.dwHighDateTime = static_cast<DWORD>(ft_val >> 32);

        SYSTEMTIME utc, local;
        FileTimeToSystemTime(&ft, &utc);
        SystemTimeToTzSpecificLocalTime(nullptr, &utc, &local);

        wchar_t buf[32];
        swprintf_s(buf, L"%04d-%02d-%02d %02d:%02d:%02d",
                   local.wYear, local.wMonth, local.wDay,
                   local.wHour, local.wMinute, local.wSecond);
        info.date = buf;
    }

    if (values[1].Type == EvtVarTypeString && values[1].StringVal) {
        info.computer = values[1].StringVal;
    }

    // 非 1074 → 固定描述，跳过 EvtFormatMessage
    if (!need_full_event_message(event_id)) {
        info.desc = fast_event_desc_w(event_id);
        EvtClose(hEvent);
        return true;
    }

    // --- 仅 1074: EvtFormatMessage ---
    std::wstring provider_name;
    if (values[2].Type == EvtVarTypeString && values[2].StringVal) {
        provider_name = values[2].StringVal;
    }

    EVT_HANDLE hPublisher = nullptr;
    if (!provider_name.empty()) {
        hPublisher = EvtOpenPublisherMetadata(
            nullptr, provider_name.c_str(), nullptr, 0, 0);
    }

    DWORD msg_size = 0;
    EvtFormatMessage(hPublisher, hEvent, 0, 0, nullptr,
                     EvtFormatMessageEvent, 0, nullptr, &msg_size);

    if (msg_size > 0) {
        std::wstring msg_buffer(msg_size, L'\0');
        ok = EvtFormatMessage(
            hPublisher, hEvent, 0, 0, nullptr,
            EvtFormatMessageEvent, msg_size,
            msg_buffer.data(), &msg_size);
        if (ok) {
            while (!msg_buffer.empty() &&
                   (msg_buffer.back() == L'\0' ||
                    msg_buffer.back() == L'\n' ||
                    msg_buffer.back() == L'\r')) {
                msg_buffer.pop_back();
            }
            info.desc = std::move(msg_buffer);
        }
    }

    if (hPublisher) EvtClose(hPublisher);
    EvtClose(hEvent);
    return !info.date.empty() || !info.desc.empty();
}


bool query_latest_event(unsigned long event_id, EventInfo& info) {
    SN_TIMER("query_latest_event");

    wchar_t query[256];
    swprintf_s(query, L"*[System[(EventID=%lu)]]", event_id);

    return query_event_core(query, EvtQueryReverseDirection, info, event_id);
}


/**
 * 按 EventRecordID 精确查询事件 (用于 1074 fast path)
 * 避免短时间内多个 1074 时取错记录
 */
static bool query_event_by_record_id(unsigned long long record_id,
                                     unsigned long event_id,
                                     EventInfo& info) {
    SN_TIMER("query_event_by_record_id");

    wchar_t query[256];
    swprintf_s(query,
        L"*[System[(EventID=%lu) and (EventRecordID=%llu)]]",
        event_id, record_id);

    return query_event_core(query, 0, info, event_id);
}


// 通知接口实现

bool send_serverchan_notify(const std::string& title,
                            const std::string& desp) {
    const auto& sendkey = get_sendkey();
    if (sendkey.empty()) {
        std::fprintf(stderr, "[Server酱] 未配置 sendkey, 跳过\n");
        return false;
    }

    std::string json_body;
    json_body.reserve(64 + title.size() + desp.size() + desp.size() / 8);
    json_body = "{\"title\":\"";
    append_json_escaped(json_body, title);
    json_body += "\",\"desp\":\"";
    append_json_escaped(json_body, desp);
    json_body += "\"}";

    std::wstring wsendkey(sendkey.begin(), sendkey.end());
    std::wstring path = L"/" + wsendkey + L".send";

    return http_post_json(SERVER_HOST, INTERNET_DEFAULT_HTTPS_PORT,
                          path, true, json_body);
}


bool send_dingtalk_notify(const std::string& title,
                          const std::string& desp) {
    load_config();
    const auto& webhook = g_config.dingtalk_webhook;
    if (webhook.empty()) {
        std::fprintf(stderr, "[钉钉] 未配置 webhook, 跳过\n");
        return false;
    }

    std::string_view url_view = webhook;
    bool use_ssl = false;

    if (url_view.compare(0, 8, "https://") == 0) {
        use_ssl = true;
        url_view = url_view.substr(8);
    } else if (url_view.compare(0, 7, "http://") == 0) {
        url_view = url_view.substr(7);
    }

    auto slash_pos = url_view.find('/');
    std::string host, path;
    if (slash_pos != std::string_view::npos) {
        host = url_view.substr(0, slash_pos);
        path = url_view.substr(slash_pos);
    } else {
        host = url_view;
        path = "/";
    }

    const auto& secret = g_config.dingtalk_secret;
    if (!secret.empty()) {
        auto now = std::chrono::system_clock::now();
        auto ts = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
        std::string timestamp = std::to_string(ts);

        std::string sign_raw;
        sign_raw.reserve(timestamp.size() + 1 + secret.size());
        sign_raw = timestamp;
        sign_raw += '\n';
        sign_raw += secret;

        std::string sign = hmac_sha256_base64(secret, sign_raw);
        std::string sep = (path.find('?') == std::string::npos) ? "?" : "&";
        path += sep;
        path += "timestamp=";
        path += timestamp;
        path += "&sign=";
        path += url_encode(sign);
    }

    std::string json_body;
    json_body.reserve(128 + title.size() + desp.size() + desp.size() / 8);
    json_body = "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"";
    append_json_escaped(json_body, title);
    json_body += "\",\"text\":\"";
    append_json_escaped(json_body, desp);
    json_body += "\"}}";

    std::wstring whost(host.begin(), host.end());
    std::wstring wpath(path.begin(), path.end());
    WORD port = use_ssl ? INTERNET_DEFAULT_HTTPS_PORT
                        : INTERNET_DEFAULT_HTTP_PORT;

    return http_post_json(whost, port, wpath, use_ssl, json_body);
}


void send_notify(const std::string& title, const std::string& desp) {
    SN_TIMER("send_notify");
    load_config();

    const auto& mode = g_config.notify_mode;
    const bool has_dingtalk = !g_config.dingtalk_webhook.empty();
    const bool has_serverchan = !get_sendkey().empty();

    // primary_only: 仅发主通道
    if (mode == "primary_only") {
        if (g_config.notify_primary == "serverchan") {
            send_serverchan_notify(title, desp);
        } else {
            send_dingtalk_notify(title, desp);
        }
        return;
    }

    // failover: 主通道失败后尝试备用
    if (mode == "failover") {
        if (g_config.notify_primary == "serverchan") {
            if (send_serverchan_notify(title, desp)) return;
            send_dingtalk_notify(title, desp);
        } else {
            if (send_dingtalk_notify(title, desp)) return;
            send_serverchan_notify(title, desp);
        }
        return;
    }

    // both_sequential (默认): 双渠道都发
    bool serverchan_ok = false;
    bool dingtalk_ok = false;
    if (has_serverchan) serverchan_ok = send_serverchan_notify(title, desp);
    if (has_dingtalk)   dingtalk_ok   = send_dingtalk_notify(title, desp);

    if (!serverchan_ok && !dingtalk_ok) {
        std::fprintf(stderr, "[通知] 所有渠道推送均失败\n");
    }
}


// 命令行解析 & process_event_notify

/** 解析 ISO-8601 UTC 时间字符串并转为本地时间 */
static std::wstring local_time_from_iso_utc(std::wstring_view iso) {
    // 输入如 "2026-06-08T12:30:45.000000000Z" 或 "2026-06-08T12:30:45"
    if (iso.size() < 19) return std::wstring(iso);

    SYSTEMTIME utc{};
    std::wstring s(iso.substr(0, 19));  // "YYYY-MM-DDTHH:MM:SS"
    s[10] = L' ';  // T → 空格，用于 swscanf
    if (swscanf_s(s.c_str(), L"%hu-%hu-%hu %hu:%hu:%hu",
                  &utc.wYear, &utc.wMonth, &utc.wDay,
                  &utc.wHour, &utc.wMinute, &utc.wSecond) != 6) {
        return std::wstring(iso);
    }

    SYSTEMTIME local{};
    if (!SystemTimeToTzSpecificLocalTime(nullptr, &utc, &local)) {
        return std::wstring(iso);
    }

    wchar_t buf[32];
    swprintf_s(buf, L"%04u-%02u-%02u %02u:%02u:%02u",
               local.wYear, local.wMonth, local.wDay,
               local.wHour, local.wMinute, local.wSecond);
    return buf;
}


/** 检测 Task Scheduler 变量未被替换 (形如 $(xxx)) */
static bool is_unresolved_task_var(std::wstring_view v) {
    return v.size() >= 3 && v[0] == L'$' && v[1] == L'(';
}

/** 综合检查 EventArgs 是否可用作 fast path */
static bool is_usable_event_args(unsigned long expected_event_id,
                                 const EventArgs& args) {
    if (!args.valid) return false;
    if (args.event_id != expected_event_id) return false;
    if (args.system_time.empty()) return false;
    if (is_unresolved_task_var(args.system_time)) return false;
    if (!args.computer.empty() && is_unresolved_task_var(args.computer)) return false;
    return true;
}


bool parse_event_args(int argc, wchar_t* argv[], EventArgs& out) {
    out.valid = false;
    bool has_any = false;

    for (int i = 1; i < argc; ++i) {
        std::wstring_view arg(argv[i]);

        if (arg == L"--event-id" && i + 1 < argc) {
            out.event_id = wcstoul(argv[++i], nullptr, 10);
            has_any = true;
        } else if (arg == L"--time" && i + 1 < argc) {
            out.system_time = local_time_from_iso_utc(argv[++i]);
            has_any = true;
        } else if (arg == L"--computer" && i + 1 < argc) {
            out.computer = argv[++i];
            has_any = true;
        } else if (arg == L"--provider" && i + 1 < argc) {
            out.provider = argv[++i];
            has_any = true;
        } else if (arg == L"--record" && i + 1 < argc) {
            out.record_id = _wcstoui64(argv[++i], nullptr, 10);
            has_any = true;
        }
    }

    out.valid = has_any;
    return has_any;
}


int process_event_notify(unsigned long event_id,
                         const std::string& title,
                         const std::string& event_label) {
    return process_event_notify(event_id, title, event_label, nullptr);
}


int process_event_notify(unsigned long event_id,
                         const std::string& title,
                         const std::string& event_label,
                         const EventArgs* args) {
    SN_TIMER("process_event_notify");
    try {
        EventInfo info;

        if (args && is_usable_event_args(event_id, *args)) {
            // fast path: 使用 Task Scheduler 传入的字段
            info.date = args->system_time;
            info.computer = args->computer;
            if (event_id != 1074) {
                info.desc = fast_event_desc_w(event_id);
            } else if (args->record_id != 0ULL) {
                // 1074 + EventRecordID: 精确查询触发任务的那条事件
                if (!query_event_by_record_id(args->record_id,
                                              event_id, info)) {
                    std::fprintf(stderr,
                        "[错误] 未找到 EventRecordID=%llu 的 EventID=%lu 记录\n",
                        args->record_id, event_id);
                    return 1;
                }
            } else {
                // 1074 无 record_id: 回退到查询最新
                if (!query_latest_event(event_id, info)) {
                    std::fprintf(stderr,
                        "[错误] 未在系统日志中找到 EventID=%lu 的记录\n", event_id);
                    return 1;
                }
            }
        } else {
            // fallback: 查日志
            if (!query_latest_event(event_id, info)) {
                std::fprintf(stderr,
                    "[错误] 未在系统日志中找到 EventID=%lu 的记录\n", event_id);
                return 1;
            }
        }

        // 构建 Markdown 格式的通知内容
        std::string desp;
        desp.reserve(256);
        desp += "**";
        desp += event_label;
        desp += "**  \n\n";
        desp += "**时间**: ";
        desp += wide_to_utf8(info.date);
        desp += "  \n\n";
        desp += "**详情**: ";
        desp += wide_to_utf8(info.desc);

        send_notify(title, desp);
        return 0;
    } catch (...) {
        return 1;
    }
}
