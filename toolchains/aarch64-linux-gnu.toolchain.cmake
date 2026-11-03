# toolchains/aarch64-linux-gnu.toolchain.cmake
# 交叉编译工具链定义文件：只描述"目标机器长什么样"，不含业务逻辑。
#
# ★ 加载时机很关键：在 project() 之前、CMake 探测编译器之前加载。
#   所以在这里改 CMAKE_CXX_COMPILER 才有效——等 project() 跑完，编译器已定死，再改就晚了。

set(CMAKE_SYSTEM_NAME Linux)            # 目标系统；显式写上，让 CMAKE_CROSSCOMPILING=TRUE
set(CMAKE_SYSTEM_PROCESSOR aarch64)     # 目标 CPU 架构
set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)

# ── sysroot 两种处境，按实际情况二选一 ─────────────────────
# A) 有独立 rootfs（板子根文件系统 / Yocto SDK 解压目录）时：
#       set(CMAKE_SYSROOT /opt/sysroot)
#   编译器一切查找（include、link、运行时）都被锁进这个目录。
#
# B) Ubuntu 自带 cross 包（本演示用这套）：头文件/库分布在 multiarch
#   目录里。用 FIND_ROOT_PATH 把它们圈起来，让 find_library / find_package
#   只在这个圈内找系统库，绝不碰到宿主机 x86 库。
set(CMAKE_FIND_ROOT_PATH /usr/aarch64-linux-gnu)

# ── 三条查找策略：不同类别的名字，在不同机器上找 ────────────
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)    # find_program：只在 build 机找
                                                #  （程序会在 build 机上被拉起来执行）
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)     # find_library：只在目标侧找
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)     # find_path / find_file：只在目标侧找

# ── build 机也能启动 aarch64 可执行文件（qemu-user）──────────
# 这样 CTest 不用上板就能跑。首次 configure 后才生效，缓存里看不到别慌。
#
# -L <目录> = 告诉 qemu 目标架构的动态加载器/动态库去哪里找
#   （等价于上板时内核加载 /lib/ld-linux-aarch64.so.1 的动作）。
#   用真实 rootfs 时这里填板的 sysroot：qemu-aarch64 -L /opt/sysroot
set(CMAKE_CROSSCOMPILING_EMULATOR qemu-aarch64 -L /usr/aarch64-linux-gnu)