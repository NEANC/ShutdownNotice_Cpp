#include "common.h"

/** ID6005: 事件日志服务已启动 */
int wmain(int argc, wchar_t* argv[]) {
    EventArgs args;
    parse_event_args(argc, argv, args);

    return process_event_notify(
        6005,
        "计算机已启动",
        "事件ID: 6005",
        args.valid ? &args : nullptr);
}
