cmake_minimum_required(VERSION 3.15)
project(ShutdownNotice VERSION 1.0.0 LANGUAGES CXX)

# C++17 标准
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MSVC 多线程运行时 (/MT)，避免依赖 VC 运行时 DLL
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# ============================================================
# 共享编译定义
# ============================================================
set(COMMON_DEFS WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)

# MSVC: 强制源文件 UTF-8 编码，避免中文窄/宽字面量按系统代码页误解析
if(MSVC)
    add_compile_options($<$<COMPILE_LANGUAGE:CXX>:/utf-8>)
endif()

# Release 构建静默: 定义 NDEBUG 禁用所有控制台输出
add_compile_definitions($<$<CONFIG:Release>:NDEBUG>)

# ============================================================
# 共享静态库：事件日志查询 + 通知服务
# ============================================================
add_library(common STATIC
    src/common.cpp
)
target_include_directories(common PUBLIC include)
target_link_libraries(common PUBLIC wevtapi winhttp crypt32 bcrypt)
target_compile_definitions(common PUBLIC ${COMMON_DEFS})

# ============================================================
# dbg 共享静态库：同 common，但启用耗时统计
# ============================================================
add_library(common_dbg STATIC
    src/common.cpp
)
target_include_directories(common_dbg PUBLIC include)
target_link_libraries(common_dbg PUBLIC wevtapi winhttp crypt32 bcrypt)
target_compile_definitions(common_dbg PUBLIC ${COMMON_DEFS})
target_compile_definitions(common_dbg PRIVATE SN_DEBUG_TIMING)

# ============================================================
# Release 优化选项
# ============================================================
if(MSVC)
    # common: 正式版全优化
    target_compile_options(common PRIVATE
        $<$<CONFIG:Release>:/O2>
        $<$<CONFIG:Release>:/GL>
        $<$<CONFIG:Release>:/Gy>
        $<$<CONFIG:Release>:/Gw>
    )
    # common_dbg: 诊断版仅 /O2，不加 /GL 避免 _dbg 目标 LTCG 警告
    target_compile_options(common_dbg PRIVATE
        $<$<CONFIG:Release>:/O2>
        $<$<CONFIG:Release>:/Gy>
        $<$<CONFIG:Release>:/Gw>
    )
endif()

# ============================================================
# 事件通知程序 (ID41, ID1074, ID6005, ID6006, ID6008)
# ============================================================
set(EVENT_IDS 41 1074 6005 6006 6008)
foreach(EVENT_ID IN LISTS EVENT_IDS)
    add_executable(ID${EVENT_ID} src/ID${EVENT_ID}.cpp)
    target_link_libraries(ID${EVENT_ID} PRIVATE common)
    target_compile_definitions(ID${EVENT_ID} PRIVATE ${COMMON_DEFS})

    if(MSVC)
        target_compile_options(ID${EVENT_ID} PRIVATE
            $<$<CONFIG:Release>:/O2>
            $<$<CONFIG:Release>:/GL>
        )
        target_link_options(ID${EVENT_ID} PRIVATE
            $<$<CONFIG:Release>:/LTCG>
            $<$<CONFIG:Release>:/OPT:REF>
            $<$<CONFIG:Release>:/OPT:ICF>
        )
    endif()
endforeach()

# ============================================================
# 开关机通知程序 (poweroff / poweron)
# ============================================================
add_executable(poweroff src/poweroff.cpp)
target_link_libraries(poweroff PRIVATE common)
target_compile_definitions(poweroff PRIVATE ${COMMON_DEFS})

add_executable(poweron src/poweron.cpp)
target_link_libraries(poweron PRIVATE common)
target_compile_definitions(poweron PRIVATE ${COMMON_DEFS})

if(MSVC)
    foreach(exe IN ITEMS poweroff poweron)
        target_compile_options(${exe} PRIVATE
            $<$<CONFIG:Release>:/O2>
            $<$<CONFIG:Release>:/GL>
        )
        target_link_options(${exe} PRIVATE
            $<$<CONFIG:Release>:/LTCG>
            $<$<CONFIG:Release>:/OPT:REF>
            $<$<CONFIG:Release>:/OPT:ICF>
        )
    endforeach()
endif()

# ============================================================
# dbg 诊断版本 (带耗时统计，不参与 Release 安装)
# 链接 common_dbg 而非 common，使 SN_DEBUG_TIMING 在库层面生效
# ============================================================
foreach(EVENT_ID IN LISTS EVENT_IDS)
    add_executable(ID${EVENT_ID}_dbg src/ID${EVENT_ID}.cpp)
    target_link_libraries(ID${EVENT_ID}_dbg PRIVATE common_dbg)
    target_compile_definitions(ID${EVENT_ID}_dbg PRIVATE ${COMMON_DEFS} SN_DEBUG_TIMING)
endforeach()

add_executable(poweroff_dbg src/poweroff.cpp)
target_link_libraries(poweroff_dbg PRIVATE common_dbg)
target_compile_definitions(poweroff_dbg PRIVATE ${COMMON_DEFS} SN_DEBUG_TIMING)

add_executable(poweron_dbg src/poweron.cpp)
target_link_libraries(poweron_dbg PRIVATE common_dbg)
target_compile_definitions(poweron_dbg PRIVATE ${COMMON_DEFS} SN_DEBUG_TIMING)

# ============================================================
# 安装规则 (仅正式版本)
# ============================================================
install(TARGETS poweroff poweron ID41 ID1074 ID6005 ID6006 ID6008
        RUNTIME DESTINATION bin)
