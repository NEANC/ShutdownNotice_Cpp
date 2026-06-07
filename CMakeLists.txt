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
# 共享静态库：事件日志查询 + 通知服务
# ============================================================
add_library(common STATIC
    src/common.cpp
)
target_include_directories(common PUBLIC include)
target_link_libraries(common PUBLIC wevtapi winhttp crypt32)

# ============================================================
# 事件通知程序 (ID41, ID1074, ID6005, ID6006, ID6008)
# ============================================================
set(EVENT_IDS 41 1074 6005 6006 6008)
foreach(EVENT_ID IN LISTS EVENT_IDS)
    add_executable(ID${EVENT_ID} src/ID${EVENT_ID}.cpp)
    target_link_libraries(ID${EVENT_ID} PRIVATE common)
endforeach()

# ============================================================
# 关机通知程序 (down)
# ============================================================
add_executable(down src/down.cpp)
target_link_libraries(down PRIVATE common)

# ============================================================
# 安装规则
# ============================================================
install(TARGETS down ID41 ID1074 ID6005 ID6006 ID6008
        RUNTIME DESTINATION bin)