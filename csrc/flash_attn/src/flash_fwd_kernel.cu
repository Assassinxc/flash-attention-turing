#include <iostream>
#include <cstdlib>
#include <cstdio>
#include <cassert>
#include <float.h>
#include <torch/extension.h>
#include <cute/tensor.hpp>
#include "cutlass/util/print_error.hpp"
#include "cutlass/util/GPU_Clock.hpp"
#include "cutlass/util/helper_cuda.hpp"

#include <cutlass/array.h>
#include <cutlass/cutlass.h>
#include <cutlass/numeric_conversion.h>
#include <cutlass/numeric_types.h>

#include "kernel_traits.h"

using namespace cute;



template <typename Kernel_traits>
__global__ __launch_bounds__(256)
void flash_fwd_kernel(
    half_t const* q,
    half_t const* k,
    half_t const* v,
    half_t* o,
    int batch_size, int seq_len, int num_heads, int head_dim
)
{

    constexpr int kBlockM = Kernel_traits::kBlockM;
    constexpr int kBlockN = Kernel_traits::kBlockN;
    constexpr int kHeadDim = Kernel_traits::kHeadDim;

    Tensor mQ = make_tensor(make_gmem_ptr(q),
                            make_shape(batch_size, seq_len, num_heads, head_dim),
                            make_stride(seq_len * num_heads * head_dim, num_heads * head_dim, head_dim, Int<1>{}));

    Tensor gQ = local_tile(mQ(blockIdx.x, _, blockIdx.y, _), Shape<Int<kBlockM>, Int<kHeadDim>>{},
                           make_coord(blockIdx.z, 0));

    Tensor mK = make_tensor(make_gmem_ptr(k),
                            make_shape(batch_size, seq_len, num_heads, head_dim),
                            make_stride(seq_len * num_heads * head_dim, num_heads * head_dim, head_dim, Int<1>{}));

    Tensor gK = local_tile(mK(blockIdx.x, _, blockIdx.y, _), Shape<Int<kBlockN>, Int<kHeadDim>>{},
                           make_coord(_, 0));

    // this is a (seq_len, head_dim) column major matrix, so its V^T in row major
    Tensor mV = make_tensor(make_gmem_ptr(v),
                            make_shape(batch_size, head_dim, num_heads, seq_len),
                            make_stride(seq_len * num_heads * head_dim, Int<1>{}, head_dim, num_heads * head_dim));

    Tensor gV = local_tile(mV(blockIdx.x, _, blockIdx.y, _), Shape<Int<kHeadDim>, Int<kBlockN>>{},
                           make_coord(0, _));

    Tensor mO = make_tensor(make_gmem_ptr(o),
                            make_shape(batch_size, seq_len, num_heads, head_dim),
                            make_stride(seq_len * num_heads * head_dim, num_heads * head_dim, head_dim, Int<1>{}));

    Tensor gO = local_tile(mO(blockIdx.x, _, blockIdx.y, _), Shape<Int<kBlockM>, Int<kHeadDim>>{},
                           make_coord(blockIdx.z, 0));


    extern __shared__ char smem_[];


    Tensor sQ = make_tensor(make_smem_ptr(reinterpret_cast<half_t*>(&smem_[0])), typename Kernel_traits::SmemLayoutQ{});
    Tensor sK = make_tensor(sQ.data() + kBlockM*kHeadDim, typename Kernel_traits::SmemLayoutK{});
    Tensor sV = make_tensor(sK.data(), typename Kernel_traits::SmemLayoutV{});
    Tensor sO = make_tensor(make_smem_ptr(reinterpret_cast<half_t*>(&smem_[0])), typename Kernel_traits::SmemLayoutQ{});


    int thread_id = threadIdx.x;
    int lane_id = thread_id % 32;


    float rM_old[2] = {-FLT_MAX, -FLT_MAX};
    float rM[2] = {0.0f};
    float rL_old[2] = {0.0f};
    float rL[2] = {0.0f};
    // for storing rowsum(P)
    float rD[2] = {0.0f};

    unsigned mask;
    if (lane_id < 4)       mask = 0x0000000F;  // Lanes  0 -  3
    else if (lane_id < 8)  mask = 0x000000F0;  // Lanes  4 -  7
    else if (lane_id < 12) mask = 0x00000F00;  // Lanes  8 - 11
    else if (lane_id < 16) mask = 0x0000F000;  // Lanes 12 - 15
    else if (lane_id < 20) mask = 0x000F0000;  // Lanes 16 - 19
    else if (lane_id < 24) mask = 0x00F00000;  // Lanes 20 - 23
    else if (lane_id < 28) mask = 0x0F000000;  // Lanes 24 - 27
    else                   mask = 0xF0000000;  // Lanes 28 - 31


    int lane_id_to_read_from;
    if (lane_id < 4)       lane_id_to_read_from = 0;   // Lanes  0 -  3
    else if (lane_id < 8)  lane_id_to_read_from = 4;   // Lanes  4 -  7
    else if (lane_id < 12) lane_id_to_read_from = 8;   // Lanes  8 - 11
    else if (lane_id < 16) lane_id_to_read_from = 12;  // Lanes 12 - 15
    else if (lane_id < 20) lane_id_to_read_from = 16;  // Lanes 16 - 19
    else if (lane_id < 24) lane_id_to_read_from = 20;  // Lanes 20 - 23
    else if (lane_id < 28) lane_id_to_read_from = 24;  // Lanes 24 - 27
    else                   lane_id_to_read_from = 28;  // Lanes 28 - 31

    // gmem -> smem for Q, K, V
    typename Kernel_traits::GmemTiledCopyQK gmem_tiled_copy_QK;
    typename Kernel_traits::GmemTiledCopyV gmem_tiled_copy_V;
    typename Kernel_traits::GmemTiledCopyO gmem_tiled_copy_O;

    ThrCopy thr_copy_QK = gmem_tiled_copy_QK.get_slice(threadIdx.x);
    Tensor tQgQ = thr_copy_QK.partition_S(gQ);
    Tensor tQsQ = thr_copy_QK.partition_D(sQ);

    Tensor tKgK = thr_copy_QK.partition_S(gK);
    Tensor tKsK = thr_copy_QK.partition_D(sK);
    Tensor tKrK = make_fragment_like(tKsK);


    ThrCopy thr_copy_V = gmem_tiled_copy_V.get_slice(threadIdx.x);
    Tensor tVgV = thr_copy_V.partition_S(gV);
    Tensor tVsV = thr_copy_V.partition_D(sV);
    Tensor tVrV = make_fragment_like(tVsV);

    // smem -> gmem for O
    ThrCopy thr_copy_O = gmem_tiled_copy_O.get_slice(threadIdx.x);
    Tensor tOsO_copy = thr_copy_O.partition_S(sO);
    Tensor tOgO_copy = thr_copy_O.partition_D(gO);


    typename Kernel_traits::TiledMma tiled_mma;

    // mma for S = QK^T
    ThrMMA thr_mma_S = tiled_mma.get_slice(threadIdx.x);
    Tensor tSsQ = thr_mma_S.partition_A(sQ);
    Tensor tSsK = thr_mma_S.partition_B(sK);

    Tensor tSrQ = thr_mma_S.make_fragment_A(tSsQ);
    Tensor tSrK = thr_mma_S.make_fragment_B(tSsK);
    Tensor tSrS_float = partition_fragment_C(tiled_mma, Shape<Int<kBlockM>, Int<kBlockN>>{});


    // mma for O = PV
    ThrMMA thr_mma_O = tiled_mma.get_slice(threadIdx.x);
    Tensor tOsV = thr_mma_O.partition_B(sV);
    Tensor tOrV = thr_mma_O.make_fragment_B(tOsV);
    Tensor tOrO_float = partition_fragment_C(tiled_mma, Shape<Int<kBlockM>, Int<kHeadDim>>{});
    Tensor tOsO = thr_mma_O.partition_C(sO);


    //  each warp only process 16 rows
    auto s2r_tiled_copy_Q = make_tiled_copy_A(typename Kernel_traits::SmemCopyAtomQ{}, tiled_mma);
    auto s2r_thr_copy_Q = s2r_tiled_copy_Q.get_slice(threadIdx.x);
    auto tSsQ_copy_view = s2r_thr_copy_Q.partition_S(sQ);
    auto tSrQ_copy_view = s2r_thr_copy_Q.retile_D(tSrQ);

    auto s2r_tiled_copy_K = make_tiled_copy_B(typename Kernel_traits::SmemCopyAtomK{}, tiled_mma);
    auto s2r_thr_copy_K = s2r_tiled_copy_K.get_slice(threadIdx.x);
    auto tSsK_copy_view = s2r_thr_copy_K.partition_S(sK);
    auto tSrK_copy_view = s2r_thr_copy_K.retile_D(tSrK);

    auto s2r_tiled_copy_V = make_tiled_copy_B(typename Kernel_traits::SmemCopyAtomV{}, tiled_mma);
    auto s2r_thr_copy_V = s2r_tiled_copy_V.get_slice(threadIdx.x);
    auto tOsV_copy_view = s2r_thr_copy_V.partition_S(sV);
    auto tOrV_copy_view = s2r_thr_copy_V.retile_D(tOrV);

    auto KV_TILE_MAX = size<3>(tKgK);
    auto QK_BLOCK_MAX = size<2>(tSsK);
    auto PV_BLOCK_MAX = size<2>(tOsV);
    // prologue

    copy(gmem_tiled_copy_QK, tQgQ, tQsQ);
    copy(gmem_tiled_copy_QK, tKgK(_,_,_,0), tKrK);


    clear(tOrO_float);

    // main loop
    CUTE_NO_UNROLL
    for (int kv_tile = 0; kv_tile < KV_TILE_MAX; ++kv_tile) {


        copy(gmem_tiled_copy_QK, tKrK, tKsK);

        __syncthreads();

        clear(tSrS_float);

        if (kv_tile + 1 < KV_TILE_MAX) {
            copy(gmem_tiled_copy_QK, tKgK(_,_,_,kv_tile + 1), tKrK);
        }


        for (int qk_block = 0; qk_block < QK_BLOCK_MAX; qk_block++) {
            copy(s2r_tiled_copy_Q, tSsQ_copy_view(_,_,qk_block), tSrQ_copy_view(_,_,qk_block));
            copy(s2r_tiled_copy_K, tSsK_copy_view(_,_,qk_block), tSrK_copy_view(_,_,qk_block));

            gemm(tiled_mma, tSrQ(_,_,qk_block), tSrK(_,_,qk_block), tSrS_float);

        }

        __syncthreads();
        copy(gmem_tiled_copy_V, tVgV(_,_,_,kv_tile), tVsV);
        __syncthreads();

        for (int i=0;i< tSrS_float.size();i ++ ) {
            tSrS_float[i] *= 1.0f / sqrtf(kHeadDim);
        }


        // compute m = rowmax(S)
        for (int i=0; i< 2; i++) {
            rM[i] = rM_old[i];
        }


        // intra-thread reduction

        for (int i=0; i< 2; i++) {
            for (int j=0; j < tSrS_float(make_coord(_,i),_,_).size(); j++) {
                rM[i] = fmaxf(rM[i], tSrS_float(make_coord(_,i),_,_)[j]);
            }
        }


        // intra-warp reduction
        for (int i=0; i<2; i++) {
            for (int offset = 2; offset > 0; offset /= 2) {
               rM[i] = fmaxf(rM[i], __shfl_down_sync(mask, rM[i], offset));
            }
        }


        // sync rM

        for (int i =0; i<2; i++) {
            rM[i] = __shfl_sync(mask, rM[i], lane_id_to_read_from);
        }


        // compute P = softmax(S)
        for (int i =0; i<2; i++) {
            for (int j=0; j < tSrS_float(make_coord(_,i),_,_).size(); j++) {
                tSrS_float(make_coord(_,i),_,_)[j] = expf(tSrS_float(make_coord(_,i),_,_)[j] - rM[i]);
            }
        }


        // rescale l and also reset rD to 0
        for (int i =0; i<2; i++) {
            rL[i] = expf(rM_old[i] - rM[i]) * rL_old[i];
            rD[i] = 0.0f;
        }


        // compute sum(sP)

        // thread reduction

        for (int i =0; i<2; i++) {
            for (int j=0; j < tSrS_float(make_coord(_,i),_,_).size(); j++) {
                rD[i] += tSrS_float(make_coord(_,i),_,_)[j];
            }
        }



        // warp reduction
        for (int i =0; i<2; i++) {
            for (int offset = 2; offset > 0; offset /= 2) {
               rD[i] +=  __shfl_down_sync(mask, rD[i], offset);
            }
        }



        // can just keep the correct rL to lane 0
        for (int i =0; i<2; i++) {
            rL[i] += rD[i];
        }

        // sync rL
        for (int i =0; i<2; i++) {
            rL[i] = __shfl_sync(mask, rL[i], lane_id_to_read_from);
        }



        constexpr int num_element = decltype(size(tSrS_float))::value;

        cutlass::NumericArrayConverter<half_t, float, num_element> convert_op;
        auto frag = convert_op(*reinterpret_cast<const cutlass::Array<float, num_element> *>(tSrS_float.data()));

        Tensor tOrP = make_tensor(make_rmem_ptr<half_t>(&frag), tSrS_float.layout());



        // rescale O

        for (int i =0; i<2; i++) {
            for (int j=0; j < tOrO_float(make_coord(_,i),_,_).size(); j++) {
                tOrO_float(make_coord(_,i),_,_)[j] = expf(rM_old[i] - rM[i]) * tOrO_float(make_coord(_,i),_,_)[j];
            }
        }




        for (int pv_block = 0; pv_block < PV_BLOCK_MAX; pv_block++) {


            copy(s2r_tiled_copy_V, tOsV_copy_view(_,_,pv_block), tOrV_copy_view(_,_,pv_block));

            gemm(tiled_mma, tOrP(_,_,pv_block), tOrV(_,_,pv_block), tOrO_float);

        }


        // update m and l
        for (int i = 0; i< 2;i++) {
            rM_old[i] = rM[i];
            rL_old[i] = rL[i];
        }


        __syncthreads();

    }
    // end of KV loop


    for (int i =0; i<2; i++) {
        for (int j=0; j < tOrO_float(make_coord(_,i),_,_).size(); j++) {
            tOrO_float(make_coord(_,i),_,_)[j] /= rL[i];
        }
    }


    constexpr int num_element = decltype(size(tOrO_float))::value;

    cutlass::NumericArrayConverter<half_t, float, num_element> convert_op;
    auto frag = convert_op(*reinterpret_cast<const cutlass::Array<float, num_element> *>(tOrO_float.data()));
    Tensor tOrO = make_tensor(make_rmem_ptr<half_t>(&frag), tOrO_float.layout());


    copy(tOrO, tOsO);

    __syncthreads();

    copy(gmem_tiled_copy_O, tOsO_copy, tOgO_copy);

}



torch::Tensor flash_fwd(torch::Tensor q, torch::Tensor k, torch::Tensor v,
                                int batch_size, int seq_len, int num_heads, int head_dim)
{

    constexpr int kBlockM = 128;
    constexpr int kBlockN = 64;
    constexpr int kHeadDim = 128;

    auto sQ_layout_atom = composition(Swizzle<3, 3, 3>{},
                                 Layout<Shape<_16,_64>,
                                 Stride<_64, _1>>{});

    auto sK_layout_atom = composition(Swizzle<3, 3, 3>{},
                               Layout<Shape<_16,_64>,
                               Stride<_64, _1>>{});

    auto sV_layout_atom = composition(Swizzle<3, 3, 3>{},
                             Layout<Shape<_64,_16>,
                             Stride<_1, _64>>{});

    auto sO_layout_atom = composition(Swizzle<3, 3, 3>{},
                                 Layout<Shape<_16,_64>,
                                 Stride<_64, _1>>{});


    auto sQ_layout = tile_to_shape(sQ_layout_atom,
                           make_shape(Int<kBlockM>{}, Int<kHeadDim>{}));



    auto sK_layout = tile_to_shape(sK_layout_atom,
                           make_shape(Int<kBlockN>{}, Int<kHeadDim>{}));


    auto sV_layout = tile_to_shape(sV_layout_atom,
                            make_shape(Int<kHeadDim>{}, Int<kBlockN>{}));

    auto sO_layout = tile_to_shape(sO_layout_atom,
                           make_shape(Int<kBlockM>{}, Int<kHeadDim>{}));



    auto sS_layout = make_layout(make_shape (Int<kBlockM>{}, Int<kBlockN>{}),
                        make_stride(Int<kBlockN>{}, Int<1>{}));




    TiledCopy copy_Q = make_tiled_copy(Copy_Atom<AutoVectorizingCopy, half_t>{},
                                Layout<Shape<_32,_8>, Stride<_8,_1>>{},
                                Layout<Shape< _1,_8>>{});

    TiledCopy copy_K = make_tiled_copy(Copy_Atom<AutoVectorizingCopy, half_t>{},
                                Layout<Shape<_32,_8>, Stride<_8,_1>>{},
                                Layout<Shape< _1,_8>>{});

    // 64 threads loading a 128 x 32 tile
    TiledCopy copy_V = make_tiled_copy(Copy_Atom<AutoVectorizingCopy, half_t>{},
                                Layout<Shape<_8,_32>, Stride<_1,_8>>{},
                                Layout<Shape< _8,_1>>{});

    TiledCopy copy_O = make_tiled_copy(Copy_Atom<AutoVectorizingCopy, half_t>{},
                                Layout<Shape<_32,_8>, Stride<_8,_1>>{},
                                Layout<Shape< _1,_8>>{});


    TiledMMA mma_S = make_tiled_mma(SM75_16x8x8_F32F16F16F32_TN{},
                                        Layout<Shape<_8, _1, _1>>{},
                                        Tile<_128,_64,_8>{}); // (kBlockM, kBlockN, 8)

    TiledMMA mma_O = make_tiled_mma(SM75_16x8x8_F32F16F16F32_TN{},
                                        Layout<Shape<_8, _1, _1>>{},
                                        Tile<_128,_128,_8>{}); // (kBlockM, kHeadDim, 8)


    torch::Tensor o = torch::empty(q.sizes(), q.options().dtype(torch::kFloat16));

    half_t* q_ptr = reinterpret_cast<half_t*>(q.data_ptr());
    half_t* k_ptr = reinterpret_cast<half_t*>(k.data_ptr());
    half_t* v_ptr = reinterpret_cast<half_t*>(v.data_ptr());
    half_t* o_ptr = reinterpret_cast<half_t*>(o.data_ptr());


    dim3 dimGrid(batch_size, num_heads, seq_len / kBlockM);
    dim3 dimBlock(256);
    int maxbytes = 65536;



    auto kernel = flash_fwd_kernel<Flash_fwd_kernel_traits<128, 128, 64, 8>>;
    cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, maxbytes);


    kernel<<<dimGrid, dimBlock, maxbytes>>>(q_ptr,
                                             k_ptr,
                                             v_ptr,
                                             o_ptr,
                                             batch_size, seq_len, num_heads, head_dim);
    return o;

}