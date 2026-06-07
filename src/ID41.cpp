#include "common.h"

/** ID41: 未进行正常关机流程的情况下重新启动 */
int wmain(int argc, wchar_t* argv[]) {
#ifdef SN_DEBUG_TIMING
    init_debug_console_utf8();
#endif

    EventArgs args;
    parse_event_args(argc, argv, args);

    int ret = process_event_notify(
        41,
        "计算机在意外关闭的情况下自动重启",
        "事件ID: 41",
        args.valid ? &args : nullptr);

#ifdef SN_DEBUG_TIMING
    debug_wait_if_enabled();
#endif
    return ret;
}
