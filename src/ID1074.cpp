#include "common.h"

/** ID1074: 进程被强制结束 / 系统关机 */
int wmain(int argc, wchar_t* argv[]) {
#ifdef SN_DEBUG_TIMING
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
#endif

    EventArgs args;
    parse_event_args(argc, argv, args);

    int ret = process_event_notify(
        1074,
        "计算机正在关闭",
        "事件ID: 1074",
        args.valid ? &args : nullptr);

#ifdef SN_DEBUG_TIMING
    debug_wait_if_enabled();
#endif
    return ret;
}
