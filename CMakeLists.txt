cmake_minimum_required(VERSION 3.20)
project(cross_compile_demo CXX)

# ── 演示用的小目标 ──────────────────────────────────────────
add_executable(${PROJECT_NAME} src/main.cpp)

# 把 CMake 知道的"目标架构"写进代码，让程序运行时自报家门。
target_compile_definitions(${PROJECT_NAME} PRIVATE
    TARGET_PROCESSOR="${CMAKE_SYSTEM_PROCESSOR}"
)

install(TARGETS ${PROJECT_NAME}
  RUNTIME DESTINATION lib/${PROJECT_NAME}
)

enable_testing()
add_test(NAME machine_check COMMAND ${PROJECT_NAME})