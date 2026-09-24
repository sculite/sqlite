#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <stdio.h>
#include "gpu_manager.h"

#define BLOCK_SIZE 256
#define MAX_CONDITIONS 32
#define MAX_AGGREGATES GPU_MAX_AGGREGATES_PER_QUERY

/* GPU operator codes */
enum OpCode {
    OP_EQ = 0,
    OP_NE = 1,
    OP_LT = 2,
    OP_LE = 3,
    OP_GT = 4,
    OP_GE = 5,
    OP_AND = 6,
    OP_OR = 7,
    OP_NOT = 8,
    OP_BETWEEN = 9,
    OP_IN = 10
};

// Condition struc
struct Condition {
    int opCode;
    int columnIndex;
    long long value1;
    long long value2;
    int valueCount;
    long long inValues[16];
    int leftChild;
    int rightChild;
};

__device__ int evaluateCondition(
    const long long* row,
    const Condition* cond,
    const Condition* allConds,
    int numColumns,
    const unsigned char* nullMask,
    int rowIndex
) {
    long long colValue;
    int i;

    #define CELL_IS_NULL(colIdx) ( \
        nullMask != 0 && (colIdx) >= 0 \
        && (nullMask[(((size_t)(rowIndex) * (size_t)numColumns + (size_t)(colIdx)) >> 3)] \
            & (1 << (((rowIndex) * numColumns + (colIdx)) & 7))) \
    )
    
    switch(cond->opCode) {
        case OP_EQ:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            return colValue == cond->value1;
            
        case OP_NE:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            return colValue != cond->value1;
            
        case OP_LT:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            return colValue < cond->value1;
            
        case OP_LE:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            return colValue <= cond->value1;
            
        case OP_GT:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            return colValue > cond->value1;
            
        case OP_GE:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            return colValue >= cond->value1;
            
        case OP_BETWEEN:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            return (colValue >= cond->value1) && (colValue <= cond->value2);
            
        case OP_IN:
            if( CELL_IS_NULL(cond->columnIndex) ) return 0;
            colValue = row[cond->columnIndex];
            for(i = 0; i < cond->valueCount && i < 16; i++) {
                if(colValue == cond->inValues[i]) {
                    return 1;
                }
            }
            return 0;
            
        case OP_AND:
            if(cond->leftChild >= 0 && cond->rightChild >= 0) {
                return evaluateCondition(row, &allConds[cond->leftChild], allConds, numColumns, nullMask, rowIndex) &&
                       evaluateCondition(row, &allConds[cond->rightChild], allConds, numColumns, nullMask, rowIndex);
            }
            return 0;
            
        case OP_OR:
            if(cond->leftChild >= 0 && cond->rightChild >= 0) {
                return evaluateCondition(row, &allConds[cond->leftChild], allConds, numColumns, nullMask, rowIndex) ||
                       evaluateCondition(row, &allConds[cond->rightChild], allConds, numColumns, nullMask, rowIndex);
            }
            return 0;
            
        case OP_NOT:
            if(cond->leftChild >= 0) {
                return !evaluateCondition(row, &allConds[cond->leftChild], allConds, numColumns, nullMask, rowIndex);
            }
            return 0;
            
        default:
            return 0;
    }
}

// The actual Where clause kernel, execed in parallel
__global__ void whereClauseKernel(
    const long long* data,
    int* resultMask,
    const Condition* conditions,
    int numRows,
    int numColumns,
    int rootConditionIndex,
    const unsigned char* nullMask
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if(idx < numRows) {
        const long long* row = data + (idx * numColumns);
        
        if(rootConditionIndex >= 0) {
            resultMask[idx] = evaluateCondition(row, &conditions[rootConditionIndex], conditions, numColumns, nullMask, idx);
        } else {
            resultMask[idx] = 1;
        }
    }
}


__global__ void compactResultsKernel(
    const long long* inputData,
    long long* outputData,
    const int* resultMask,
    const int* scanIndices,
    int numRows,
    int numColumns
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if(idx < numRows && resultMask[idx]) {
        int outIdx = scanIndices[idx];
        for(int col = 0; col < numColumns; col++) {
            outputData[outIdx * numColumns + col] = inputData[idx * numColumns + col];
        }
    }
}

__global__ void countMatchesKernel(
    const int* resultMask,
    int* totalMatches,
    int numRows
) {
    __shared__ int blockCount[BLOCK_SIZE];
    int threadIndex = threadIdx.x;
    int rowIndex = blockIdx.x * blockDim.x + threadIndex;

    blockCount[threadIndex] = rowIndex < numRows ? resultMask[rowIndex] : 0;
    __syncthreads();

    for(int offset = blockDim.x / 2; offset > 0; offset /= 2) {
        if(threadIndex < offset) {
            blockCount[threadIndex] += blockCount[threadIndex + offset];
        }
        __syncthreads();
    }

    if(threadIndex == 0) {
        atomicAdd(totalMatches, blockCount[0]);
    }
}


//GPU kernel for block-level scans
__global__ void blockScanKernel(
    const int* input,
    int* output,
    int* blockSums,
    int n
) {
    extern __shared__ int temp[];
    
    int thid = threadIdx.x;
    int globalIdx = blockIdx.x * blockDim.x + threadIdx.x;
    int blockId = blockIdx.x;
    
    if(thid > 0) {
        if(globalIdx - 1 < n) {
            temp[thid] = input[globalIdx - 1];
        } else {
            temp[thid] = 0;
        }
    } else {
        temp[thid] = 0; 
    }
    __syncthreads();
    
    for(int offset = 1; offset < blockDim.x; offset *= 2) {
        int val = 0;
        if(thid >= offset) {
            val = temp[thid - offset];
        }
        __syncthreads();
        temp[thid] += val;
        __syncthreads();
    }
    
    if(thid == blockDim.x - 1 && blockSums) {
        if(globalIdx < n) {
            blockSums[blockId] = temp[thid] + input[globalIdx];
        } else {
            blockSums[blockId] = temp[thid];
        }
    }
    
    if(globalIdx < n) {
        output[globalIdx] = temp[thid];
    }
}

__global__ void addBlockOffsetsKernel(
    int* output,
    const int* blockOffsets,
    int n
) {
    int globalIdx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if(globalIdx < n && blockIdx.x > 0) {
        output[globalIdx] += blockOffsets[blockIdx.x - 1];
    }
}

__global__ void inclusiveToExclusiveKernel(
    int* data,
    int n
) {
    int globalIdx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if(globalIdx < n) {
        int current = data[globalIdx];
        if(globalIdx > 0) {

            __shared__ int shared[256];
            shared[threadIdx.x] = current;
            __syncthreads();
            
            if(threadIdx.x > 0) {
                data[globalIdx] = shared[threadIdx.x - 1];
            } else if(blockIdx.x > 0) {
                data[globalIdx] = 0;  
            } else {
                data[globalIdx] = 0;  
            }
        } else {
            data[globalIdx] = 0;  
        }
    }
}


//performs an exclusive prefix sum on the block sums array on the CPU
static int hostBlockPrefixSum(int* blockSums, int numBlocks) {
    if(numBlocks <= 1) return 0;
    
    for(int i = 1; i < numBlocks; i++) {
        blockSums[i] += blockSums[i - 1];
    }
    return 0;
}

static int gpuPrefixSum(
    const int* d_input,
    int* d_output,
    int* d_blockSums,
    int* d_blockOffsets,
    int numRows,
    cudaStream_t stream
) {
    if(numRows <= 0) return 0;
    
    cudaError_t err = cudaSuccess;
    int numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    int sharedMemSize = BLOCK_SIZE * 2 * sizeof(int);
    int* h_blockSums = NULL;
    
    blockScanKernel<<<numBlocks, BLOCK_SIZE, sharedMemSize, stream>>>(
        d_input, d_output, d_blockSums, numRows
    );
    
    err = cudaGetLastError();
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Block scan kernel failed: %s\n", cudaGetErrorString(err));
        return -1;
    }
    
    if(numBlocks > 1) {
        h_blockSums = (int*)malloc(numBlocks * sizeof(int));
        if(!h_blockSums) {
            fprintf(stderr, "GPU: Failed to allocate host block sums\n");
            return -1;
        }
        
        err = cudaMemcpyAsync(h_blockSums, d_blockSums, numBlocks * sizeof(int), cudaMemcpyDeviceToHost, stream);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to copy block sums to host: %s\n", cudaGetErrorString(err));
            free(h_blockSums);
            return -1;
        }

        err = cudaStreamSynchronize(stream);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to synchronize block sums: %s\n", cudaGetErrorString(err));
            free(h_blockSums);
            return -1;
        }
        
        hostBlockPrefixSum(h_blockSums, numBlocks);
        
        err = cudaMemcpyAsync(d_blockSums, h_blockSums, numBlocks * sizeof(int), cudaMemcpyHostToDevice, stream);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to copy block sums to device: %s\n", cudaGetErrorString(err));
            free(h_blockSums);
            return -1;
        }
        
        free(h_blockSums);
        
        addBlockOffsetsKernel<<<numBlocks, BLOCK_SIZE, 0, stream>>>(
            d_output, d_blockSums, numRows
        );
        
        err = cudaGetLastError();
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Add block offsets kernel failed: %s\n", cudaGetErrorString(err));
            return -1;
        }
    }
    
    return 0;
}

void cpuPrefixSum(const int* input, int* output, int n) {
    if(n <= 0) return;
    output[0] = 0;
    for(int i = 1; i < n; i++) {
        output[i] = output[i-1] + input[i-1];
    }
}


static int g_gpuInitialized = 0;
static int g_deviceCount = 0;


//reusable device and host buffers for GPU operations
typedef struct DeviceScratch {
    long long* d_data;
    long long* d_output;
    Condition* d_conditions;
    int* d_resultMask;
    int* d_scanIndices;
    int* d_matchCount;
    int* d_blockSums;        
    int* d_blockOffsets;     
    unsigned char* d_nullMaskV;
    GpuAggSpec* d_aggSpecs;
    GpuAggPartial* d_partials;
    GpuAggPartial* d_aggOut;
    cudaStream_t transferStream;  
    cudaStream_t computeStream;  
    size_t dataCapacity;
    size_t outputCapacity;
    size_t conditionCapacity;
    size_t maskCapacity;
    size_t scanCapacity;
    size_t matchCountCapacity;
    size_t blockSumsCapacity;
    size_t blockOffsetsCapacity;
    size_t nullCapacity;
    size_t specCapacity;
    size_t partialCapacity;
    size_t aggOutCapacity;
} DeviceScratch;

static DeviceScratch g_deviceScratch = {0};
static int ensureDeviceBuffer(void** ptr, size_t requiredBytes, size_t* capacity, const char* label) {
    if(*ptr && requiredBytes <= *capacity) {
        return 0;
    }
    if(*ptr) {
        cudaFree(*ptr);
        *ptr = NULL;
    }

    cudaError_t err = cudaMalloc(ptr, requiredBytes);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to allocate %s: %s\n", label, cudaGetErrorString(err));
        return -1;
    }

    *capacity = requiredBytes;
    return 0;
}

extern "C" int gpuWhereClauseInit(void) {
    if(g_gpuInitialized) {
        return 0;
    }
    
    cudaError_t err = cudaGetDeviceCount(&g_deviceCount);
    if(err != cudaSuccess || g_deviceCount == 0) {
        fprintf(stderr, "GPU: No CUDA-capable device found\n");
        return -1;
    }
    
    cudaDeviceProp prop;
    err = cudaGetDeviceProperties(&prop, 0);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to get device properties\n");
        return -1;
    }
    
    //CUDA streams for asyncop
    err = cudaStreamCreate(&g_deviceScratch.transferStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to create transfer stream: %s\n", cudaGetErrorString(err));
        return -1;
    }
    
    err = cudaStreamCreate(&g_deviceScratch.computeStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to create compute stream: %s\n", cudaGetErrorString(err));
        cudaStreamDestroy(g_deviceScratch.transferStream);
        return -1;
    }
    
    g_gpuInitialized = 1;
    return 0;
}


extern "C" void gpuWhereClauseCleanup(void) {
    if(g_gpuInitialized) {
        if(g_deviceScratch.d_data) cudaFree(g_deviceScratch.d_data);
        if(g_deviceScratch.d_output) cudaFree(g_deviceScratch.d_output);
        if(g_deviceScratch.d_conditions) cudaFree(g_deviceScratch.d_conditions);
        if(g_deviceScratch.d_resultMask) cudaFree(g_deviceScratch.d_resultMask);
        if(g_deviceScratch.d_scanIndices) cudaFree(g_deviceScratch.d_scanIndices);
        if(g_deviceScratch.d_matchCount) cudaFree(g_deviceScratch.d_matchCount);
        if(g_deviceScratch.d_blockSums) cudaFree(g_deviceScratch.d_blockSums);
        if(g_deviceScratch.d_blockOffsets) cudaFree(g_deviceScratch.d_blockOffsets);
        if(g_deviceScratch.d_nullMaskV) cudaFree(g_deviceScratch.d_nullMaskV);
        if(g_deviceScratch.d_aggSpecs) cudaFree(g_deviceScratch.d_aggSpecs);
        if(g_deviceScratch.d_partials) cudaFree(g_deviceScratch.d_partials);
        if(g_deviceScratch.d_aggOut) cudaFree(g_deviceScratch.d_aggOut);
        
        if(g_deviceScratch.transferStream) cudaStreamDestroy(g_deviceScratch.transferStream);
        if(g_deviceScratch.computeStream) cudaStreamDestroy(g_deviceScratch.computeStream);
        
        memset(&g_deviceScratch, 0, sizeof(g_deviceScratch));

        cudaDeviceReset();
        g_gpuInitialized = 0;
    }
}


extern "C" int gpuWhereClause(
    const long long* h_data,
    long long* h_output,
    int* h_outputCount,
    const Condition* h_conditions,
    int numRows,
    int numColumns,
    int numConditions,
    int rootConditionIndex,
    const unsigned char* h_nullMask
) {
    if(!g_gpuInitialized) {
        fprintf(stderr, "GPU: Not initialized\n");
        return -1;
    }
    
    if(!h_data || !h_outputCount) {
        fprintf(stderr, "GPU: Invalid parameters\n");
        return -1;
    }
    
    cudaError_t err = cudaSuccess;
    int numBlocks = 0;
    int resultCount = 0;
    int lastScanIndex = 0;
    int lastMask = 0;
    size_t outputSize = 0;

    size_t dataSize = (size_t)numRows * (size_t)numColumns * sizeof(long long);
    size_t maskSize = (size_t)numRows * sizeof(int);
    size_t blockSumsSize = ((numRows + BLOCK_SIZE - 1) / BLOCK_SIZE) * sizeof(int);
    size_t condSize = (size_t)numConditions * sizeof(Condition);
    size_t nullSize = numRows > 0 ? ((size_t)numRows * (size_t)numColumns + 7) / 8 : 0;

    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_data, dataSize, &g_deviceScratch.dataCapacity, "device data") != 0) {
        goto cleanup;
    }
    if(h_output && ensureDeviceBuffer((void**)&g_deviceScratch.d_output, dataSize, &g_deviceScratch.outputCapacity, "device output") != 0) {
        goto cleanup;
    }
    if(numConditions > 0) {
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_conditions, condSize, &g_deviceScratch.conditionCapacity, "device conditions") != 0) {
            goto cleanup;
        }
    }
    if(nullSize > 0 && ensureDeviceBuffer((void**)&g_deviceScratch.d_nullMaskV, nullSize, &g_deviceScratch.nullCapacity, "device null mask") != 0) {
        goto cleanup;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_resultMask, maskSize, &g_deviceScratch.maskCapacity, "device result mask") != 0) {
        goto cleanup;
    }
    if(h_output) {
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_scanIndices, maskSize, &g_deviceScratch.scanCapacity, "device scan indices") != 0) {
            goto cleanup;
        }
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_blockSums, blockSumsSize, &g_deviceScratch.blockSumsCapacity, "device block sums") != 0) {
            goto cleanup;
        }
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_blockOffsets, blockSumsSize, &g_deviceScratch.blockOffsetsCapacity, "device block offsets") != 0) {
            goto cleanup;
        }
    } else if(ensureDeviceBuffer((void**)&g_deviceScratch.d_matchCount, sizeof(int), &g_deviceScratch.matchCountCapacity, "device match count") != 0) {
        goto cleanup;
    }

    //async memcpy can be pipelined
    err = cudaMemcpyAsync(g_deviceScratch.d_data, h_data, dataSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to async copy data to device: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }

    if(numConditions > 0) {
        err = cudaMemcpyAsync(g_deviceScratch.d_conditions, h_conditions, condSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to async copy conditions to device: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }
    }

    if(nullSize > 0){
        if(h_nullMask){
            err = cudaMemcpyAsync(g_deviceScratch.d_nullMaskV, h_nullMask, nullSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        }else{
            err = cudaMemsetAsync(g_deviceScratch.d_nullMaskV, 0, nullSize, g_deviceScratch.transferStream);
        }
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to upload null mask: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }
    }
    
    err = cudaStreamSynchronize(g_deviceScratch.transferStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to synchronize transfer stream: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }

    numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    whereClauseKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_data,
        g_deviceScratch.d_resultMask,
        g_deviceScratch.d_conditions,
        numRows,
        numColumns,
        rootConditionIndex,
        nullSize > 0 ? g_deviceScratch.d_nullMaskV : NULL
    );

    err = cudaGetLastError();
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Kernel launch failed: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }

    if(!h_output) {
        err = cudaMemsetAsync(g_deviceScratch.d_matchCount, 0, sizeof(int), g_deviceScratch.computeStream);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to clear match count: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }

        countMatchesKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
            g_deviceScratch.d_resultMask,
            g_deviceScratch.d_matchCount,
            numRows
        );

        err = cudaGetLastError();
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Count kernel launch failed: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }

        err = cudaMemcpyAsync(&resultCount, g_deviceScratch.d_matchCount, sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to copy match count: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }

        err = cudaStreamSynchronize(g_deviceScratch.computeStream);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to synchronize match count: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }

        *h_outputCount = resultCount;
        goto cleanup;
    }

    if(gpuPrefixSum(g_deviceScratch.d_resultMask, g_deviceScratch.d_scanIndices,
                   g_deviceScratch.d_blockSums, g_deviceScratch.d_blockOffsets,
                   numRows, g_deviceScratch.computeStream) != 0) {
        goto cleanup;
    }

    err = cudaMemcpyAsync(&lastScanIndex, g_deviceScratch.d_scanIndices + numRows - 1,
                          sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to copy final scan index: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    err = cudaMemcpyAsync(&lastMask, g_deviceScratch.d_resultMask + numRows - 1,
                          sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to copy final mask: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }

    err = cudaStreamSynchronize(g_deviceScratch.computeStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to synchronize scan results: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    resultCount = lastScanIndex + lastMask;

    if(h_output) {
        compactResultsKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
            g_deviceScratch.d_data,
            g_deviceScratch.d_output,
            g_deviceScratch.d_resultMask,
            g_deviceScratch.d_scanIndices,
            numRows,
            numColumns
        );

        err = cudaGetLastError();
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Compact kernel launch failed: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }

        outputSize = (size_t)resultCount * (size_t)numColumns * sizeof(long long);
        if(outputSize > 0) {
            err = cudaMemcpyAsync(h_output, g_deviceScratch.d_output, outputSize, cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
            if(err != cudaSuccess) {
                fprintf(stderr, "GPU: Failed to async copy results: %s\n", cudaGetErrorString(err));
                goto cleanup;
            }
        }
    }
    
    err = cudaStreamSynchronize(g_deviceScratch.computeStream);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to synchronize result transfer: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }

    *h_outputCount = resultCount;

cleanup:
    return (err == cudaSuccess) ? 0 : -1;
}

extern "C" int gpuWhereClauseCount(
    const long long* h_data,
    int* h_outputCount,
    const Condition* h_conditions,
    int numRows,
    int numColumns,
    int numConditions,
    int rootConditionIndex,
    const unsigned char* h_nullMask
) {
    return gpuWhereClause(
        h_data,
        NULL,
        h_outputCount,
        h_conditions,
        numRows,
        numColumns,
        numConditions,
        rootConditionIndex,
        h_nullMask
    );
}



//pipelined version of gpuWhereClauseCount
//submit does HtoD, filter, and count 
//collect doesDtoH of count result
extern "C" int gpuWhereClauseCountSubmit(
    const long long* h_data,
    const Condition* h_conditions,
    int numRows,
    int numColumns,
    int numConditions,
    int rootConditionIndex,
    const unsigned char* h_nullMask
){
    if(!g_gpuInitialized) {
        fprintf(stderr, "GPU: Not initialized\n");
        return -1;
    }
    if(!h_data || numRows <= 0) {
        return -1;
    }

    cudaError_t err = cudaSuccess;
    size_t dataSize = (size_t)numRows * (size_t)numColumns * sizeof(long long);
    size_t maskSize = (size_t)numRows * sizeof(int);
    size_t condSize = (size_t)numConditions * sizeof(Condition);
    size_t blockSumsSize = ((numRows + BLOCK_SIZE - 1) / BLOCK_SIZE) * sizeof(int);
    size_t nullSize = ((size_t)numRows * (size_t)numColumns + 7) / 8;

    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_data, dataSize, &g_deviceScratch.dataCapacity, "device data") != 0) {
        return -1;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_resultMask, maskSize, &g_deviceScratch.maskCapacity, "device result mask") != 0) {
        return -1;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_matchCount, sizeof(int), &g_deviceScratch.matchCountCapacity, "device match count") != 0) {
        return -1;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_nullMaskV, nullSize, &g_deviceScratch.nullCapacity, "device null mask") != 0) {
        return -1;
    }
    if(numConditions > 0) {
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_conditions, condSize, &g_deviceScratch.conditionCapacity, "device conditions") != 0) {
            return -1;
        }
    }

    err = cudaStreamSynchronize(g_deviceScratch.computeStream);
    if(err != cudaSuccess) return -1;

    err = cudaMemcpyAsync(g_deviceScratch.d_data, h_data, dataSize,
                          cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
    if(err != cudaSuccess) return -1;

    if(numConditions > 0) {
        err = cudaMemcpyAsync(g_deviceScratch.d_conditions, h_conditions, condSize,
                              cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        if(err != cudaSuccess) return -1;
    }

    if(h_nullMask){
        err = cudaMemcpyAsync(g_deviceScratch.d_nullMaskV, h_nullMask, nullSize,
                              cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
    }else{
        err = cudaMemsetAsync(g_deviceScratch.d_nullMaskV, 0, nullSize, g_deviceScratch.transferStream);
    }
    if(err != cudaSuccess) return -1;

    err = cudaStreamSynchronize(g_deviceScratch.transferStream);
    if(err != cudaSuccess) return -1;

    int numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    whereClauseKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_data,
        g_deviceScratch.d_resultMask,
        g_deviceScratch.d_conditions,
        numRows,
        numColumns,
        rootConditionIndex,
        g_deviceScratch.d_nullMaskV
    );
    if(cudaGetLastError() != cudaSuccess) return -1;

    err = cudaMemsetAsync(g_deviceScratch.d_matchCount, 0, sizeof(int), g_deviceScratch.computeStream);
    if(err != cudaSuccess) return -1;

    countMatchesKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_resultMask,
        g_deviceScratch.d_matchCount,
        numRows
    );
    if(cudaGetLastError() != cudaSuccess) return -1;

    return 0;
}

extern "C" int gpuWhereClauseCountCollect(int* h_outputCount) {
    if(!h_outputCount) return -1;

    cudaError_t err = cudaMemcpyAsync(h_outputCount, g_deviceScratch.d_matchCount,
                                       sizeof(int), cudaMemcpyDeviceToHost,
                                       g_deviceScratch.computeStream);
    if(err != cudaSuccess) return -1;

    err = cudaStreamSynchronize(g_deviceScratch.computeStream);
    if(err != cudaSuccess) return -1;

    return 0;
}


__global__ void compactRowidsKernel(
    const long long* inputData,
    long long* outputRowids,
    const int* resultMask,
    const int* scanIndices,
    int numRows,
    int numColumns
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(idx < numRows && resultMask[idx]) {
        int outIdx = scanIndices[idx];
        outputRowids[outIdx] = inputData[(long long)idx * numColumns];
    }
}

extern "C" int gpuWhereClauseRowids(
    const long long* h_data,
    long long* h_outputRowids,
    int* h_outputCount,
    const Condition* h_conditions,
    int numRows,
    int numColumns,
    int numConditions,
    int rootConditionIndex,
    const unsigned char* h_nullMask
) {
    if(!g_gpuInitialized) {
        fprintf(stderr, "GPU: Not initialized\n");
        return -1;
    }
    if(!h_data || !h_outputCount) {
        fprintf(stderr, "GPU: Invalid parameters\n");
        return -1;
    }

    cudaError_t err = cudaSuccess;
    int numBlocks = 0;
    int resultCount = 0;
    size_t maskSize = (size_t)numRows * sizeof(int);
    size_t condSize = (size_t)numConditions * sizeof(Condition);
    size_t dataSize = (size_t)numRows * (size_t)numColumns * sizeof(long long);
    size_t nullSize = numRows > 0 ? ((size_t)numRows * (size_t)numColumns + 7) / 8 : 0;

    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_data, dataSize, &g_deviceScratch.dataCapacity, "device data") != 0) {
        goto cleanup;
    }
    if(h_outputRowids) {
        size_t rowidsSize = (size_t)numRows * sizeof(long long);
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_output, rowidsSize, &g_deviceScratch.outputCapacity, "device output") != 0) {
            goto cleanup;
        }
    }
    if(numConditions > 0) {
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_conditions, condSize, &g_deviceScratch.conditionCapacity, "device conditions") != 0) {
            goto cleanup;
        }
    }
    if(nullSize > 0 && ensureDeviceBuffer((void**)&g_deviceScratch.d_nullMaskV, nullSize, &g_deviceScratch.nullCapacity, "device null mask") != 0) {
        goto cleanup;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_resultMask, maskSize, &g_deviceScratch.maskCapacity, "device result mask") != 0) {
        goto cleanup;
    }
    if(h_outputRowids) {
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_scanIndices, maskSize, &g_deviceScratch.scanCapacity, "device scan indices") != 0) {
            goto cleanup;
        }
        size_t blockSumsSize = ((numRows + BLOCK_SIZE - 1) / BLOCK_SIZE) * sizeof(int);
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_blockSums, blockSumsSize, &g_deviceScratch.blockSumsCapacity, "device block sums") != 0) {
            goto cleanup;
        }
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_blockOffsets, blockSumsSize, &g_deviceScratch.blockOffsetsCapacity, "device block offsets") != 0) {
            goto cleanup;
        }
    } else {
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_matchCount, sizeof(int), &g_deviceScratch.matchCountCapacity, "device match count") != 0) {
            goto cleanup;
        }
    }

    err = cudaMemcpyAsync(g_deviceScratch.d_data, h_data, dataSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
    if(err != cudaSuccess) { fprintf(stderr, "GPU: H2D copy failed: %s\n", cudaGetErrorString(err)); goto cleanup; }
    if(numConditions > 0) {
        err = cudaMemcpyAsync(g_deviceScratch.d_conditions, h_conditions, condSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        if(err != cudaSuccess) { fprintf(stderr, "GPU: H2D cond copy failed: %s\n", cudaGetErrorString(err)); goto cleanup; }
    }
    if(nullSize > 0){
        if(h_nullMask){
            err = cudaMemcpyAsync(g_deviceScratch.d_nullMaskV, h_nullMask, nullSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        }else{
            err = cudaMemsetAsync(g_deviceScratch.d_nullMaskV, 0, nullSize, g_deviceScratch.transferStream);
        }
        if(err != cudaSuccess) { fprintf(stderr, "GPU: H2D null mask failed: %s\n", cudaGetErrorString(err)); goto cleanup; }
    }
    err = cudaStreamSynchronize(g_deviceScratch.transferStream);
    if(err != cudaSuccess) { fprintf(stderr, "GPU: Transfer sync failed: %s\n", cudaGetErrorString(err)); goto cleanup; }

    numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    whereClauseKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_data, g_deviceScratch.d_resultMask, g_deviceScratch.d_conditions,
        numRows, numColumns, rootConditionIndex,
        nullSize > 0 ? g_deviceScratch.d_nullMaskV : NULL
    );
    err = cudaGetLastError();
    if(err != cudaSuccess) { fprintf(stderr, "GPU: Kernel launch failed: %s\n", cudaGetErrorString(err)); goto cleanup; }

    if(!h_outputRowids) {
        err = cudaMemsetAsync(g_deviceScratch.d_matchCount, 0, sizeof(int), g_deviceScratch.computeStream);
        if(err != cudaSuccess) { fprintf(stderr, "GPU: Memset failed: %s\n", cudaGetErrorString(err)); goto cleanup; }
        countMatchesKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
            g_deviceScratch.d_resultMask, g_deviceScratch.d_matchCount, numRows
        );
        err = cudaGetLastError();
        if(err != cudaSuccess) { fprintf(stderr, "GPU: Count kernel failed: %s\n", cudaGetErrorString(err)); goto cleanup; }
        {
            int cnt = 0;
            err = cudaMemcpyAsync(&cnt, g_deviceScratch.d_matchCount, sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
            if(err != cudaSuccess) { fprintf(stderr, "GPU: D2H count failed: %s\n", cudaGetErrorString(err)); goto cleanup; }
            err = cudaStreamSynchronize(g_deviceScratch.computeStream);
            if(err != cudaSuccess) { fprintf(stderr, "GPU: Count sync failed: %s\n", cudaGetErrorString(err)); goto cleanup; }
            *h_outputCount = cnt;
        }
        goto cleanup;
    }

    if(gpuPrefixSum(g_deviceScratch.d_resultMask, g_deviceScratch.d_scanIndices,
                   g_deviceScratch.d_blockSums, g_deviceScratch.d_blockOffsets,
                   numRows, g_deviceScratch.computeStream) != 0) {
        goto cleanup;
    }

    {
        int lastScanIndex = 0, lastMask = 0;
        err = cudaMemcpyAsync(&lastScanIndex, g_deviceScratch.d_scanIndices + numRows - 1, sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
        if(err != cudaSuccess) goto cleanup;
        err = cudaMemcpyAsync(&lastMask, g_deviceScratch.d_resultMask + numRows - 1, sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
        if(err != cudaSuccess) goto cleanup;
        err = cudaStreamSynchronize(g_deviceScratch.computeStream);
        if(err != cudaSuccess) goto cleanup;
        resultCount = lastScanIndex + lastMask;
    }

    if(resultCount > 0) {
        compactRowidsKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
            g_deviceScratch.d_data, g_deviceScratch.d_output,
            g_deviceScratch.d_resultMask, g_deviceScratch.d_scanIndices, numRows, numColumns
        );
        err = cudaGetLastError();
        if(err != cudaSuccess) goto cleanup;
        {
            size_t outputSize = (size_t)resultCount * sizeof(long long);
            err = cudaMemcpyAsync(h_outputRowids, g_deviceScratch.d_output, outputSize, cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
            if(err != cudaSuccess) goto cleanup;
        }
    }
    err = cudaStreamSynchronize(g_deviceScratch.computeStream);
    if(err != cudaSuccess) goto cleanup;
    *h_outputCount = resultCount;

cleanup:
    return (err == cudaSuccess) ? 0 : -1;
}



__device__ inline void u128Add(unsigned long long& lo, unsigned long long& hi,
                               unsigned long long blo, unsigned long long bhi){
    unsigned long long oldLo = lo;
    lo += blo;
    hi += bhi + (lo < oldLo ? 1ULL : 0ULL);
}

__device__ inline void u128SetSigned(unsigned long long& lo, unsigned long long& hi,
                                    long long v){
    lo = (unsigned long long)v;
    hi = (v < 0) ? 0xFFFFFFFFFFFFFFFFULL : 0ULL;
}

__global__ void aggReduceKernel(
    const long long* data,
    const unsigned char* nullMask,
    const int* matchMask,
    const GpuAggSpec* aggSpecs,
    int numAggs,
    GpuAggPartial* partials,
    int numRows,
    int numColumns
) {
    __shared__ unsigned long long sLo[BLOCK_SIZE];
    __shared__ unsigned long long sHi[BLOCK_SIZE];
    __shared__ long long sMin[BLOCK_SIZE];
    __shared__ long long sMax[BLOCK_SIZE];
    __shared__ long long sCnt[BLOCK_SIZE];
    __shared__ unsigned int sHas[BLOCK_SIZE];

    int t = threadIdx.x;
    int idx = blockIdx.x * blockDim.x + t;
    int isMatch = (idx < numRows) ? matchMask[idx] : 0;
    const long long* row = data + ((long long)idx * numColumns);

    for(int a = 0; a < numAggs; a++){
        const GpuAggSpec sp = aggSpecs[a];
        int use = isMatch;
        int isNull = 0;
        if( use && sp.columnIndex >= 0 ){
            int bitIdx = idx * numColumns + sp.columnIndex;
            isNull = (nullMask[bitIdx >> 3] >> (bitIdx & 7)) & 1;
        }
        if( sp.columnIndex >= 0 && isNull ) use = 0;

        if( sp.type == GPU_AGG_COUNT_STAR || sp.type == GPU_AGG_COUNT_COL ){
            sLo[t] = 0;
            sHi[t] = 0;
            sMin[t] = 0;
            sMax[t] = 0;
            sHas[t] = 0;
            sCnt[t] = use ? 1 : 0;
        }else{
            /* sum / avg / min / max over the integer cell value */
            if( use ){
                u128SetSigned(sLo[t], sHi[t], row[sp.columnIndex]);
                sMin[t] = row[sp.columnIndex];
                sMax[t] = row[sp.columnIndex];
                sCnt[t] = 1;
                sHas[t] = 1;
            }else{
                sLo[t] = 0;
                sHi[t] = 0;
                sMin[t] = 0x7FFFFFFFFFFFFFFFLL;
                sMax[t] = 0x8000000000000000LL;
                sCnt[t] = 0;
                sHas[t] = 0;
            }
        }
        __syncthreads();

        for(int offset = BLOCK_SIZE / 2; offset > 0; offset /= 2){
            if( t < offset ){
                u128Add(sLo[t], sHi[t], sLo[t + offset], sHi[t + offset]);
                if( sMin[t + offset] < sMin[t] ) sMin[t] = sMin[t + offset];
                if( sMax[t + offset] > sMax[t] ) sMax[t] = sMax[t + offset];
                sCnt[t] += sCnt[t + offset];
                sHas[t] |= sHas[t + offset];
            }
            __syncthreads();
        }

        if( t == 0 ){
            GpuAggPartial o;
            o.sumLo = sLo[0];
            o.sumHi = sHi[0];
            o.minVal = sMin[0];
            o.maxVal = sMax[0];
            o.cnt = sCnt[0];
            o.hasAny = sHas[0];
            partials[blockIdx.x * numAggs + a] = o;
        }
        __syncthreads();
    }
}


__global__ void aggCombineKernel(
    const GpuAggPartial* partials,
    GpuAggPartial* out,
    int numBlocks,
    int numAggs
) {
    int a = threadIdx.x;
    if( a >= numAggs ) return;

    GpuAggPartial acc;
    acc.sumLo = 0;
    acc.sumHi = 0;
    acc.minVal = 0x7FFFFFFFFFFFFFFFLL;
    acc.maxVal = 0x8000000000000000LL;
    acc.cnt = 0;
    acc.hasAny = 0;

    for(int b = 0; b < numBlocks; b++){
        const GpuAggPartial p = partials[b * numAggs + a];
        u128Add(acc.sumLo, acc.sumHi, p.sumLo, p.sumHi);
        if( p.hasAny ){
            if( p.minVal < acc.minVal ) acc.minVal = p.minVal;
            if( p.maxVal > acc.maxVal ) acc.maxVal = p.maxVal;
        }
        acc.cnt += p.cnt;
        acc.hasAny |= p.hasAny;
    }
    out[a] = acc;
}

extern "C" int gpuWhereClauseAgg(
    const long long* h_data,
    const unsigned char* h_nullMask,
    long long* h_output,
    int* h_outputCount,
    const Condition* h_conditions,
    GpuAggPartial* h_aggOut,
    const GpuAggSpec* h_aggSpecs,
    int numAggs,
    int numRows,
    int numColumns,
    int numConditions,
    int rootConditionIndex,
    int wantRows
) {
    if(!g_gpuInitialized) {
        fprintf(stderr, "GPU: Not initialized\n");
        return -1;
    }
    if(!h_data || numAggs<=0 || numAggs>MAX_AGGREGATES) {
        fprintf(stderr, "GPU: Invalid agg parameters\n");
        return -1;
    }

    cudaError_t err = cudaSuccess;
    int numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    size_t dataSize = (size_t)numRows * (size_t)numColumns * sizeof(long long);
    size_t maskSize = (size_t)numRows * sizeof(int);
    size_t condSize = (size_t)numConditions * sizeof(Condition);
    size_t nullSize = ((size_t)numRows * (size_t)numColumns + 7) / 8;
    size_t specSize = (size_t)numAggs * sizeof(GpuAggSpec);
    size_t partialSize = (size_t)numBlocks * (size_t)numAggs * sizeof(GpuAggPartial);
    size_t aggOutSize = (size_t)numAggs * sizeof(GpuAggPartial);
    size_t blockSumsSize = (size_t)numBlocks * sizeof(int);
    int resultCount = 0;

    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_data, dataSize, &g_deviceScratch.dataCapacity, "device data") != 0) return -1;
    if(numConditions > 0){
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_conditions, condSize, &g_deviceScratch.conditionCapacity, "device conditions") != 0) return -1;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_nullMaskV, nullSize, &g_deviceScratch.nullCapacity, "device null mask") != 0) return -1;
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_aggSpecs, specSize, &g_deviceScratch.specCapacity, "device agg specs") != 0) return -1;
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_partials, partialSize, &g_deviceScratch.partialCapacity, "device agg partials") != 0) return -1;
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_aggOut, aggOutSize, &g_deviceScratch.aggOutCapacity, "device agg out") != 0) return -1;
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_resultMask, maskSize, &g_deviceScratch.maskCapacity, "device result mask") != 0) return -1;

    err = cudaMemcpyAsync(g_deviceScratch.d_data, h_data, dataSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
    if(err != cudaSuccess) goto cleanup;
    if(numConditions > 0){
        err = cudaMemcpyAsync(g_deviceScratch.d_conditions, h_conditions, condSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        if(err != cudaSuccess) goto cleanup;
    }
    if(h_nullMask && nullSize > 0){
        err = cudaMemcpyAsync(g_deviceScratch.d_nullMaskV, h_nullMask, nullSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        if(err != cudaSuccess) goto cleanup;
    }else if( nullSize > 0 ){
        err = cudaMemsetAsync(g_deviceScratch.d_nullMaskV, 0, nullSize, g_deviceScratch.transferStream);
        if(err != cudaSuccess) goto cleanup;
    }
    err = cudaMemcpyAsync(g_deviceScratch.d_aggSpecs, h_aggSpecs, specSize, cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
    if(err != cudaSuccess) goto cleanup;
    err = cudaStreamSynchronize(g_deviceScratch.transferStream);
    if(err != cudaSuccess) goto cleanup;

    whereClauseKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_data, g_deviceScratch.d_resultMask, g_deviceScratch.d_conditions,
        numRows, numColumns, rootConditionIndex, g_deviceScratch.d_nullMaskV
    );
    err = cudaGetLastError();
    if(err != cudaSuccess){ fprintf(stderr, "GPU: Agg where kernel failed: %s\n", cudaGetErrorString(err)); goto cleanup; }

    aggReduceKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_data,
        g_deviceScratch.d_nullMaskV,
        g_deviceScratch.d_resultMask,
        g_deviceScratch.d_aggSpecs,
        numAggs,
        g_deviceScratch.d_partials,
        numRows,
        numColumns
    );
    err = cudaGetLastError();
    if(err != cudaSuccess){ fprintf(stderr, "GPU: Agg reduce kernel failed: %s\n", cudaGetErrorString(err)); goto cleanup; }

    aggCombineKernel<<<1, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_partials, g_deviceScratch.d_aggOut, numBlocks, numAggs
    );
    err = cudaGetLastError();
    if(err != cudaSuccess){ fprintf(stderr, "GPU: Agg combine kernel failed: %s\n", cudaGetErrorString(err)); goto cleanup; }

    err = cudaMemcpyAsync(h_aggOut, g_deviceScratch.d_aggOut, aggOutSize, cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
    if(err != cudaSuccess) goto cleanup;

    if( wantRows && h_output && h_outputCount ){
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_output, dataSize, &g_deviceScratch.outputCapacity, "device output") != 0) return -1;
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_scanIndices, maskSize, &g_deviceScratch.scanCapacity, "device scan indices") != 0) return -1;
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_blockSums, blockSumsSize, &g_deviceScratch.blockSumsCapacity, "device block sums") != 0) return -1;
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_blockOffsets, blockSumsSize, &g_deviceScratch.blockOffsetsCapacity, "device block offsets") != 0) return -1;

        err = cudaStreamSynchronize(g_deviceScratch.computeStream);
        if(err != cudaSuccess) goto cleanup;

        if(gpuPrefixSum(g_deviceScratch.d_resultMask, g_deviceScratch.d_scanIndices,
                       g_deviceScratch.d_blockSums, g_deviceScratch.d_blockOffsets,
                       numRows, g_deviceScratch.computeStream) != 0) goto cleanup;

        {
            int lastScanIndex = 0, lastMask = 0;
            err = cudaMemcpyAsync(&lastScanIndex, g_deviceScratch.d_scanIndices + numRows - 1, sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
            if(err != cudaSuccess) goto cleanup;
            err = cudaMemcpyAsync(&lastMask, g_deviceScratch.d_resultMask + numRows - 1, sizeof(int), cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
            if(err != cudaSuccess) goto cleanup;
            err = cudaStreamSynchronize(g_deviceScratch.computeStream);
            if(err != cudaSuccess) goto cleanup;
            resultCount = lastScanIndex + lastMask;
        }

        if(resultCount > 0){
            compactResultsKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
                g_deviceScratch.d_data, g_deviceScratch.d_output,
                g_deviceScratch.d_resultMask, g_deviceScratch.d_scanIndices,
                numRows, numColumns
            );
            err = cudaGetLastError();
            if(err != cudaSuccess) goto cleanup;
            {
                size_t outputSize = (size_t)resultCount * (size_t)numColumns * sizeof(long long);
                err = cudaMemcpyAsync(h_output, g_deviceScratch.d_output, outputSize, cudaMemcpyDeviceToHost, g_deviceScratch.computeStream);
                if(err != cudaSuccess) goto cleanup;
            }
        }
        err = cudaStreamSynchronize(g_deviceScratch.computeStream);
        if(err != cudaSuccess) goto cleanup;
        *h_outputCount = resultCount;
    }else{
        err = cudaStreamSynchronize(g_deviceScratch.computeStream);
        if(err != cudaSuccess) goto cleanup;
        if( h_outputCount ) *h_outputCount = 0;
    }

    err = cudaSuccess;

cleanup:
    return (err == cudaSuccess) ? 0 : -1;
}
