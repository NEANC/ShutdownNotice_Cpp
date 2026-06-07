#include "common.h"

/** ID6005: 事件日志服务已启动 */
int main() {
    return process_event_notify(
        6005,
        "计算机已启动",
        "事件ID: 6005");
}