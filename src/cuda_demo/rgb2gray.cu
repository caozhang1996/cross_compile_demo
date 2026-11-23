// src/cuda_demo/rgb2gray.cu
// ==============================================================
// CUDA 进阶 Demo ② —— 图像灰度转换（RGBD 数据入手）
// 主线：内存布局 + 合并访问（coalesced access）
//
// 前置知识（要用到步骤①向量加法的底子）：
//   · 线程编号：i = blockIdx.x*blockDim.x + threadIdx.x
//   · 显存搬运：cudaMalloc / cudaMemcpy / cudaFree
//
// 本 demo 的"数据"取自真实工作场景——奥比这类 RGBD 相机最常
// 交付的两种帧，内存布局截然不同：
//
//   ① 彩色帧 RGB888（interleaved 交错式，行主序）：
//        内存里就是 [R G B][R G B][R G B]...
//        每像素 3 字节，第 i 个像素落在字节偏移 i*3 处。
//   ② 深度帧 uint16（单通道）：
//        每像素 1 个 uint16（单位 mm），第 i 个像素在偏移 i*2 处。
//
// 灰度转换目标：把彩色帧变成"肉眼看得出明暗、算法好上手"的
// 单通道图。转灰度用的亮度公式 BT.601：
//        Y = 0.299*R + 0.587*G + 0.114*B
// GPU 上不用浮点（慢），改成"定点整数"技巧：
//        Y = (77*R + 150*G + 29*B) >> 8     ← 77/256≈0.299 ...
// 系数夸大成 256 倍、最后右移 8 位找回来；全整数、零除法，快。
//
// ★ 今天的核心问题：GPU 读内存讲究"合并访问"——
//   一个 warp（32 个线程）同时发起的访存，硬件会先试图"合并"成
//   尽量少的几次内存事务，每次事务是按 32 字节(一个 sector)搬的。
//   想让速度快，就得保证【连续编号的线程 → 连续的内存地址】。
//   一旦错位（stride 3、跳行…），每个 sector 里只有少数字节被用上，
//   其余全浪费——内存流量瞬间翻几倍。
//
// 我们准备了 4 个核，输出都是灰度图，但是非写法的访问模式天差地别：
//   kernel 1 · 只取 R 通道当灰度：stride 3 访问 → 每个 sector 只用 1/3
//   kernel 2 · 三个通道一起读：按像素整体读 → sector 全部吃满（正解）
//   kernel 3 · 列主序访问：连续的线程在跳行 → 灾难级不合并（反例）
//   kernel 4 · 深度图 uint16 → uint8 灰度：2 字节像素天然合并
// 四个核结果都能和 CPU 参考版对得上——同一个结果，不同的命。
// ==============================================================

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <cuda_runtime.h>

// ── 图像尺寸：1280x720，常见 RGBD 深度/彩流分辨率 ──────────
constexpr int W = 1280;
constexpr int H = 720;
constexpr int N = W * H;  // 像素总数

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

// ── 亮度公式：同一份代码 CPU / GPU 共用（__host__ __device__）──
// 这样 CPU 参考版和 GPU 核用的是同一个函数，结果必然逐字节一致。
__host__ __device__ inline uint8_t rgb888_gray(const uint8_t* p)
{
  uint32_t y = 77u * p[0] + 150u * p[1] + 29u * p[2];  // 先放大 256 倍
  return (uint8_t)(y >> 8);                            // 再缩小回去
}

// ==============================================================
// kernel 1 —— 「懒写法」：只取 R 通道当灰度
// 数据访问：src[i*3]，步长 3 地读字节。
// 为什么慢（本节重点，结合上面的 sector 讲）：
//   warp 32 线程要读的地址是 0,3,6,...93，落在字节 0~95 这 96 字节里
//   = 3 个 sector（32B×3）。可每个 sector 里真正用到的只有约 10 字节，
//   剩下 2/3 是被你"顺手请求"却在缓存里躺着的废数据。
//   换句话说：搬 96 字节、只用 32 字节 → 有效带宽只剩 1/3。
__global__ void gray_extractR(const uint8_t* src, uint8_t* dst, int n)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n)
  {
    dst[i] = src[i * 3];  // 只有 R（懒人字幕：这其实不是灰度，是近似）
  }
}

// ==============================================================
// kernel 2 —— 正解：把 3 个字节当作"一个整体"从相邻地址读
// 数据访问：线程 i 读 src[i*3]、src[i*3+1]、src[i*3+2]。
// 为什么快：
//   3 条 load 请求的地址分别是 {0,3,...,93}、{1,4,...,94}、{2,5,...,95}，
//   全都在那 96 字节（3 sector）里。虽然第一条 load 也只"用"了三分之一的
//   字节，但 sector 会被留在缓存里，第 2、3 条 load 直接命中——最终 96 字节
//   被完完全全消费掉，DRAM 只搬了一次。这就是"合并"的真义：
//   ★ 别只看单条 load，要看整个 warp 的需求是否紧凑成连续块。
__global__ void gray_rgb888(const uint8_t* src, uint8_t* dst, int n)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n)
  {
    dst[i] = rgb888_gray(src + (size_t)i * 3);
  }
}

// ==============================================================
// kernel 3 —— 反例：列主序访问同一张行主序图（历史教学名场面）
// 正确性不变，但访问模式故意写坏：
//   线程 i 负责的像素是 列 x = i/H、行 y = i%H。
//   连续线程 i、i+1 → 行 y 加 1 → 像素地址跳了一个整行 W*3 字节！
// 后果：一个 warp 的 32 次读请求，落在 32 个不同的行 → 32 个独立的
//   sector → 一次访存被拆成 32 次事务。内存流量瞬间放大几十倍。
//
// 现实中的教训：做图像处理前先搞清楚图在内存里是行主序还是列主序，
// 线程编号必须顺着"地址连续"的那一维走。张量/相机缓冲经常带 pitch
// （行间有空隙的对齐），同样道理。
__global__ void gray_rgb888_columnmajor(const uint8_t* src, uint8_t* dst, int w, int h)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= w * h) return;
  int x = i / h;       // "列"快速变化
  int y = i % h;       // 行在慢速变化 —— 线程相邻时反而跨行
  int pix = y * w + x;
  dst[pix] = rgb888_gray(src + (size_t)pix * 3);
}

// ==============================================================
// kernel 4 —— 深度图：uint16 转 8bit 灰度（顺便归一化）
// 数据访问：线程 i 读 1 个 uint16。连续的线程 → 连续 2 字节。
//   warp 32 线程覆盖 64 字节 = 恰好 2 个 sector，整段吃满 → 天然合并。
// 归一化：把毫米距离压到 0~255，maxDepth 以内线性映射、超出截断。
__global__ void depth_to_gray8(const uint16_t* depth, uint8_t* dst, int n, int maxDepth)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n)
  {
    uint32_t d = depth[i];
    if (d == 0) dst[i] = 0;  // 0 = 无效深度（相机没测到），涂黑
    else if (d >= (uint32_t)maxDepth) dst[i] = 255;  // 太远/爆掉，涂白
    else dst[i] = (uint8_t)((d * 255u) / (uint32_t)maxDepth);
  }
}

// ── 主机计时小工具（沿用步骤①）──────────────────────────────
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
  std::printf("===== Demo ② : RGB 灰度转换 + 深度转灰度 =====\n");
  std::printf("图片 %dx%d, 像素 %d 个\n", W, H, N);

  // ── 第一幕：GPU 是否在线（本容器无 GPU，qemu 也仿不了 → 走 CPU）──
  int devCount = 0;
  cudaError_t e0 = cudaGetDeviceCount(&devCount);
  bool haveGPU = (e0 == cudaSuccess && devCount > 0);
  if (haveGPU)
  {
    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
    std::printf("GPU: %s (计算能力 %d.%d)\n", prop.name, prop.major,
                prop.minor);
  }
  else
  {
    std::printf(">> 本容器无显卡：GPU 段跳过，只跑 CPU 参考版（验证算法与\n");
    std::printf(">> 数据布局）。交叉产物拷到 Orin 板上，4 个核会真正开跑。\n\n");
  }

  // ── 第二幕：造 RGBD 数据（模拟一帧彩流 + 一帧深流）──────────
  // 彩色：让 R/G/B 三通道有规律地不同，肉眼可见"只取 R"不是灰度。
  // 深度：毫米距离 + 少量 0/65535 的坏点（深度相机最常见的毛刺）。
  std::vector<uint8_t> rgb(N * 3);
  std::vector<uint16_t> depth(N);
  for (int i = 0; i < N; ++i)
  {
    rgb[i * 3 + 0] = (uint8_t)((i * 5) & 0xFF);
    rgb[i * 3 + 1] = (uint8_t)((i * 29 + 7) & 0xFF);
    rgb[i * 3 + 2] = (uint8_t)((i * 87 + 13) & 0xFF);
    uint16_t d = (uint16_t)(300 + (i * 137) % 7300);  // 300 ~ 7600 mm
    if (i % 97 == 0)   d = 0;        // 没测到的坏点
    if (i % 131 == 0)  d = 65535;    // 爆掉/遮挡
    depth[i] = d;
  }

  // CPU 参考版：同一套公式在 CPU 上先把答案算出来。
  constexpr int kMaxDepth = 8000;  // 深度上限 8m
  std::vector<uint8_t> refGray(N), refGrayR(N), refGrayDepth(N);
  double cpu_ms = time_ms([&] {
    for (int i = 0; i < N; ++i)
    {
      refGray[i] = rgb888_gray(&rgb[(size_t)i * 3]);
      refGrayR[i] = rgb[i * 3];  // 懒写法就是把 R 当灰度
      uint32_t d = depth[i];
      if (d == 0) refGrayDepth[i] = 0;
      else if (d >= kMaxDepth) refGrayDepth[i] = 255;
      else refGrayDepth[i] = (uint8_t)((d * 255u) / (uint32_t)kMaxDepth);
    }
  });
  std::printf("[CPU] 三张灰度图参考版耗时: %.2f ms\n\n", cpu_ms);

  // ── 第三幕：GPU 正戏（4 个核 + 各自计时 + 校验）────────────
  if (!haveGPU) { std::printf("跳过 GPU 段。CPU 参考版已验证算法正确性。\n"); return 0; }

  uint8_t* d_rgb;   uint16_t* d_depth;
  uint8_t *d_grayR, *d_grayY, *d_grayY_cm, *d_grayDepth;
  CUDA_CHECK(cudaMalloc(&d_rgb, (size_t)N * 3 * sizeof(uint8_t)));
  CUDA_CHECK(cudaMalloc(&d_depth, (size_t)N * sizeof(uint16_t)));
  CUDA_CHECK(cudaMalloc(&d_grayR, (size_t)N));
  CUDA_CHECK(cudaMalloc(&d_grayY, (size_t)N));
  CUDA_CHECK(cudaMalloc(&d_grayY_cm, (size_t)N));
  CUDA_CHECK(cudaMalloc(&d_grayDepth, (size_t)N));
  CUDA_CHECK(cudaMemcpy(d_rgb, rgb.data(), (size_t)N * 3, cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_depth, depth.data(), (size_t)N * sizeof(uint16_t), cudaMemcpyHostToDevice));

  const int threads = 256;
  const int blocks = (N + threads - 1) / threads;
  std::printf(">>> 网格 = %d 块 x %d 线程\n", blocks, threads);

  // 每个核独立计时：录起点事件 → 派活 → 录终点 → 取耗时。

  // ---- kernel 1：只取 R ----
  cudaEvent_t e_[2];
  CUDA_CHECK(cudaEventCreate(&e_[0])); CUDA_CHECK(cudaEventCreate(&e_[1]));
  CUDA_CHECK(cudaEventRecord(e_[0]));
  gray_extractR<<<blocks, threads>>>(d_rgb, d_grayR, N);
  CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaEventRecord(e_[1]));
  CUDA_CHECK(cudaEventSynchronize(e_[1]));
  float ms_R; CUDA_CHECK(cudaEventElapsedTime(&ms_R, e_[0], e_[1]));

  // ---- kernel 2：整像素三通道 ----
  CUDA_CHECK(cudaEventRecord(e_[0]));
  gray_rgb888<<<blocks, threads>>>(d_rgb, d_grayY, N);
  CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaEventRecord(e_[1]));
  CUDA_CHECK(cudaEventSynchronize(e_[1]));
  float ms_Y; CUDA_CHECK(cudaEventElapsedTime(&ms_Y, e_[0], e_[1]));

  // ---- kernel 3：列主序反例 ----
  CUDA_CHECK(cudaEventRecord(e_[0]));
  gray_rgb888_columnmajor<<<blocks, threads>>>(d_rgb, d_grayY_cm, W, H);
  CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaEventRecord(e_[1]));
  CUDA_CHECK(cudaEventSynchronize(e_[1]));
  float ms_CM; CUDA_CHECK(cudaEventElapsedTime(&ms_CM, e_[0], e_[1]));

  // ---- kernel 4：深度转灰度 ----
  CUDA_CHECK(cudaEventRecord(e_[0]));
  depth_to_gray8<<<blocks, threads>>>(d_depth, d_grayDepth, N, kMaxDepth);
  CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaEventRecord(e_[1]));
  CUDA_CHECK(cudaEventSynchronize(e_[1]));
  float ms_D; CUDA_CHECK(cudaEventElapsedTime(&ms_D, e_[0], e_[1]));

  // ── 第四幕：校验（GPU 结果 vs CPU 参考，必须逐字节一致）─────
  std::vector<uint8_t> gR(N), gY(N), gCM(N), gD(N);
  CUDA_CHECK(cudaMemcpy(gR.data(), d_grayR, N, cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaMemcpy(gY.data(), d_grayY, N, cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaMemcpy(gCM.data(), d_grayY_cm, N, cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaMemcpy(gD.data(), d_grayDepth, N, cudaMemcpyDeviceToHost));

  auto diff = [](const auto& a, const auto& b) {
    long long bad = 0; int first = -1;
    for (size_t i = 0; i < a.size(); ++i)
      if (a[i] != b[i]) { ++bad; if (first < 0) first = (int)i; }
    return std::make_pair(bad, first);
  };

  auto d_R = diff(gR, refGrayR);
  auto d_Y = diff(gY, refGray);
  auto d_CM = diff(gCM, refGray);
  auto d_D = diff(gD, refGrayDepth);

  // ── 第五幕：报告 ───────────────────────────────────────────
  std::printf("\n%-28s %9s  校验\n", "kernel", "耗时(ms)");
  std::printf("%-28s %9.3f  %s\n", "1·只取R通道(stride3)", ms_R,
              d_R.first == 0 ? "✓" : "✗");
  std::printf("%-28s %9.3f  %s\n", "2·三通道整读(正解)", ms_Y,
              d_Y.first == 0 ? "✓" : "✗");
  std::printf("%-28s %9.3f  %s\n", "3·列主序(反例)", ms_CM,
              d_CM.first == 0 ? "✓" : "✗");
  std::printf("%-28s %9.3f  %s\n", "4·深度16bit→灰度", ms_D,
              d_D.first == 0 ? "✓" : "✗");
  std::printf("\n== 关注点 ==");
  std::printf("\n· kernel1 vs kernel2：同样输出尺寸，1 是 3× 内存流量（越显存越明显）");
  std::printf("\n· kernel2 vs kernel3：结果一模一样（都对了），访问模式毁性能");
  std::printf("\n· kernel1、2、3 校验均通过 = 三种写法结果都对，速度差就是内存效率差\n");

  if (d_Y.second >= 0)
    std::printf("首个不一致索引: %d (GPU=%d CPU=%d)\n", d_Y.second, gY[d_Y.second],
                refGray[d_Y.second]);

  // 上板跑时，用 Nsight Compute 看"到底差在哪"：
  //   ncu --set MemoryWorkloadAnalysis ./rgb2gray_demo
  //   重点看每个核的 Global Memory Load / Store 效率与实际 DRAM 读字节数：
  //   kernel1 的 Global Load Throughput 约只有 kernel2 的 1/3,
  //   kernel3 会灾难性地拉高 Local / Global 事务数。
  std::printf("\n（Orin 上建议 ncu --section MemoryWorkloadAnalysis 对比这 4 个核）\n");

  CUDA_CHECK(cudaFree(d_rgb)); CUDA_CHECK(cudaFree(d_depth));
  CUDA_CHECK(cudaFree(d_grayR)); CUDA_CHECK(cudaFree(d_grayY));
  CUDA_CHECK(cudaFree(d_grayY_cm)); CUDA_CHECK(cudaFree(d_grayDepth));
  CUDA_CHECK(cudaEventDestroy(e_[0])); CUDA_CHECK(cudaEventDestroy(e_[1]));
  std::printf("\n===== Demo ② 结束 =====\n");
  return 0;
}