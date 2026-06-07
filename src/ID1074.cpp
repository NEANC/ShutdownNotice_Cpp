#include "common.h"

/** ID1074: 进程被强制结束 / 系统关机 */
int main() {
    return process_event_notify(
        1074,
        "计算机正在关闭",
        "事件ID: 1074");
}