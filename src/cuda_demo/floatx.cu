/**
 * 内置类型 floatx 学习（x 为 2/3/4）
 */

#include <vector>
#include <cstdio>
#include <cuda_runtime.h>

#define CUDA_CHECK(call)                                                   \
  do                                                                       \
  {                                                                        \
    cudaError_t err_ = (call);                                             \
    if (err_ != cudaSuccess)                                               \
    {                                                                      \
      std::fprintf(stderr, "CUDA 错误 @ %s:%d : %s\n", __FILE__, __LINE__,  \
                   cudaGetErrorString(err_));                              \
      std::exit(1);                                                        \
    }                                                                      \
  } while (0)


// kernel func 1
__global__ void transform_points(float3* pts, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
    {
        float3 p = pts[i];
        p.x *= 2.0f;
        p.z += 9.0f;

        pts[i] = p;
    }
}

__global__ void transform_points_2(float3* pts, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
    {
        float3 p = pts[i];
        p.x += 5.0f;
        p.y *= 3.0f;

        pts[i] = p;
    }
}

int main(int argc, char**argv)
{

    // blocks & threads
    constexpr int n = 1024;
    int threads = 256;
    int blocks = (n + threads - 1) / threads;

    // 准备数据s
    std::vector<float3> points(n, make_float3(1.0f, 2.0f, 3.0f));
    float3*  d_float3;
    cudaMalloc(&d_float3, sizeof(float3) * n);
    cudaMemcpy(d_float3, points.data(), (size_t)n * sizeof(float3), cudaMemcpyHostToDevice);

    // GPU 计算并等待结果通过
    transform_points<<<blocks, threads>>>(d_float3, n);
    transform_points_2<<<blocks, threads>>>(d_float3, n);
    cudaDeviceSynchronize();

    // 数据拷贝回去
    cudaMemcpy(points.data(), d_float3, (size_t)n * sizeof(float3), cudaMemcpyDeviceToHost);
    
    //验证数据
    std::printf("points[100].x: %f, points[100].y: %f, points[100].z: %f\n", points[100].x, points[100].y, points[100].z);
    return 0;
}