cmake_minimum_required(VERSION 3.22)
project(squeezeagent CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_library(log-lib log)
find_library(z-lib z)

# Vendored AOSP slicer (dex IR + instrumentation: provides ExitHook/EntryHook).
file(GLOB SLICER_SRC third_party/slicer/*.cc)
add_library(slicer STATIC ${SLICER_SRC})
target_include_directories(slicer PUBLIC third_party/slicer/export)
target_link_libraries(slicer ${z-lib})
target_compile_options(slicer PRIVATE -Wno-unused-parameter -Wno-deprecated-declarations)

add_library(squeezeagent SHARED squeeze_agent.cc squeeze_transform.cc)
target_include_directories(squeezeagent PRIVATE include third_party/slicer/export)
target_link_libraries(squeezeagent slicer ${log-lib} ${z-lib})

# Link with 16 KB page alignment.
#
# Android 15+ devices and the `sdk_gphone16k_*` emulators use 16 KB pages, and their linker
# hard-refuses a library aligned to the older 4 KB default:
#
#   "libsqueezeagent.so" program alignment (4096) cannot be smaller than system page size (16384)
#
# The agent then can't dlopen at all — the attach fails outright rather than degrading, so this
# is not optional. See docs/response-overrides.md ("Dead ends worth remembering").
target_link_options(squeezeagent PRIVATE "-Wl,-z,max-page-size=16384")
