cmake_minimum_required(VERSION 3.22)
project(squeezeagent CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(squeezeagent SHARED squeeze_agent.cc)
target_include_directories(squeezeagent PRIVATE include)

find_library(log-lib log)
target_link_libraries(squeezeagent ${log-lib})
