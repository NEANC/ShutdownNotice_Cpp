#include "common.h"

#include <windows.h>
#include <winevt.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <wincrypt.h>

#include <algorithm>
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
static constexpr unsigned long HTTP_TIMEOUT_MS = 1000;                ///< HTTP 超时(毫秒)
static constexpr const wchar_t* CONFIG_FILE = L"config.ini";          ///< 配置文件名


// 配置缓存 — 单次读取 config.ini，全局复用，消除重复 I/O
struct ConfigCache {
    std::string serverchan_sendkey;
    std::string dingtalk_webhook;
    std::string dingtalk_secret;
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
    "# 留空则不启用 ServerChan 推送\n"
    "sendkey = \n"
    "\n"
    "[dingtalk]\n"
    "# 留空则不启用钉钉推送\n"
    "webhook = \n"
    "\n"
    "# 钉钉机器人加签密钥 (可选)，留空则不启用加签\n"
    "secret = \n";

/** 钉钉 Webhook 基础 URL */
static constexpr const char* DINGTALK_BASE_URL =
    "https://oapi.dingtalk.com/robot/send?access_token=";

/** 一次性读取配置文件并缓存所有键值 */
static void load_config() {
    if (g_config.loaded) return;
    g_config.loaded = true;

    // 获取 exe 所在目录
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
        // 配置文件不存在，自动生成模板
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
        // 终止程序
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
                // 若只填了 access_token，自动拼接完整 URL
                if (val.compare(0, 4, "http") != 0)
                    g_config.dingtalk_webhook = DINGTALK_BASE_URL + val;
                else
                    g_config.dingtalk_webhook = val;
            } else if (key == "secret")
                g_config.dingtalk_secret = val;
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

/** HMAC-SHA256 计算并返回 Base64 编码结果 */
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

    DWORD hash_size = 0;
    DWORD cb_result = 0;
    BCryptGetProperty(hAlg, BCRYPT_HASH_LENGTH,
                      reinterpret_cast<PUCHAR>(&hash_size),
                      sizeof(hash_size), &cb_result, 0);

    std::vector<BYTE> hash(hash_size);
    status = BCryptFinishHash(hHash, hash.data(), hash_size, 0);

    BCryptDestroyHash(hHash);
    BCryptCloseAlgorithmProvider(hAlg, 0);

    if (!BCRYPT_SUCCESS(status)) return {};

    DWORD base64_size = 0;
    CryptBinaryToStringA(hash.data(), hash_size,
                         CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                         nullptr, &base64_size);
    if (base64_size == 0) return {};

    std::string result(base64_size, '\0');
    CryptBinaryToStringA(hash.data(), hash_size,
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

/** JSON 字符串转义 */
static std::string json_escape(const std::string& s) {
    std::string result;
    result.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '"':  result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\n': result += "\\n";  break;
            case '\r': result += "\\r";  break;
            case '\t': result += "\\t";  break;
            default:   result += c;      break;
        }
    }
    return result;
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

    WinHttpSetTimeouts(hRequest, HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS,
                       HTTP_TIMEOUT_MS, HTTP_TIMEOUT_MS);

    const wchar_t* headers = L"Content-Type: application/json\r\n";
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


// 公共接口实现
/** EvtRenderEventValues 属性路径 */
static constexpr const wchar_t* EVT_PROP_TIME = L"Event/System/TimeCreated/@SystemTime";
static constexpr const wchar_t* EVT_PROP_COMPUTER = L"Event/System/Computer";
static constexpr const wchar_t* EVT_PROP_PROVIDER = L"Event/System/Provider/@Name";

bool query_latest_event(unsigned long event_id, EventInfo& info) {
    // 构建 XPath 查询
    wchar_t query[256];
    swprintf_s(query, L"*[System[(EventID=%lu)]]", event_id);

    EVT_HANDLE hResults = EvtQuery(
        nullptr, EVENT_CHANNEL, query,
        EvtQueryChannelPath | EvtQueryReverseDirection);
    if (!hResults) return false;

    EVT_HANDLE hEvent = nullptr;
    DWORD dwReturned = 0;
    BOOL ok = EvtNext(hResults, 1, &hEvent, INFINITE, 0, &dwReturned);
    EvtClose(hResults);

    if (!ok || dwReturned == 0) return false;

    // 直接渲染指定属性值（避免全量 XML 序列化/解析开销）
    const wchar_t* properties[] = {EVT_PROP_TIME, EVT_PROP_COMPUTER, EVT_PROP_PROVIDER};
    EVT_HANDLE hContext = EvtCreateRenderContext(3, properties, EvtRenderContextValues);

    EVT_VARIANT values[3] = {};
    if (hContext) {
        DWORD used = 0, props = 0;
        EvtRender(hContext, hEvent, EvtRenderEventValues,
                  sizeof(values), values, &used, &props);
        EvtClose(hContext);
    }

    // 提取时间 (FILETIME → 格式化字符串)
    if (values[0].Type == EvtVarTypeFileTime && values[0].FileTimeVal) {
        SYSTEMTIME st;
        FILETIME ft;
        ULONGLONG ft_val = values[0].FileTimeVal;
        ft.dwLowDateTime = static_cast<DWORD>(ft_val & 0xFFFFFFFF);
        ft.dwHighDateTime = static_cast<DWORD>(ft_val >> 32);
        FileTimeToSystemTime(&ft, &st);
        wchar_t buf[32];
        swprintf_s(buf, L"%04d-%02d-%02d %02d:%02d:%02d",
                   st.wYear, st.wMonth, st.wDay,
                   st.wHour, st.wMinute, st.wSecond);
        info.date = buf;
    }

    // 提取计算机名
    if (values[1].Type == EvtVarTypeString && values[1].StringVal) {
        info.computer = values[1].StringVal;
    }

    // 提取 Provider 名称用于获取发布者元数据
    std::wstring provider_name;
    if (values[2].Type == EvtVarTypeString && values[2].StringVal) {
        provider_name = values[2].StringVal;
    }

    // 获取发布者句柄
    EVT_HANDLE hPublisher = nullptr;
    if (!provider_name.empty()) {
        hPublisher = EvtOpenPublisherMetadata(
            nullptr, provider_name.c_str(), nullptr, 0, 0);
    }

    // 格式化事件消息
    DWORD msg_size = 0;
    EvtFormatMessage(hPublisher, hEvent, 0, 0, nullptr,
                     EvtFormatMessageEvent, 0, nullptr, &msg_size);

    if (msg_size > 0) {
        std::wstring msg_buffer(msg_size / sizeof(wchar_t), L'\0');
        ok = EvtFormatMessage(
            hPublisher, hEvent, 0, 0, nullptr,
            EvtFormatMessageEvent, msg_size,
            msg_buffer.data(), &msg_size);
        if (ok) {
            // 去掉尾部空行
            while (!msg_buffer.empty() &&
                   (msg_buffer.back() == L'\n' || msg_buffer.back() == L'\r')) {
                msg_buffer.pop_back();
            }
            info.desc = std::move(msg_buffer);
        }
    }

    if (hPublisher) EvtClose(hPublisher);
    EvtClose(hEvent);
    return !info.date.empty() || !info.desc.empty();
}

bool send_serverchan_notify(const std::string& title,
                            const std::string& desp) {
    const auto& sendkey = get_sendkey();
    if (sendkey.empty()) {
        std::fprintf(stderr, "[Server酱] 未配置 sendkey, 跳过\n");
        return false;
    }

    // 构建 JSON 请求体（预分配减少重分配）
    std::string json_body;
    json_body.reserve(64 + title.size() + desp.size());
    json_body = "{\"title\":\"";
    json_body += json_escape(title);
    json_body += "\",\"desp\":\"";
    json_body += json_escape(desp);
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

    // 解析 URL: https://oapi.dingtalk.com/robot/send?access_token=xxx
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

    // 加签处理（使用缓存中的 secret）
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

    // 构建钉钉 Markdown 消息（预分配减少重分配）
    std::string json_body;
    json_body.reserve(256 + title.size() + desp.size());
    json_body = "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"";
    json_body += json_escape(title);
    json_body += "\",\"text\":\"";
    json_body += json_escape(desp);
    json_body += "\"}}";

    std::wstring whost(host.begin(), host.end());
    std::wstring wpath(path.begin(), path.end());
    WORD port = use_ssl ? INTERNET_DEFAULT_HTTPS_PORT
                        : INTERNET_DEFAULT_HTTP_PORT;

    return http_post_json(whost, port, wpath, use_ssl, json_body);
}

void send_notify(const std::string& title, const std::string& desp) {
    bool serverchan_ok = send_serverchan_notify(title, desp);
    bool dingtalk_ok = send_dingtalk_notify(title, desp);

    if (!serverchan_ok && !dingtalk_ok) {
        std::fprintf(stderr, "[通知] 所有渠道推送均失败\n");
    }
}

int process_event_notify(unsigned long event_id,
                         const std::string& title,
                         const std::string& event_label) {
    try {
        EventInfo info;
        if (!query_latest_event(event_id, info)) return 1;

        // 构建 Markdown 格式的通知内容
        std::ostringstream desp;
        desp << "**" << event_label << "**  \n\n"
             << "**时间**: " << wide_to_utf8(info.date) << "  \n\n"
             << "**详情**: " << wide_to_utf8(info.desc);

        send_notify(title, desp.str());
        return 0;
    } catch (...) {
        return 1;
    }
}