#include "common.h"

/** ID41: 未进行正常关机流程的情况下重新启动 */
int main() {
    return process_event_notify(
        41,
        "计算机在意外关闭的情况下自动重启",
        "事件ID: 41");
}