#!/usr/bin/env bash
# run-on-qemu.sh — 无板运行 aarch64 产物：把本机"伪装"成一块 aarch64 板
#
# 原理：qemu-user 是用户态仿真，不走整机虚拟。
#   -L <目录> = 指定"板子的根文件系统"（动态加载器 + 动态库的去处）。
#   等价写法：QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 ...
#
# 用法：
#   ./run-on-qemu.sh build-cross/hello_cross [参数...]

set -euo pipefail

# Ubuntu cross 包自带的 aarch64 动态加载器/库；用真实板子时改成其 rootfs 路径
FAKE_ROOTFS="${QEMU_LD_PREFIX:-/usr/aarch64-linux-gnu}"

if [ $# -lt 1 ]; then
    echo "用法: $0 <aarch64 可执行文件> [参数...]"
    exit 1
fi

bin="$1"; shift

echo "▶ 伪板运行：qemu-aarch64 -L ${FAKE_ROOTFS} ${bin} $*"
exec qemu-aarch64 -L "${FAKE_ROOTFS}" "$bin" "$@"