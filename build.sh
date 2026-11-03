#!/usr/bin/bash
# 交叉编译演示工程 —— 一键构建/运行脚本
#
# 用法：
#   ./build.sh native   # 原生编译（x86_64）并运行
#   ./build.sh cross    # 交叉编译（aarch64），产物在 build-cross/
#   ./build.sh run      # 伪板运行 cross 产物（qemu-aarch64）
#   ./build.sh test     # CTest：原生 + cross 各跑一遍
#   ./build.sh clean    # 删除两个 build 目录
#
# 背后机制：
#   cmake 分两阶段——configure 读 CMakeLists.txt(+toolchain) 生成 Makefile，
#   build 调用 make 真正编译。原生与交叉必须用不同构建目录，
#   否则 CMakeCache.txt 相互污染。

set -e

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NATIVE_DIR="$SRC_DIR/build-native"
CROSS_DIR="$SRC_DIR/build-cross"
TOOLCHAIN="$SRC_DIR/toolchains/aarch64-linux-gnu.toolchain.cmake"

configure_native() {
    # -S <源码目录> -B <构建目录>：configure 阶段
    cmake -S "$SRC_DIR" -B "$NATIVE_DIR" -DCMAKE_BUILD_TYPE=Release
}

configure_cross() {
    # -DCMAKE_TOOLCHAIN_FILE=... 就是交叉编译的开关（只在此处出现）
    # 首次 configure 后写入缓存，之后每次重配置它自己会读 toolchain
    cmake -S "$SRC_DIR" -B "$CROSS_DIR" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
}

case "${1:-all}" in
  native)
    configure_native
    cmake --build "$NATIVE_DIR"              # build 阶段：调 make 编译
    echo "✓ 产物: $NATIVE_DIR/hello_cross"
    "$NATIVE_DIR/hello_cross"
    ;;
  cross)
    configure_cross
    cmake --build "$CROSS_DIR"
    echo "✓ 产物: $CROSS_DIR/hello_cross"
    file "$CROSS_DIR/hello_cross"            # 用 file 确认 ELF 架构
    ;;
  run)
    "$SRC_DIR/run-on-qemu.sh" "$CROSS_DIR/hello_cross"
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
    echo "✓ 已清理 build-native/ 和 build-cross/"
    ;;
  *)
    echo "用法: $0 [native|cross|run|test|clean]"
    exit 1
    ;;
esac

echo ""
echo "✓ 完成"