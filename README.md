# cross_compile_demo

CMake 交叉编译学习 demo：**一套 CMakeLists.txt，原生/x86 与交叉/aarch64 双产物**，没有 ARM 板时用 qemu 伪板运行验证。

> 需要：`cmake ≥ 3.20`、`g++-aarch64-linux-gnu`、`qemu-user`。

## 快速开始

```bash
# 首次准备：安装交叉工具链 + qemu 用户态仿真
sudo apt install g++-aarch64-linux-gnu qemu-user

# 原生编译（x86_64）并运行
./build.sh native

# 交叉编译（aarch64）→ install-cross/，file 验证 ELF 架构
./build.sh cross

# 伪板运行交叉产物（qemu-aarch64 仿真，无需 ARM 板）
./build.sh run

# CTest：原生 + 交叉（qemu 仿真）各跑一遍
./build.sh test

# 清理所有 build-*/ 和 install-*/
./build.sh clean
```

## 项目结构

```
.
├── CMakeLists.txt                          # 唯一的工程文件，业务代码零改动
├── build.sh                                # 一键脚本：native/cross/run/test/clean
├── run-on-qemu.sh                          # 伪板运行脚本（qemu-aarch64 -L …）
├── src/
│   └── main.cpp                            # 演示程序：自报编译架构 + 用 STL 验证链路
├── toolchains/
│   └── aarch64-linux-gnu.toolchain.cmake   # 交叉工具链定义（逐行注释）
│
├── build-native/  install-native/          # x86_64 产物（.gitignore 已忽略）
└── build-cross/   install-cross/           # aarch64 产物（.gitignore 已忽略）
```

## 核心原理（本 demo 想要讲清的三件事）

### 1. CMake 的"两阶段"
```
cmake -S . -B build-cross -DCMAKE_TOOLCHAIN_FILE=toolchains/….cmake   ← configure
cmake --build build-cross                                            ← build
```
- **configure**：读 CMakeLists.txt（+ toolchain），生成 Makefile 与 `CMakeCache.txt`
- **build**：调用 make 真正编译链接。CMake 本身不编译，只生成构建系统
- toolchain 文件在 `project()` **之前**加载，所以改编译器才有效——工程代码一行不用动

### 2. 交叉产物没有板也能跑
```
qemu-aarch64 -L /usr/aarch64-linux-gnu ./install-cross/…/cross_compile_demo
```
- 动态链接的产物需要 **目标架构的动态加载器** `ld-linux-aarch64.so.1`，宿主 x86 没有
- `-L <目录>` 让 qemu 去指定目录找（等价于板子的根文件系统）；真实板子场景填 `/opt/sysroot`
- 配合 `CMAKE_CROSSCOMPILING_EMULATOR`，CTest 自动挂 emulator，测试不用上板

### 3. 查找策略三兄弟（toolchain.cmake 里最容易问倒人的部分）
| 变量 | 值 | 含义 |
|---|---|---|
| `CMAKE_FIND_ROOT_PATH_MODE_PROGRAM` | `NEVER` | `find_program` 只在 build 机找（工具要在 build 机上执行） |
| `CMAKE_FIND_ROOT_PATH_MODE_LIBRARY` | `ONLY` | `find_library` 只在目标侧找，绝不碰宿主 x86 库 |
| `CMAKE_FIND_ROOT_PATH_MODE_INCLUDE` | `ONLY` | `find_path`/`find_file` 只在目标侧找 |
| `CMAKE_FIND_ROOT_PATH` | `/usr/aarch64-linux-gnu` | 目标侧"根"：Ubuntu cross 包的 multiarch 目录 |

## 踩坑记录（都是真跑出来的）

| 现象 | 根因 | 解法 |
|---|---|---|
| `Exec format error` | x86 内核不认 aarch64 ELF | 用 `qemu-aarch64` 跑，属正常现象 |
| qemu 报 `Could not open /lib/ld-linux-aarch64.so.1` | 宿主上缺目标架构动态加载器 | `-L /usr/aarch64-linux-gnu` |
| `cmake --install 报 Not a file: …/install-native/cmake_install.cmake` | `--install` 参数应为**构建目录**；目的地归 `CMAKE_INSTALL_PREFIX` 管 | `cmake -DCMAKE_INSTALL_PREFIX=… 配置` + `cmake --install <build 目录>` |
| 重配置提示 `Manually-specified variables were not used: CMAKE_TOOLCHAIN_FILE` | 首次已写进缓存，属正常提醒 | 忽略即可 |


## 常问速查

- **原生和交叉能共用 build 目录吗？** 不能。`CMakeCache.txt` 会污染，必须分目录（脚本已强制）
- **产物架构怎么一眼确认？** `file <二进制>` → `ELF 64-bit LSB pie executable, ARM aarch64`
- **改 toolchain 后没生效？** 删掉对应 build 目录重 configure（缓存里旧编译器值还在）
- **CTest 里怎么知道在跑原生还是交叉？** configure 时若加载了 toolchain，`CMAKE_CROSSCOMPILING=TRUE`

## 验证环境

| 项 | 值 |
|---|---|
| 宿主 | x86_64, Ubuntu 22.04 (jammy) |
| CMake | 3.28.3，「configure + build」两阶段标准流程 |
| cross 工具链 | `aarch64-linux-gnu-g++` 11.2/11.4（glibc 目标为 aarch64） |
| 仿真 | qemu-user 6.2，`-L /usr/aarch64-linux-gnu` |
| 验证结果 | 原生/cross CTest 各 1/1 Passed；产物经 `file` 确认架构 |