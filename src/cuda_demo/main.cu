// src/cuda_demo/main.cu
// ==============================================================
// CUDA 入门 Demo —— 两个数组逐元素相加（GPU 世界的 Hello World）
//
// 五幕剧本（建议按这个顺序读代码）：
//   第一幕  探测 GPU：在不在？叫什么？算力多少？
//   第二幕  CPU 参考版：老办法串行加一遍，当对照基准
//   第三幕  GPU 正戏：分配显存 → 数据搬进显存 →
//           派几万线程同时算 → 结果搬回内存
//   第四幕  校验 + 计时：GPU 结果和 CPU 一样吗？快了多少倍？
//
// 编译它的是 nvcc，不是 gcc——.cu 文件里混着两种代码：
//   host   段：普通 C++，CPU 跑（main / for / printf...）
//   device 段：__global__ 函数，GPU 跑（下方那个 vecAdd）
// 两个世界各有各的内存，所以才有第三幕那些"搬运"。
// ==============================================================

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <cuda_runtime.h>

// 元素个数：1 千 6 百万。数据够大，GPU 的并行优势才看得出来。
constexpr int N = 1 << 24;

// ── 错误大扫除：CUDA 几乎每个 API 都会返回错误码 ──────────
// CUDA_CHECK(x) 是一段宏：执行 x，出错就打印出错位置并立刻退出。
// 初学最忌讳"写错了却不想办法报错"——这行宏能让你第一时间看到现场。
#define CUDA_CHECK(call)                                                   \
  do                                                                       \
  {                                                                        \
    cudaError_t err_ = (call);                                             \
    if (err_ != cudaSuccess)                                               \
    {                                                                      \
      std::fprintf(stderr, "CUDA 错误 @ %s:%d : %s\n", __FILE__, __LINE__, \
                   cudaGetErrorString(err_));                              \
      std::exit(1);                                                        \
    }                                                                      \
  } while (0)

// ── device 段：每个线程只干"一个元素的活" ───────────────────
// 这个函数不是被 CPU 调用的——你叫 GPU"派 X 个线程"来执行它。
// 每个线程拿到自己的编号，算自己那个格子，互不打架。
//
// ★ 线程编号怎么算（一维版）：
//      blockIdx.x  = 我这个线程属于第几个"线程块"
//      blockDim.x  = 一个块里装了多少线程 （256, 来源于 134~135 行），
//                    对于同一份启动配置，blockDim 对所有块、所有线程是同一个值。
//      threadIdx.x = 我在块内的第几个
//   全局编号 i = blockIdx.x * blockDim.x + threadIdx.x
//
//   形象一点：GPU 把线程排成"块"（block）再排成"网格"（grid）。
//   块是给程序员归组用的——块内线程能协作、能共享数据（今天的
//   demo 用不到，下一课再说）。今天块内 256 个线程，块数跟数据量匹配。
__global__ void vecAdd(const float* a, const float* b, float* c, int n)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n)
  {                      // 越界保护：N 不一定恰好整除 256
    c[i] = a[i] + b[i];  // 每个线程就干这一行
  }
}

// 主机计时小工具（CPU 侧，返回毫秒）
template <typename Fn>
double time_ms(Fn&& f)
{
  auto t0 = std::chrono::high_resolution_clock::now();
  f();
  auto t1 = std::chrono::high_resolution_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

int main()
{
  std::printf("===== CUDA Demo : 浮点数相加 (N=%d) =====\n", N);

  // ── 第一幕：GPU 在不在？ ──────────────────────────────────
  int devCount = 0;
  cudaError_t e = cudaGetDeviceCount(&devCount);

  bool haveGPU = (e == cudaSuccess && devCount > 0);
  if (haveGPU)
  {
    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
    std::printf("GPU: %s (计算能力 %d.%d, 流处理器簇=%d)\n", prop.name,
                prop.major, prop.minor, prop.multiProcessorCount);
  }
  else
  {
    // 本容器没插 GPU、qemu 伪板也仿不了 GPU → 走"优雅降级"：
    // 照常编译、链接、部署；GPU 段跳过，只演示 CPU 参考版。
    // 把产物拷到 Orin 板上运行，GPU 段才会真正点火。
    std::printf("未检测到可用的 GPU（返回码：%s）\n", cudaGetErrorString(e));
    std::printf(">> 本容器无显卡，qemu 仿不了 GPU，GPU 段将跳过；\n");
    std::printf(">> 交叉产物拷到 Orin 板上运行时，GPU 段会全速跑起来。\n");
  }

  // ── 第二幕：造数据 + CPU 参考版 ──────────────────────────
  std::vector<float> a(N), b(N);
  for (int i = 0; i < N; ++i)
  {
    a[i] = (i % 1000) * 0.7f;
    b[i] = (i % 1000) * 0.3f;
  }

  std::vector<float> ref(N), gpu(N);  // ref=CPU 结果, gpu=GPU 结果
  double cpu_ms = time_ms([&] {
    for (int i = 0; i < N; ++i)  // 老办法：CPU 单核，一遍一遍串行加
      ref[i] = a[i] + b[i];
  });
  
  std::printf("\n[CPU] 参考实现: %.2f ms\n", cpu_ms);

  // ── 第三幕：GPU 正戏 ──────────────────────────────────────
  if (haveGPU)
  {
    // 1) 在显存里开三块地（device 内存，CPU 碰不到）
    float *d_a = nullptr, *d_b = nullptr, *d_c = nullptr;
    CUDA_CHECK(cudaMalloc(&d_a, N * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_b, N * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_c, N * sizeof(float)));

    // 2) 把输入数据从 RAM 搬进显存
    CUDA_CHECK(
        cudaMemcpy(d_a, a.data(), N * sizeof(float), cudaMemcpyHostToDevice));
    CUDA_CHECK(
        cudaMemcpy(d_b, b.data(), N * sizeof(float), cudaMemcpyHostToDevice));

    // 3) 派活：启动 <<<块数, 每块线程数>>> 个线程
    const int threads = 256;
    const int blocks = (N + threads - 1) / threads;  // 向上取整
    std::printf("\n>>> 网格 = %d 块 x %d 线程 = %d 线程同时干活\n", blocks,
                threads, blocks * threads);

    // 4) 用 CUDA 事件计时（GPU 侧时钟，比主机计时精确）
    cudaEvent_t t0, t1;
    CUDA_CHECK(cudaEventCreate(&t0));
    CUDA_CHECK(cudaEventCreate(&t1));
    CUDA_CHECK(cudaEventRecord(t0));

    vecAdd<<<blocks, threads>>>(d_a, d_b, d_c, N); // GPU 计算
    CUDA_CHECK(cudaGetLastError());  // <<<>>> 启动是异步的，错误在这才现形
    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));  // 等 GPU 干完再继续

    float gpu_ms = 0.f;
    CUDA_CHECK(cudaEventElapsedTime(&gpu_ms, t0, t1));

    // 5) 结果搬回 RAM（device → host）
    CUDA_CHECK(
        cudaMemcpy(gpu.data(), d_c, N * sizeof(float), cudaMemcpyDeviceToHost));

    CUDA_CHECK(cudaFree(d_a));
    CUDA_CHECK(cudaFree(d_b));
    CUDA_CHECK(cudaFree(d_c));

    // ── 第四幕：校验 + 加速比 ────────────────────────────────
    long bad = 0;
    for (int i = 0; i < N; ++i)
    {
      // 浮点比较"== "是天坑（精度抖动），工程上都是比"差多少"
      if (std::fabs(gpu[i] - ref[i]) > 1e-3f)
      {
        if (bad < 5)
        {
          std::printf("不一致 @%d: GPU=%g CPU=%g\n", i, gpu[i], ref[i]);
        }
      
        ++bad;
      }
    }

    std::printf("\n[GPU] kernel 耗时: %.3f ms (纯计算，不含搬运)\n", gpu_ms);
    std::printf("结果校验: %s\n",
                bad == 0 ? "✓ GPU 和 CPU 完全对得上" : "✗ 有差异，回去查算法");
    std::printf("加速比: CPU/GPU = %.1f 倍\n", cpu_ms / gpu_ms);
    std::printf(
        "（注意：这里只比了计算本身；真实工程还要把两次搬运(RAM -> VRAM, VRAM -> RAM)的时间消耗算进去）\n");
  }
  else
  {
    // 无 GPU：跳过第三、四幕，至少看到 CPU 版能跑、得数长啥样
    std::printf("\n跳过 GPU 段（无设备）。CPU 参考版已验证算法正确性。\n");
    std::printf(
        "交叉产物(cross/.../cuda_demo)拷到 Orin 板上即可跑完整 GPU 路径。\n");
  }

  std::printf("\n===== 演示结束 =====\n");
  return 0;
}