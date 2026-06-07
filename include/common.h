#pragma once

#include <string>
#include <string_view>


// 关机通知系统 - 共享声明
// 功能：查询 Windows 事件日志，格式化后通过 Server酱 推送通知

/** 事件日志查询结果 */
struct EventInfo {
    std::wstring date;      ///< 事件发生时间
    std::wstring computer;  ///< 计算机名称
    std::wstring desc;      ///< 事件详细描述
};

/** 将宽字符串转换为 UTF-8 编码字符串 */
std::string wide_to_utf8(std::wstring_view wstr);

/**
 * 查询最新的指定事件ID的系统日志
 *
 * @param event_id Windows 事件 ID (如 41, 1074, 6005 等)
 * @param info     输出参数，存储查询结果
 * @return true 查询成功, false 查询失败
 */
bool query_latest_event(unsigned long event_id, EventInfo& info);

/**
 * 通过 Server酱 发送通知
 *
 * @param title 通知标题 (UTF-8, 支持 Markdown)
 * @param desp  通知内容 (UTF-8, 支持 Markdown)
 * @return true 发送成功, false 发送失败
 */
bool send_serverchan_notify(const std::string& title, const std::string& desp);

/**
 * 通过钉钉机器人 Webhook 发送通知
 *
 * 从 config.ini [dingtalk] 节读取 webhook 和 secret 配置
 * 若 secret 不为空，自动计算 HMAC-SHA256 加签
 *
 * @param title 通知标题 (UTF-8, 支持 Markdown)
 * @param desp  通知内容 (UTF-8, 支持 Markdown)
 * @return true 发送成功, false 发送失败
 */
bool send_dingtalk_notify(const std::string& title, const std::string& desp);

/**
 * 统一通知入口：根据 config.ini 配置自动选择推送渠道
 *
 * 优先级：同时尝试所有已配置的渠道（Server酱 + 钉钉）
 * 任一渠道成功即视为整体成功（仅记录错误日志，不中断其他渠道）
 *
 * @param title 通知标题 (UTF-8, 支持 Markdown)
 * @param desp  通知内容 (UTF-8, 支持 Markdown)
 */
void send_notify(const std::string& title, const std::string& desp);

/**
 * 便捷函数：查询事件日志并发送通知
 *
 * @param event_id     Windows 事件 ID
 * @param title        通知标题
 * @param event_label  事件标签，如 "事件ID: 41"
 * @return int 0 成功, 1 失败
 */
int process_event_notify(unsigned long event_id,
                         const std::string& title,
                         const std::string& event_label);