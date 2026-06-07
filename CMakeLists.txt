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

# ============================================================
# 共享静态库：事件日志查询 + 通知服务
# ============================================================
add_library(common STATIC
    src/common.cpp
)
target_include_directories(common PUBLIC include)
target_link_libraries(common PUBLIC wevtapi winhttp crypt32)
target_compile_definitions(common PUBLIC ${COMMON_DEFS})

# ============================================================
# dbg 共享静态库：同 common，但启用耗时统计
# ============================================================
add_library(common_dbg STATIC
    src/common.cpp
)
target_include_directories(common_dbg PUBLIC include)
target_link_libraries(common_dbg PUBLIC wevtapi winhttp crypt32)
target_compile_definitions(common_dbg PUBLIC ${COMMON_DEFS})
target_compile_definitions(common_dbg PRIVATE SN_DEBUG_TIMING)

# ============================================================
# Release 优化选项
# ============================================================
if(MSVC)
    foreach(lib IN ITEMS common common_dbg)
        target_compile_options(${lib} PRIVATE
            $<$<CONFIG:Release>:/O2>
            $<$<CONFIG:Release>:/GL>
            $<$<CONFIG:Release>:/Gy>
            $<$<CONFIG:Release>:/Gw>
        )
    endforeach()
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
# 关机通知程序 (down)
# ============================================================
add_executable(down src/down.cpp)
target_link_libraries(down PRIVATE common)
target_compile_definitions(down PRIVATE ${COMMON_DEFS})

if(MSVC)
    target_compile_options(down PRIVATE
        $<$<CONFIG:Release>:/O2>
        $<$<CONFIG:Release>:/GL>
    )
    target_link_options(down PRIVATE
        $<$<CONFIG:Release>:/LTCG>
        $<$<CONFIG:Release>:/OPT:REF>
        $<$<CONFIG:Release>:/OPT:ICF>
    )
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

add_executable(down_dbg src/down.cpp)
target_link_libraries(down_dbg PRIVATE common_dbg)
target_compile_definitions(down_dbg PRIVATE ${COMMON_DEFS} SN_DEBUG_TIMING)

# ============================================================
# 安装规则 (仅正式版本)
# ============================================================
install(TARGETS down ID41 ID1074 ID6005 ID6006 ID6008
        RUNTIME DESTINATION bin)
