cmake_minimum_required(VERSION 3.21)
project(gpu_memory_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(JNI REQUIRED)

add_library(gpu_memory_native SHARED
    gpu_memory_native.cpp
)

target_compile_definitions(gpu_memory_native PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

target_include_directories(gpu_memory_native PRIVATE
    ${JNI_INCLUDE_DIRS}
)

target_link_libraries(gpu_memory_native PRIVATE
    dxgi
    ole32
)

set_target_properties(gpu_memory_native PROPERTIES
    PREFIX ""
)