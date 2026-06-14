cmake_minimum_required(VERSION 3.18)
project(jacacapture C)

# zdtun (LGPL-3.0) — userspace TCP/IP stack. zdtun.c #includes socks5.c, so don't list it.
add_definitions(-DANDROID -DNO_DEBUG)

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/zdtun
)

add_library(jacacapture SHARED
    jaca_capture.c
    zdtun/zdtun.c
    zdtun/utils.c
)

find_library(log-lib log)
target_link_libraries(jacacapture ${log-lib})
