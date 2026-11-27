# cross_compile_demo

CMake 交叉编译学习 demo：**一套 CMakeLists.txt，原生/x86 与交叉/aarch64 双产物**，没有 ARM 板时用 qemu 伪板运行验证。

工程里有三个可执行程序，对应三条学习主线：

- **`cross_compile_demo`**：纯 C++ 演示程序——自报编译架构 + 用 STL 验证交叉链路，入门交叉编译；
- **`cuda_demo`**：真正的 GPU 加速程序——向量相加 kernel，CPU/GPU 对比 + 校验，入门 CUDA；
- **`fast_check_chessboard`**：OpenCV 交叉编译产物——对一批图像做棋盘格快速检测（标定预检），把 **第三方库（OpenCV）接入交叉工具链** 这条线走通，入门"交叉编译 + 第三方依赖"。详见下文「fast_check_chessboard」一节。

> 需要：`cmake ≥ 3.20`、`g++-aarch64-linux-gnu`；CUDA 部分需要宿主 nvcc（CUDA 工具包）与**目标侧** CUDA 头文件/库（本工程在虚拟根目录 `/sysroot` 里，见下文）。OpenCV 部分需要**目标侧** aarch64 版 OpenCV（本工程在 `/opt/3rdparty/OpenCV`，见下文）。伪板运行需要 `qemu-user`——没装就装上：`sudo apt install qemu-user`。

## 快速开始

```bash
# 首次准备：交叉工具链（qemu-user 用于伪板运行，可选但推荐）
sudo apt install g++-aarch64-linux-gnu qemu-user

# 原生编译（x86_64）：纯 C++，不启用 CUDA，直接运行
./build.sh native

# 交叉编译（aarch64）：一次产出 cross_compile_demo + cuda_demo + fast_check_chessboard
./build.sh cross

# 伪板运行交叉产物（qemu-aarch64 仿真，无需 ARM 板）
./build.sh run

# 伪板运行棋盘格检测（OpenCV 产物），默认扫描 test_images 目录
./build.sh run fast_check_chessboard

# CTest：原生 + 交叉（qemu 仿真）各跑一遍
./build.sh test

# 清理所有 build-*/ 和 install-*/
./build.sh clean
```

注意两点：

- **伪板运行需要 qemu-user**：`sudo apt install qemu-user`。
- **GPU 程序在容器里跑不了 kernel**：容器无 GPU、qemu 也不仿真 GPU。`cuda_demo` 在本机只能验证到"编译—链接—产物架构"，真正的 GPU 计算要上 Orin 板（见「cuda_demo」一节）。

## 项目结构

```
.
├── CMakeLists.txt                          # 唯一的工程文件，业务代码零改动
│                                           #   CUDA 只在交叉构建里点亮（见下文）
├── build.sh                                # 一键脚本：native/cross/run/test/clean
│                                           #   并导出"虚拟根目录"环境变量（见下表）
├── run-on-qemu.sh                          # 伪板运行脚本（qemu-aarch64 -L …）
├── src/
│   ├── main.cpp                            # CPU 演示：自报架构 + STL 链路验证
│   ├── cuda_demo/                          # GPU 演示（floatx / vec_add / rgb2gray）
│   │   └── main.cu                         # GPU 演示：向量相加（五幕教学注释）
│   └── opencv_demo/
│       └── fast_check_chessboard/
│           ├── main.cpp                    # OpenCV 棋盘格快速检测（标定预检）
│           └── test_images/                # 测试图：left/ + right/ 各 18 张（36 张 11×8 棋盘）
├── toolchains/
│   └── aarch64-linux-gnu.toolchain.cmake   # 交叉工具链定义（逐行注释）
│
├── build-native/  install-native/          # x86_64 产物（.gitignore 已忽略）
└── build-cross/   install-cross/           # aarch64 两个产物（.gitignore 已忽略）
```

### build.sh 注入的环境变量：虚拟根目录设计

目标板子的文件系统布局，在构建容器里用一套虚拟目录复刻，toolchain 用 `$ENV{}` 读取：

| 环境变量 | 本容器值 | 意义 |
|---|---|---|
| `SYSROOT` | `/sysroot` | 虚拟的板子 `/`：完整 aarch64 rootfs，含 `/usr/local/cuda-12.2` 的 **aarch64** CUDA 头文件/库 |
| `THIRD_PARTY_LIBRARIES_PATH` | `/opt/3rdparty` | 板子上第三方库的落点（`find_package`/`find_library` 会到这些根里找） |
| `INSTALL_PATH` | `/opt/install` | 板子上自家产物的安装目录 |
| `SYSTEM_TAG` | `orin-8.6.2`（容器注入） | 目标板系统版本，toolchain 据此选 CUDA 版本分支 |

前三个由 build.sh 在 configure 前 `export`，最后一个由容器/构建环境注入。**绕开 build.sh 直接跑 cmake 时 `SYSROOT` 未导出，CUDA 段 configure 会挂**（见踩坑记录）。

## 核心原理（本 demo 想要讲清的三件事）

### 1. CMake 的"两阶段"
```
cmake -S . -B build-cross -DCMAKE_TOOLCHAIN_FILE=toolchains/….cmake   ← configure
cmake --build build-cross                                            ← build
```
- **configure**：读 CMakeLists.txt（+ toolchain），生成 Makefile 与 `CMakeCache.txt`
- **build**：调用 make 真正编译链接。CMake 本身不编译，只生成构建系统
- toolchain 文件在 `project()` **之前**加载。

### 2. 交叉产物没有板也能跑
```
qemu-aarch64 -L /usr/aarch64-linux-gnu ./install-cross/…/cross_compile_demo
```
- 动态链接的产物需要 **目标架构的动态加载器** `ld-linux-aarch64.so.1`，宿主 x86 没有
- `-L <目录>` 让 qemu 去指定目录找（等价于板子的根文件系统）；本工程的 `run-on-qemu.sh` 默认用 `/usr/aarch64-linux-gnu`，想换伪板根目录就 `export QEMU_LD_PREFIX=<目录>`（如 `QEMU_LD_PREFIX=/sysroot` 即用虚拟板根）
- 配合 `CMAKE_CROSSCOMPILING_EMULATOR`，CTest 自动挂 emulator，测试不用上板

### 3. 查找策略三兄弟（toolchain.cmake 里最容易问倒人的部分）
| 变量 | 值 | 含义 |
|---|---|---|
| `CMAKE_FIND_ROOT_PATH_MODE_PROGRAM` | `NEVER` | `find_program` 只在 build 机找（工具要在 build 机上执行） |
| `CMAKE_FIND_ROOT_PATH_MODE_LIBRARY` | `ONLY` | `find_library` 只在目标侧找，绝不碰宿主 x86 库 |
| `CMAKE_FIND_ROOT_PATH_MODE_INCLUDE` | `ONLY` | `find_path`/`find_file` 只在目标侧找 |
| `CMAKE_FIND_ROOT_PATH` | `$ENV{SYSROOT} / $ENV{THIRD_PARTY_LIBRARIES_PATH} / $ENV{INSTALL_PATH}` | 目标侧允许搜索的"根"：虚拟的板根 + 第三方库目录 + 安装目录 |

## cuda_demo：真正的 GPU 加速程序

**它是什么**：两个 float 数组逐元素相加。CUDA 版的"Hello World"，但麻雀虽小五脏俱全——内核函数、`<<<网格, 块>>>` 启动、线程编号、显存搬运、错误检查 `CUDA_CHECK`、CUDA 事件计时、CPU/GPU 结果校验与加速比，全在 [src/cuda_demo/main.cu](src/cuda_demo/main.cu) 一份文件里按"五幕"逐步注释。没有 GPU 的环境会自动降级：`cudaGetDeviceCount` 返回 0 时只跑 CPU 参考分支并打印说明。

### 编译链路："x86 的 nvcc 怎么编出 Orin 的 GPU 程序"

`nvcc` 只是**编译工具**——它跑在 x86 宿主上，产出的是"aarch64 可执行文件 + 内嵌 sm_87 的 GPU 机器码"。关键参数（从实际 `flags.make` 里抓的真实命令）：

```bash
/usr/local/cuda-12.2/bin/nvcc -ccbin aarch64-linux-gnu-g++ -Xcompiler -fPIC \
     -I/sysroot/usr/local/cuda-12.2/include -L/sysroot/usr/local/cuda-12.2/lib64 \
     --generate-code=arch=compute_87,code=[compute_87,sm_87] -std=c++17 -O3 main.cu
```

| 参数 | 作用 |
|---|---|
| `-ccbin aarch64-linux-gnu-g++` | .cu 的 **host 段**（CPU 侧代码）交给 aarch64 的 g++，否则默认抓宿主 x86 g++，产物直接不能上板 |
| `-I/-L /sysroot/usr/local/cuda-12.2/...` | 头文件与链接库取自**虚拟板子的目录**（那里面是 aarch64 的 CUDA 12.2） |
| `--generate-code=arch=compute_87,code=[compute_87,sm_87]` | 为 Orin 的 GPU（Ampere GA10B，计算能力 8.7）生成 SASS；来自 CMakeLists 的 `CUDA_ARCHITECTURES 87` |

这些参数在工程里的落点：toolchain 文件按 `SYSTEM_TAG` 的 if/elseif 分支选定 `CMAKE_CUDA_COMPILER` 和 `CMAKE_CUDA_FLAGS`（`orin-8.6.2` → CUDA 12.2）；CMakeLists 里 `set_target_properties(cuda_demo PROPERTIES CUDA_ARCHITECTURES 87)` 定算力。同样一条 `./build.sh cross`，会附带编译并链接出 `cuda_demo`。

### 为什么 native 构建没有 cuda_demo

CUDA 只在 `if(CMAKE_CROSSCOMPILING)` 里 `enable_language(CUDA)` 启用，**native（x86、无 GPU）保持纯 C++、零 nvcc 依赖**（宿主上 nvcc 本就不在 PATH）。GPU 产物本来就是给板子造的——语义和实现一致。

### 怎么真跑起来（上 Orin 板）

`cuda_demo` 默认**静态链接** cudart（`readelf -d` 里没有 libcudart 依赖），拷贝单文件即可，运行时只依赖板上的系统库 + 驱动库 `libcuda.so.1`（板上自带）：

```bash
scp install-cross/lib/cross_compile_demo/cuda_demo 用户@<Orin板IP>:~/
ssh 用户@<Orin板IP> './cuda_demo'
```

在板上会看到五幕完整上演：GPU 探测（名字/算力 8.7）→ CPU 参考计时 → 网格 65536 块 × 256 线程 = 1677 万线程同时干活 → 校验通过 → 加速比。

## fast_check_chessboard：把 OpenCV 接进交叉工具链

**它是什么**：[src/opencv_demo/fast_check_chessboard/main.cpp](src/opencv_demo/fast_check_chessboard/main.cpp) 里实现了一个棋盘格**快速预检**程序：纯 CPU 逐张读图，用 OpenCV 的 `cv::findChessboardCorners(..., CALIB_CB_FAST_CHECK | CALIB_CB_ADAPTIVE_THRESH)` 判断"图上有没有棋盘格"，遍历目录下全部图片、逐张打印结果并汇总。**只问"有/没有"、不抠角点坐标**——正是标定流水线里"引导摆板/抽检废图"的那道快闸门。这个 demo 的意义：**本工程第一次把第三方库（OpenCV）编排进交叉构建**，打通"依赖在 `/opt/3rdparty`、头文件/库都是 aarch64"这条线。棋盘定位为**本工程自己的 `main.cpp` 里那个 `FastCheckChessboardCorners()` 函数**（`cv::cvtColor` 转灰 → `cv::findChessboardCorners` 带两个 flag）。

### 依赖清单（交叉态下逐个能对上才跑得起来）

**编译期（build 机）**

| 依赖 | 位置 | 说明 |
|---|---|---|
| aarch64 版 OpenCV 4.9.0 | `/opt/3rdparty/OpenCV` | `find_package(OpenCV REQUIRED)` 找到（它的 CMake 配置在 `lib/cmake/opencv4/OpenCVConfig.cmake`）|
| `libopencv_{calib3d,imgproc,imgcodecs,core}.so` | 同上 `lib/` | `target_link_libraries(... ${OpenCV_LIBS})` 自动带上，且按依赖扁平化会间接引入 `features2d`、`flann` |
| OpenCV 头文件 | `/opt/3rdparty/OpenCV/include/opencv4` | `OpenCV_INCLUDE_DIRS` 已含括，无需手写 `-I` |
| C++ 标准 | — | main.cpp 用了 `std::filesystem`，CMake 里 `target_compile_features(... cxx_std_17)` 锁定 |

**运行期（qemu 伪板 / 真板）**

| 依赖 | 来源 | 谁注入 |
|---|---|---|
| OpenCV 动态库 `.so.409` | `/opt/3rdparty/OpenCV/lib`（不在 qemu `-L` 默认覆盖的 rootfs 里）| build.sh 里 `LD_LIBRARY_PATH=$THIRD_PARTY_LIBRARIES_PATH/OpenCV/lib` |
| libjpeg / libpng / libwebp / zlib 等系统库 | 只在**完整** rootfs `/sysroot` 里；qemu 默认 `-L /usr/aarch64-linux-gnu` 缺它们 | build.sh 里 `QEMU_LD_PREFIX=/sysroot`（run-on-qemu.sh 支持用该变量换根目录）|
| qemu-user | 宿主 | `sudo apt install qemu-user` |

> **为什么 `-L` 不够还要 `LD_LIBRARY_PATH`？** qemu 的 `-L <rootfs>` 只负责"板子的系统库"，而 `/opt/3rdparty/OpenCV/lib` 是构建容器的虚拟三方库落点、不在 rootfs 内，得用 guest 动态加载器认识的 `LD_LIBRARY_PATH` 补上。

### 怎么跑

```bash
./build.sh cross                         # 编译 + 安装，产物出现在 install-cross/lib/cross_compile_demo/
./build.sh run fast_check_chessboard                        # 默认扫 test_images（36 张 11×8 棋盘图）
./build.sh run fast_check_chessboard /path/to/my_images 11 8   # 自定义目录 + 棋盘内角数
```

输出形如 `[有棋盘格  ] <文件>`，结尾汇总 `共 N 张，检测到棋盘格 M 张`。实测 36/36 全检出。

**参数**：`<图像目录> [棋盘内角 宽 高]`，默认目录 `test_images`、内角 `11×8`（图在 `src/opencv_demo/fast_check_chessboard/test_images/left|right/`，各 18 张）。

**动手改的落点**：CMakeLists 交叉分支里 `find_package(OpenCV)` + `add_executable(fast_check_chessboard ...)`；build.sh 的 `run` 分支新增 `fast_check_chessboard` 选择，顺带处理 `LD_LIBRARY_PATH` 与 `QEMU_LD_PREFIX`。

### 一个诚实的提醒

`CALIB_CB_FAST_CHECK` 是**快速粗判，可能漏检**（真棋盘被当没有）。标定"正式采集"要的是不漏——那一步用 `CALIB_CB_FILTER_QUADS`（带四边形精校验，更慢但更可靠）。本 demo 定位是"预检/演示"，取舍注明在这里。

## 踩坑记录（都是真跑出来的）

| 现象 | 根因 | 解法 |
|---|---|---|
| x86 上 `Exec format error` | x86 内核不认 aarch64 ELF | 用 `qemu-aarch64` 跑，属正常现象 |
| qemu 报 `Could not open /lib/ld-linux-aarch64.so.1` | 宿主上缺目标架构动态加载器 | `-L` 指定板子根目录（本工程 `run-on-qemu.sh` 已处理） |
| 链接报 `skipping incompatible ... libcudart.so ... cannot find -lcudart` | `-I/-L` 指向了宿主 **x86** 的 CUDA 目录 | `-I/-L` 一律走 `${CMAKE_SYSROOT}/...`，且必须 `export SYSROOT=/sysroot` |
| CUDA configure 报 `Check for working CUDA compiler ... - broken` | 绕开 build.sh 直接 cmake，`SYSROOT` 未导出，CUDA 试编退回 x86 | 用 build.sh，或手动 export 三个环境变量再 configure |
| `nvcc: not found` | nvcc 不在 PATH | native 不需要 nvcc；cross 由 toolchain 显式指定绝对路径 |
| 板上跑报 `invalid device function` | `CUDA_ARCHITECTURES` 没显式设置，CMake 兜底猜了一个（如 52） | CMakeLists 里给目标设 `CUDA_ARCHITECTURES 87`（cmake 缓存里的 52 就是兜底值） |
| `cmake --install 报 Not a file: …/cmake_install.cmake` | `--install` 参数应为**构建目录**；目的地归 `CMAKE_INSTALL_PREFIX` 管 | `-DCMAKE_INSTALL_PREFIX=… 配置` + `cmake --install <build 目录>` |
| 重配置提示 `Manually-specified variables were not used: CMAKE_TOOLCHAIN_FILE` | 首次已写进缓存，属正常提醒 | 忽略即可 |
| `find_package(OpenCV)` 找不到 | 宿主没有 x86 OpenCV 头/库；而交叉版在 `/opt/3rdparty`，普通搜索不到 | 确保 OpenCV 的 `OpenCVConfig.cmake` 能被找到（本工程在 `/opt/3rdparty/OpenCV/lib/cmake/opencv4`） |
| 交叉链接报 `undefined reference to deflateInit_/png_*/jpeg_*` | OpenCV 动态库依赖 zlib/jpeg/png/webp，这些头库不在默认搜索路径 | 用 `--sysroot=/sysroot`（完整 rootfs 里有这些 aarch64 系统库），并显式 `-I/-L` 到 `/opt/3rdparty` |
| 链接 `-lopencv_calib3d` 报 `undefined reference to cv::Feature2D/…flann…` | `calib3d` 隐式依赖 `features2d`、`flann` | 手动链接时把 `-lopencv_features2d -lopencv_flann` 也加上（CMake 里 `${OpenCV_LIBS}` 会扁平化带上） |
| qemu 运行报 `libopencv_*.so.409: cannot open shared object file` | OpenCV 库在 `/opt/3rdparty`，超出了 qemu `-L <rootfs>` 的覆盖 | qemu 加 `-E LD_LIBRARY_PATH=/opt/3rdparty/OpenCV/lib`（build.sh 封装好了） |
| qemu 运行报 `libjpeg.so.8 / libpng16 … : not found` | 这些系统库只在完整 rootfs `/sysroot`，qemu 默认 `-L /usr/aarch64-linux-gnu` 缺 | `export QEMU_LD_PREFIX=/sysroot` 让 qemu 用虚拟板根（build.sh 封装好了） |

## 常问速查

- **原生和交叉能共用 build 目录吗？** 不能。`CMakeCache.txt` 会污染，必须分目录（脚本已强制）
- **产物架构怎么一眼确认？** `file <二进制>` → `ELF 64-bit LSB pie executable, ARM aarch64`
- **改 toolchain 后没生效？** 删掉对应 build 目录重 configure（缓存里旧编译器值还在）
- **CTest 里怎么知道在跑原生还是交叉？** configure 时若加载了 toolchain，`CMAKE_CROSSCOMPILING=TRUE`
- **为什么 `./build.sh native` 之后没有 cuda_demo？** CUDA 只在交叉构建启用；native 是纯 C++（x86、无 GPU，也不需要 nvcc）
- **cuda_demo 在本容器能跑吗？** 只能编/链/验架构；真跑 kernel 需上 Orin 板（无 GPU，qemu 也不仿 GPU）
- **换板子/显卡怎么改？** 算力改 CMakeLists 的 `CUDA_ARCHITECTURES`；换 CUDA 版本改 toolchain 的 `SYSTEM_TAG` 分支，并保证虚拟 sysroot 里有对应的 `usr/local/cuda-<版本>`

## 验证环境

| 项 | 值 |
|---|---|
| 宿主 | x86_64, Ubuntu 22.04.4 LTS (jammy) |
| CMake | 3.28.3，「configure + build」两阶段标准流程 |
| cross 工具链 | `aarch64-linux-gnu-g++` 11.4.0（glibc 目标为 aarch64） |
| CUDA 工具包 | 宿主 x86 12.2.140（只作编译工具, 路径：/usr/local/cuda-12.2/bin/nvcc）；目标侧 aarch64 12.2 在虚拟板 `/sysroot/usr/local/cuda-12.2` |
| OpenCV | 4.9.0 **aarch64 交叉版**，位于 `/opt/3rdparty/OpenCV`（头文件 `include/opencv4`、动态库 `lib/*.so.409`；`calib3d/imgproc/imgcodecs/core` 及间接 `features2d`/`flann`） |
| `SYSTEM_TAG` | `orin-8.6.2`（toolchain 走 CUDA 12.2 分支） |
| GPU | 容器内无（无 `/dev/nvidia*`、无 `nvidia-smi`） |
| 仿真 | qemu-user（`sudo apt install qemu-user`）；`run-on-qemu.sh` 可用 `QEMU_LD_PREFIX=/sysroot` 指定伪板根目录；OpenCV 库用 `LD_LIBRARY_PATH=/opt/3rdparty/OpenCV/lib` 补 |
| 验证结果 | 原生/cross CTest 各 1/1 Passed；cross 一次产出 cross_compile_demo + cuda_demo + fast_check_chessboard；`file` 确认 aarch64 架构、`cuda_demo` 内嵌 sm_87；`fast_check_chessboard` 在 qemu 下对 36 张测试图 36/36 检出棋盘格 |

## 交叉编译笔记学习
https://docs.qq.com/doc/DQ2ZvQm9NVnJHS01W