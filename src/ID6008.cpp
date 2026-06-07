#include "common.h"

/** ID6008: 未正常关机的情况下重新启动 */
int main() {
    return process_event_notify(
        6008,
        "计算机意外关闭",
        "事件ID: 6008");
}