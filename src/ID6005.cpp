#include "common.h"

/** ID6005: 事件日志服务已启动 */
int wmain(int argc, wchar_t* argv[]) {
#ifdef SN_DEBUG_TIMING
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
#endif

    EventArgs args;
    parse_event_args(argc, argv, args);

    int ret = process_event_notify(
        6005,
        "计算机已启动",
        "事件ID: 6005",
        args.valid ? &args : nullptr);

#ifdef SN_DEBUG_TIMING
    debug_wait_if_enabled();
#endif
    return ret;
}
