# toolchains/aarch64-linux-gnu.toolchain.cmake
# 交叉编译工具链定义文件：只描述"目标机器长什么样"，不含业务逻辑。
#
# ★ 加载时机很关键：在 project() 之前、CMake 探测编译器之前加载。
#   所以在这里改 CMAKE_CXX_COMPILER 才有效——等 project() 跑完，编译器已定死，再改就晚了。

set(CMAKE_SYSTEM_NAME Linux)            # 目标系统；显式写上，让 CMAKE_CROSSCOMPILING=TRUE
set(CMAKE_SYSTEM_PROCESSOR aarch64)     # 目标 CPU 架构
set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)


# ── 虚拟根目录：把容器"伪装"成目标板子 ─────────────────────────
# 目标板子的文件系统布局，在构建容器里用一套虚拟目录复刻，
# 由 build.sh 在 cmake configure 前 export 三个环境变量注入：
#
#   $SYSROOT                    虚拟的 "/"：板子的根文件系统。
#                               编译器收到 --sysroot=<该目录> 后，默认头文件、
#                               系统库的查找全被锁进这里——等于把板子上
#                               (aarch64) 的原生查找范围搬到了构建机上。
#   $THIRD_PARTY_LIBRARIES_PATH 虚拟的 "/opt/3rdparty"：板子上第三方库的
#                               落点，find_package / find_library 会到这找。
#   $INSTALL_PATH               虚拟的 "/opt/install"：自家产物的安装目录。
# 环境变量取不到时展开为空、等于不限制，此时下方 -I/-L 会退回构建机的
# x86 目录——所以 build.sh 里这三个 export 是交叉编译成立的前提。
set(CMAKE_SYSROOT $ENV{SYSROOT})

# find_package / find_library / find_path 允许搜索的"根"，配合下方
# MODE_LIBRARY / MODE_INCLUDE = ONLY：CMake 一切搜索都被圈进这三个根里，
# 绝不摸到宿主机（/usr 等）的 x86 系统库和头文件。
# （CMake 默认会把 FIND_ROOT_PATH 初始化成 SYSROOT；这里显式给了三个，
#   三个根同时生效。）
set(CMAKE_FIND_ROOT_PATH
$ENV{SYSROOT}
$ENV{THIRD_PARTY_LIBRARIES_PATH}
$ENV{INSTALL_PATH}
)

# configure 自检：一眼看出三个环境变量是否取到、取成了什么。
# 排查问题第一步就看这里——十有八九是变量没 export、成了空字符串。
message("CMAKE_SYSROOT: ${CMAKE_SYSROOT}")
message("CMAKE_FIND_ROOT_PATH: ${CMAKE_FIND_ROOT_PATH}")

# ── 三条查找策略：不同类别的名字，在不同机器上找 ────────────
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)    # find_program：只在 build 机找
                                                #  （程序会在 build 机上被拉起来执行）
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)     # find_library：只在目标侧找
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)     # find_path / find_file：只在目标侧找

# ── CUDA：按 SYSTEM_TAG 选对应的 nvcc 与参数 ─────────────────
# $SYSTEM_TAG 由容器/构建环境注入，标识目标板子的系统版本；各档只是
# CUDA 版本号不同，参数结构完全一样：
#
# CMAKE_CUDA_COMPILER —— CUDA 语言用的 nvcc，写绝对路径是为了锁死：
#   交叉编译时 PATH 上可能混着宿主(x86) 的 nvcc，让它抢跑产物就错了。
#   注意它是 cache 变量：改版本必须清 build 缓存、重新 configure。
#
# CMAKE_CUDA_FLAGS 逐段：
#   -ccbin ${CMAKE_CXX_COMPILER}
#       .cu 会拆成两段编译：device 段(GPU 代码)由 nvcc 自己编，host 段
#       (CPU 侧代码)转手给这里指定的编译器。默认它会去 PATH 抓宿主 g++，
#       产物直接变 x86——必须指给 aarch64-linux-gnu-g++。
#   -Xcompiler -fPIC
#       -Xcompiler 把后面的参数原样透传给 host 编译器；-fPIC=位置无关代码，
#       共享库 / TensorRT 插件必需。
#   -I${CMAKE_SYSROOT}/cuda/include  -L${CMAKE_SYSROOT}/cuda/lib64
#       头文件与链接库走"板子的路径"：${CMAKE_SYSROOT} 已从 $SYSROOT 取到
#       /sysroot，于是落到 /sysroot/usr/local/cuda-12.x 的 aarch64 货物上。
#       （链接发生在构建机，但 -L 结算的正是这同一份 aarch64 库——
#         运行时板子上加载的还是它，编译/运行两条线统一在虚拟根目录下。）
if($ENV{SYSTEM_TAG} STREQUAL "orin-8.5.2")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-11.4/bin/nvcc")
  set(CMAKE_CUDA_FLAGS
      "-ccbin ${CMAKE_CXX_COMPILER} -Xcompiler -fPIC -I${CMAKE_SYSROOT}/usr/local/cuda-11.4/include -L${CMAKE_SYSROOT}/usr/local/cuda-11.4/lib64"
  )
elseif($ENV{SYSTEM_TAG} STREQUAL "orin-8.6.2")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-12.2/bin/nvcc")
  set(CMAKE_CUDA_FLAGS
      "-ccbin ${CMAKE_CXX_COMPILER} -Xcompiler -fPIC -I${CMAKE_SYSROOT}/usr/local/cuda-12.2/include -L${CMAKE_SYSROOT}/usr/local/cuda-12.2/lib64"
  )
elseif($ENV{SYSTEM_TAG} STREQUAL "orin-10.3.0")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-12.6/bin/nvcc")
  set(CMAKE_CUDA_FLAGS
      "-ccbin ${CMAKE_CXX_COMPILER} -Xcompiler -fPIC -I${CMAKE_SYSROOT}/usr/local/cuda-12.6/include -L${CMAKE_SYSROOT}/usr/local/cuda-12.6/lib64"
  )
elseif($ENV{SYSTEM_TAG} STREQUAL "orin-r6.2")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-12.6/bin/nvcc")
  set(CMAKE_CUDA_FLAGS
      "-ccbin ${CMAKE_CXX_COMPILER} -Xcompiler -fPIC -I${CMAKE_SYSROOT}/usr/local/cuda-12.6/include -L${CMAKE_SYSROOT}/usr/local/cuda-12.6/lib64"
  )
elseif($ENV{SYSTEM_TAG} STREQUAL "jp-7.0")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-13.0/bin/nvcc")
  set(CMAKE_CUDA_FLAGS
      "-ccbin ${CMAKE_CXX_COMPILER} -Xcompiler -fPIC -I${CMAKE_SYSROOT}/usr/local/cuda-13.0/include -L${CMAKE_SYSROOT}/usr/local/cuda-13.0/lib64"
  )
elseif($ENV{SYSTEM_TAG} STREQUAL "driveos-thoru")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-12.8/bin/nvcc")
  set(CMAKE_CUDA_FLAGS
      "-ccbin ${CMAKE_CXX_COMPILER} -Xcompiler -fPIC -I${CMAKE_SYSROOT}/usr/local/cuda-12.8/include -L${CMAKE_SYSROOT}/usr/local/cuda-12.8/lib64"
  )
elseif($ENV{SYSTEM_TAG} STREQUAL "jetson-jp7.2")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-13.2/bin/nvcc")
  set(CMAKE_CUDA_FLAGS
      "-ccbin ${CMAKE_CXX_COMPILER} -Xcompiler -fPIC -I${CMAKE_SYSROOT}/usr/local/cuda-13.2/include -L${CMAKE_SYSROOT}/usr/local/cuda-13.2/lib64"
  )
endif()

# ── build 机也能启动 aarch64 可执行文件（qemu-user）──────────
# 这样 CTest 不用上板就能跑。首次 configure 后才生效，缓存里看不到别慌。
#
# -L <目录> = 告诉 qemu 目标架构的动态加载器/动态库去哪里找
#   （等价于上板时内核加载 /lib/ld-linux-aarch64.so.1 的动作）。
# 配套注意：现在系统库统一从 CMAKE_SYSROOT(/sysroot) 来，下面/usr/aarch64-
# linux-gnu 是跨包多架构目录；若两者库版本有出入，把 -L 改成
# ${CMAKE_SYSROOT} 即与链接端严格同源。
set(CMAKE_CROSSCOMPILING_EMULATOR qemu-aarch64 -L /usr/aarch64-linux-gnu)