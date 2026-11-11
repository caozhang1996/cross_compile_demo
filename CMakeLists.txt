cmake_minimum_required(VERSION 3.20)
# 语言声明只给 CXX：nvcc 不在 PATH 上，native 构建不该背 CUDA 依赖。
# CUDA 在下方 if(CMAKE_CROSSCOMPILING) 里按需点亮——cross 的 toolchain
# 文件已经把 CMAKE_CUDA_COMPILER 指好，那里才是编 .cu 的现场。
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

# ── CUDA 实验目标：真正的 GPU 程序（src/cuda_demo/main.cu）───
# 只在交叉构建里使用 CUDA：GPU 产物是给板子的；native(x86、无 GPU) 保持
# 纯 C++，不引入 nvcc 依赖。
if(CMAKE_CROSSCOMPILING)
  enable_language(CUDA)   # toolchain 已指定编译器；这里真正注册这门语言

  add_executable(cuda_demo src/cuda_demo/main.cu)

  # CUDA_ARCHITECTURES 决定 nvcc 的 -gencode = 编出哪种 GPU 能跑的机器码：
  #   "87" = sm_87 = Jetson Orin 的 GPU（Ampere GA10B，计算能力 8.7）。
  # 换板子/显卡时改成对应算力，如 "75"(Xavier) / "86"(RTX 30) / "90"(RTX 50)。
  set_target_properties(cuda_demo PROPERTIES CUDA_ARCHITECTURES 87)

  install(TARGETS cuda_demo
    RUNTIME DESTINATION lib/${PROJECT_NAME}
  )
endif()