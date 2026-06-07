#include "common.h"

/** ID6006: 事件日志服务已停止 */
int wmain(int argc, wchar_t* argv[]) {
    EventArgs args;
    parse_event_args(argc, argv, args);

    return process_event_notify(
        6006,
        "计算机已关闭",
        "事件ID: 6006",
        args.valid ? &args : nullptr);
}
