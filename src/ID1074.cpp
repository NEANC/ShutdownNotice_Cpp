#include "common.h"

/** ID1074: 进程被强制结束 / 系统关机 */
int wmain(int argc, wchar_t* argv[]) {
    EventArgs args;
    parse_event_args(argc, argv, args);

    return process_event_notify(
        1074,
        "计算机正在关闭",
        "事件ID: 1074",
        args.valid ? &args : nullptr);
}
