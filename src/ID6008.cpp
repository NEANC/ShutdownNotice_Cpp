#include "common.h"

/** ID6008: 未正常关机的情况下重新启动 */
int wmain(int argc, wchar_t* argv[]) {
#ifdef SN_DEBUG_TIMING
    init_debug_console_utf8();
#endif

    EventArgs args;
    parse_event_args(argc, argv, args);

    int ret = process_event_notify(
        6008,
        "计算机意外关闭",
        "事件ID: 6008",
        args.valid ? &args : nullptr);

#ifdef SN_DEBUG_TIMING
    debug_wait_if_enabled();
#endif
    return ret;
}
