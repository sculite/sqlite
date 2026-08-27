#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <stdio.h>

#define BLOCK_SIZE 256
#define MAX_CONDITIONS 32

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

// Device function to evaluate a single condition on a row 
__device__ int evaluateCondition(const long long* row, const Condition* cond, const Condition* allConds, int numColumns) {
    long long colValue;
    int i;
    
    switch(cond->opCode) {
        case OP_EQ:
            colValue = row[cond->columnIndex];
            return colValue == cond->value1;
            
        case OP_NE:
            colValue = row[cond->columnIndex];
            return colValue != cond->value1;
            
        case OP_LT:
            colValue = row[cond->columnIndex];
            return colValue < cond->value1;
            
        case OP_LE:
            colValue = row[cond->columnIndex];
            return colValue <= cond->value1;
            
        case OP_GT:
            colValue = row[cond->columnIndex];
            return colValue > cond->value1;
            
        case OP_GE:
            colValue = row[cond->columnIndex];
            return colValue >= cond->value1;
            
        case OP_BETWEEN:
            colValue = row[cond->columnIndex];
            return (colValue >= cond->value1) && (colValue <= cond->value2);
            
        case OP_IN:
            colValue = row[cond->columnIndex];
            for(i = 0; i < cond->valueCount && i < 16; i++) {
                if(colValue == cond->inValues[i]) {
                    return 1;
                }
            }
            return 0;
            
        case OP_AND:
            if(cond->leftChild >= 0 && cond->rightChild >= 0) {
                return evaluateCondition(row, &allConds[cond->leftChild], allConds, numColumns) &&
                       evaluateCondition(row, &allConds[cond->rightChild], allConds, numColumns);
            }
            return 0;
            
        case OP_OR:
            if(cond->leftChild >= 0 && cond->rightChild >= 0) {
                return evaluateCondition(row, &allConds[cond->leftChild], allConds, numColumns) ||
                       evaluateCondition(row, &allConds[cond->rightChild], allConds, numColumns);
            }
            return 0;
            
        case OP_NOT:
            if(cond->leftChild >= 0) {
                return !evaluateCondition(row, &allConds[cond->leftChild], allConds, numColumns);
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
    int rootConditionIndex
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if(idx < numRows) {
        const long long* row = data + (idx * numColumns);
        
        if(rootConditionIndex >= 0) {
            resultMask[idx] = evaluateCondition(row, &conditions[rootConditionIndex], conditions, numColumns);
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
    int rootConditionIndex
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
        rootConditionIndex
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
    int rootConditionIndex
) {
    return gpuWhereClause(
        h_data,
        NULL,
        h_outputCount,
        h_conditions,
        numRows,
        numColumns,
        numConditions,
        rootConditionIndex
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
    int rootConditionIndex
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

    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_data, dataSize, &g_deviceScratch.dataCapacity, "device data") != 0) {
        return -1;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_resultMask, maskSize, &g_deviceScratch.maskCapacity, "device result mask") != 0) {
        return -1;
    }
    if(ensureDeviceBuffer((void**)&g_deviceScratch.d_matchCount, sizeof(int), &g_deviceScratch.matchCountCapacity, "device match count") != 0) {
        return -1;
    }
    if(numConditions > 0) {
        if(ensureDeviceBuffer((void**)&g_deviceScratch.d_conditions, condSize, &g_deviceScratch.conditionCapacity, "device conditions") != 0) {
            return -1;
        }
    }

    /* Wait for previous batch's kernel to finish before overwriting the
    ** shared device data buffer. This serializes GPU kernels across batches
    ** while still allowing the CPU to fill the next host buffer in parallel. */
    err = cudaStreamSynchronize(g_deviceScratch.computeStream);
    if(err != cudaSuccess) return -1;

    /* Async H2D transfer of row data */
    err = cudaMemcpyAsync(g_deviceScratch.d_data, h_data, dataSize,
                          cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
    if(err != cudaSuccess) return -1;

    /* Async H2D transfer of conditions */
    if(numConditions > 0) {
        err = cudaMemcpyAsync(g_deviceScratch.d_conditions, h_conditions, condSize,
                              cudaMemcpyHostToDevice, g_deviceScratch.transferStream);
        if(err != cudaSuccess) return -1;
    }

    /* Wait for H2D transfers to complete before launching kernel */
    err = cudaStreamSynchronize(g_deviceScratch.transferStream);
    if(err != cudaSuccess) return -1;

    /* Launch filter kernel on compute stream */
    int numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    whereClauseKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_data,
        g_deviceScratch.d_resultMask,
        g_deviceScratch.d_conditions,
        numRows,
        numColumns,
        rootConditionIndex
    );
    if(cudaGetLastError() != cudaSuccess) return -1;

    /* Zero match count */
    err = cudaMemsetAsync(g_deviceScratch.d_matchCount, 0, sizeof(int), g_deviceScratch.computeStream);
    if(err != cudaSuccess) return -1;

    /* Launch count kernel on compute stream */
    countMatchesKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_resultMask,
        g_deviceScratch.d_matchCount,
        numRows
    );
    if(cudaGetLastError() != cudaSuccess) return -1;

    /* Kernel launched asynchronously — return without waiting */
    return 0;
}

extern "C" int gpuWhereClauseCountCollect(int* h_outputCount) {
    if(!h_outputCount) return -1;

    /* D2H transfer of count (tiny, 4 bytes) */
    cudaError_t err = cudaMemcpyAsync(h_outputCount, g_deviceScratch.d_matchCount,
                                       sizeof(int), cudaMemcpyDeviceToHost,
                                       g_deviceScratch.computeStream);
    if(err != cudaSuccess) return -1;

    /* Block until count is available */
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
    int rootConditionIndex
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
    err = cudaStreamSynchronize(g_deviceScratch.transferStream);
    if(err != cudaSuccess) { fprintf(stderr, "GPU: Transfer sync failed: %s\n", cudaGetErrorString(err)); goto cleanup; }

    numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    whereClauseKernel<<<numBlocks, BLOCK_SIZE, 0, g_deviceScratch.computeStream>>>(
        g_deviceScratch.d_data, g_deviceScratch.d_resultMask, g_deviceScratch.d_conditions,
        numRows, numColumns, rootConditionIndex
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
