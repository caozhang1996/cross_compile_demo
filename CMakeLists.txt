cmake_minimum_required(VERSION 3.20)
project(cross_compile_demo CXX)

# ── 演示用的小目标 ──────────────────────────────────────────
add_executable(hello_cross src/main.cpp)

# 把 CMake 知道的"目标架构"写进代码，让程序运行时自报家门。
target_compile_definitions(hello_cross PRIVATE
    TARGET_PROCESSOR="${CMAKE_SYSTEM_PROCESSOR}"
)

enable_testing()
add_test(NAME machine_check COMMAND hello_cross)