#include "common.h"

#include <windows.h>

#include <cstdio>
#include <ctime>

/**
 * down: 关机通知
 * 获取当前计算机名和时间，通过已配置的通知渠道推送关机告知
 */
int main() {
    try {
        // 获取计算机名
        wchar_t computer_name[MAX_COMPUTERNAME_LENGTH + 1] = {};
        DWORD name_size = MAX_COMPUTERNAME_LENGTH + 1;
        GetComputerNameW(computer_name, &name_size);

        // 获取当前时间 (格式: YYYY/MM/DD HH:MM:SS)
        SYSTEMTIME st;
        GetLocalTime(&st);
        wchar_t time_buf[32];
        swprintf_s(time_buf, L"%04d/%02d/%02d %02d:%02d:%02d",
                   st.wYear, st.wMonth, st.wDay,
                   st.wHour, st.wMinute, st.wSecond);

        // 构建通知内容
        std::string desp;
        desp.reserve(128);
        desp += "计算机 **";
        desp += wide_to_utf8(std::wstring_view(computer_name));
        desp += "** 于 **";
        desp += wide_to_utf8(std::wstring_view(time_buf));
        desp += "** 时进入关机程序";

        send_notify("计算机正在关机", desp);
#ifdef SN_DEBUG_TIMING
        debug_wait_if_enabled();
#endif
        return 0;
    } catch (...) {
#ifdef SN_DEBUG_TIMING
        debug_wait_if_enabled();
#endif
        return 1;
    }
}