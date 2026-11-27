#!/usr/bin/bash
# 交叉编译演示工程 —— 一键构建/运行脚本
#
# 用法：
#   ./build.sh native   # 原生编译（x86_64）并安装到 install-native/，运行
#   ./build.sh cross    # 交叉编译（aarch64），产物安装到 install-cross/
#   ./build.sh run                # 伪板运行 cross 产物（qemu-aarch64），默认 cross_compile_demo
#   ./build.sh run cuda_demo      # 伪板运行 GPU demo（cuda_demo，CPU 降级分支）
#   ./build.sh run fast_check_chessboard [图像目录]  # 伪板运行 OpenCV 棋盘格检测
#   ./build.sh test     # CTest：原生 + cross 各跑一遍
#   ./build.sh clean    # 删除 build-*/ 和 install-*/
#
# 背后机制：
#   cmake 分两阶段——configure 读 CMakeLists.txt(+toolchain) 生成 Makefile，
#   build 调用 make 真正编译。原生与交叉必须用不同构建目录，
#   否则 CMakeCache.txt 相互污染。

set -e

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 虚拟根目录: 相当于把这个文件夹当成目标板子的 `/`
export SYSROOT=/sysroot

# 虚拟的第三方库路径和包安装路径
export THIRD_PARTY_LIBRARIES_PATH=/opt/3rdparty
export INSTALL_PATH=/opt/install

NATIVE_DIR="$SRC_DIR/build-native"
NATIVE_INSTALL="$SRC_DIR/install-native"
CROSS_DIR="$SRC_DIR/build-cross"
CROSS_INSTALL="$SRC_DIR/install-cross"
TOOLCHAIN="$SRC_DIR/toolchains/aarch64-linux-gnu.toolchain.cmake"

# 目标名 = ${PROJECT_NAME} = cross_compile_demo；
# CMakeLists.txt 里 install RUNTIME DESTINATION lib/${PROJECT_NAME}
NATIVE_BIN="$NATIVE_INSTALL/lib/cross_compile_demo/cross_compile_demo"
CROSS_BIN="$CROSS_INSTALL/lib/cross_compile_demo/cross_compile_demo"
CUDA_BIN="$CROSS_INSTALL/lib/cross_compile_demo/cuda_demo"

FAST_CHECK_BIN="$CROSS_INSTALL/lib/cross_compile_demo/fast_check_chessboard"
# OpenCV 棋盘格检测的测试图目录（demo 相对路径基于它，见 main.cpp 默认值）
FAST_CHECK_IMAGES="$SRC_DIR/src/opencv_demo/fast_check_chessboard/test_images"

configure_native() {
    cmake -S "$SRC_DIR" -B "$NATIVE_DIR" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$NATIVE_INSTALL"
}

configure_cross() {
    # -DCMAKE_TOOLCHAIN_FILE=... 就是交叉编译的开关（只在此处出现）
    cmake -S "$SRC_DIR" -B "$CROSS_DIR" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$CROSS_INSTALL" \
          -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
}

case "${1:-all}" in
  native)
    configure_native
    cmake --build "$NATIVE_DIR"              # build 阶段：调 make 编译
    cmake --install "$NATIVE_DIR"            # 参数=构建目录（生成脚本所在地）
    echo "✓ 产物: $NATIVE_BIN"
    "$NATIVE_BIN"
    ;;
  cross)
    configure_cross
    cmake --build "$CROSS_DIR"
    cmake --install "$CROSS_DIR"
    echo "✓ 产物: $CROSS_BIN"
    file "$CROSS_BIN"                        # 用 file 确认 ELF 架构
    ;;
  run)
    # ./build.sh run [cross_compile_demo|cuda_demo|fast_check_chessboard] [额外参数…]
    # 按 $2 选跑哪个交叉产物；不传默认 cross_compile_demo
    case "${2:-}" in
      cuda_demo)
        RUN_BIN="$CUDA_BIN"
        RUN_ARGS=()                        # cuda_demo 无额外参数
        ;;
      fast_check_chessboard)
        RUN_BIN="$FAST_CHECK_BIN"
        # OpenCV 库在 /opt/3rdparty 下，超出 -L 覆盖范围，需 LD_LIBRARY_PATH 补
        export LD_LIBRARY_PATH="$THIRD_PARTY_LIBRARIES_PATH/OpenCV/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        # OpenCV 依赖的系统库（libjpeg/libpng/libwebp/zlib 等）只在完整 rootfs 里，
        # run-on-qemu.sh 默认的 /usr/aarch64-linux-gnu 缺它们 → 用 QEMU_LD_PREFIX 指到 /sysroot
        export QEMU_LD_PREFIX=/sysroot
        # 可传自定义图像目录，默认 test_images
        RUN_ARGS=("${3:-$FAST_CHECK_IMAGES}")
        ;;
      *)                                 # 默认 cross_compile_demo；$2 非目标名时整体当参数传下去
        RUN_BIN="$CROSS_BIN"
        RUN_ARGS=("${@:2}")
        ;;
    esac
    "$SRC_DIR/run-on-qemu.sh" "$RUN_BIN" "${RUN_ARGS[@]}"
    ;;
  test)
    configure_native && cmake --build "$NATIVE_DIR"
    configure_cross && cmake --build "$CROSS_DIR"
    echo "--- 原生 CTest ---"
    ctest --test-dir "$NATIVE_DIR"
    echo "--- cross CTest（qemu 伪板仿真） ---"
    ctest --test-dir "$CROSS_DIR"
    ;;
  clean)
    rm -rf "$NATIVE_DIR" "$CROSS_DIR"
    rm -rf "$NATIVE_INSTALL" "$CROSS_INSTALL"
    echo "✓ 已清理 build-*/ 和 install-*/"
    ;;
  *)
    echo "用法: $0 [native|cross|run|test|clean]"
    echo "      $0 run [cross_compile_demo|cuda_demo|fast_check_chessboard] [参数…]"
    exit 1
    ;;
esac

echo ""
echo "✓ 完成"