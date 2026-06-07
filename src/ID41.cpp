#include "common.h"

/** ID41: 未进行正常关机流程的情况下重新启动 */
int wmain(int argc, wchar_t* argv[]) {
    EventArgs args;
    parse_event_args(argc, argv, args);

    return process_event_notify(
        41,
        "计算机在意外关闭的情况下自动重启",
        "事件ID: 41",
        args.valid ? &args : nullptr);
}
