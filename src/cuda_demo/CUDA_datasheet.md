
## 0. .cu = C++ + CUDA 扩展

`.cu` 喂给 **nvcc** 编译，拆成两段：

- **host 段**（`main`、循环、普通代码）→ 转手给 g++，编成 CPU 机器码
- **device 段**（`__global__` / `__device__` 函数）→ 编成 GPU 机器码


## 1. 函数限定符三兄弟

| 关键字 | 跑在哪 | 谁调用 | 例子 |
|---|---|---|---|
| `__global__` | GPU | **只有 CPU 侧用 `<<<...>>>` 启动** | `gray_rgb888`、`vecAdd` |
| `__device__` | GPU | GPU 函数内部互相调 | `rgb888_gray` |
| `__host__` | CPU | 普通调用 | `rgb888_gray` |

- `__global__` 必须**返回 void**、参数**按值传**（不能传引用 / `std::vector`）。
- `__host__ __device__` 连写表示**一份代码 CPU 和 GPU 通用**，保证 CPU 参考版本与 GPU 逐字节一致：

```cuda
__host__ __device__ inline uint8_t rgb888_gray(const uint8_t* p) { ... }
```

## 2. 常用类型

定宽整数（来自 `<cstdint>`）：

| 类型 | 位数 | 用途 | 例子 |
|---|---|---|---|
| `uint8_t` | 8 | 像素 R/G/B、灰度值 | `rgb[i*3+0]` |
| `uint16_t` | 16 | **深度值（mm）** | `depth[i]` |
| `uint32_t` | 32 | 距离运算防溢出 | 灰度累加 |
| `int` | 32 | 线程索引 | `i = blockIdx.x*blockDim.x+threadIdx.x` |
| `size_t` | 64 | 大数组字节数 / 指针偏移 | `(size_t)i * 3` |

CUDA 内置向量类型（`.x .y .z .w` 取分量，对齐良好，`make_float3(x,y,z)` 构造）：

```cuda
float3 p;   // 点云 3D 点：p.x p.y p.z
uchar4 px;  // R G B A 正好一个像素：一次 load 拿整像素，4 字节对齐、读得快
int2   c;   // 二维坐标 c.x c.y
```

特殊结构体类型举例：

| 类型 | 含义 |
|---|---|
| `dim3` | `x,y,z` 三个 uint；`gridDim`/`blockDim`/`<<<a,b>>>` 实参类型 |
| `cudaError_t` | API 返回码（也是一个枚举），`cudaSuccess` == 成功 |
| `cudaStream_t` / `cudaEvent_t` | 异步流 / 计时事件 |
| `cudaDeviceProp` | 显卡属性（名字、算力、SM 数） |

## 3. 枚举（两种，别混）

- **CUDA API 的 C 风格枚举**，全局名字直接用：

```cuda
cudaMemcpy(dst, src, bytes, cudaMemcpyHostToDevice);  // cudaMemcpyKind
cudaError_t err = cudaGetDeviceCount(&n);             // err != cudaSuccess 即出错
```

- **自己代码用 `enum class`**（host/device 都能用，多一层类型安全，不偷偷跟 int 互转）。

## 4. 核函数写法 = 一个固定模式

```cuda
__global__ void myKernel(const float* in, float* out, int n)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;  // ① 报全局编号（固定公式）
  if (i < n)                                      // ② 越界保护
  {
    out[i] = in[i] * 2.f;                         // ③ 每线程只做自己那格
  }
}
// CPU 侧启动：
//   int threads = 256;
//   int blocks  = (n + threads - 1) / threads;   // 向上取整
//   myKernel<<<blocks, threads>>>(d_in, d_out, n);
```

要点：

- `i = blockIdx.x*blockDim.x + threadIdx.x` 是固定公式：**块号 × 每块线程数 + 块内序号**。
- 2D 图像再加一层 `int pix = y*W + x;`。**索引顺序必须顺着"地址连续"那一维走**（rgb2gray 的 columnmajor 反例就是故意拧着来）。
- `<<<blocks, threads>>>` 共两个参数：第一个 = 块数，第二个 = 每块线程数
- **启动是异步的**：`<<<>>>` 只是"下订单"。错误要 `cudaGetLastError()` + 同步/事件才追得到。
- 一个线程处理一小块数据，**别在线程里写大循环当串行跑**。

## 5. 常见写法套路速览

| 套路 | 写法 | 见处 |
|---|---|---|
| 错误检查宏 | `#define CUDA_CHECK(call) do{...报错退出}while(0)` | 各 demo 顶部 |
| 编译期常量 | `constexpr int W = 1280;` | 文件顶部 |
| 定点整数替代浮点 | `(77u*R + 150u*G + 29u*B) >> 8` | `rgb888_gray` |
| CPU 参考版对齐校验 | 同公式 CPU 先算，GPU 结果逐字节比 | 校验幕 |
| 无别名指针 | `const float* __restrict__ a`（后续优化再学） | —— |

## 6. 新手坑位清单

1. **把 host 指针传给核函数** → GPU 读不到；先 `cudaMalloc` + `cudaMemcpy`。
2. **不查错误码** → 启动失败静默、结果全错还找不到；无条件用 `CUDA_CHECK`。
3. **索引用 `int` 溢出** → 大数组/字节偏移用 `size_t`。
4. **RGB 3 字节像素当 4 字节读** → 未对齐错乱；要么按 3 字节读，要么上游转 RGBA。
5. **`float ==` 比较** → 永远比差值范围：`fabs(a-b) < 1e-3f`。
6. **以为 `<<<>>>` 是同步调用** → 它异步，读结果前要 sync / 事件。
7. **忘了 `__syncthreads()`** → shared memory 课的核心坑，先预告。