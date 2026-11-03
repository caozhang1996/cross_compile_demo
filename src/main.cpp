// 交叉编译演示程序：自报家门 + 用点 STL，证明目标侧标准库链路是通的。
#include <atomic>
#include <iostream>
#include <string>
#include <vector>

#ifndef TARGET_PROCESSOR
#define TARGET_PROCESSOR "unknown"
#endif

// 由编译器预定义宏推断实际架构，和 CMake 传进来的对照
static std::string machine() {
#if defined(__aarch64__)
    return "aarch64";
#elif defined(__x86_64__)
    return "x86_64";
#elif defined(__arm__)
    return "arm";
#elif defined(__i386__)
    return "i386";
#else
    return "unknown";
#endif
}

int main() {
    std::atomic<int> counter{0};
    std::vector<std::string> items;
    for (int i = 1; i <= 3; ++i) {
        items.push_back(std::to_string(i));
        counter.fetch_add(i);
    }
    std::cout << "CMake 传入的目标架构   : " TARGET_PROCESSOR "\n"
              << "编译器宏推断的架构     : " << machine() << "\n"
              << "sizeof(void*)          : " << sizeof(void*) << "\n"
              << "vector 元素总数        : " << items.size() << "\n"
              << "atomic 累加结果        : " << counter.load() << "\n"
              << "C++ 语言标准           : " << __cplusplus << "\n";
    return 0;
}