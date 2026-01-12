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


__global__ void scanKernel(const int* input, int* output, int n) {
    extern __shared__ int temp[];
    
    int thid = threadIdx.x;
    int globalIdx = blockIdx.x * blockDim.x + threadIdx.x;
    
    int pout = 0, pin = 1;
    
    if(globalIdx < n) {
        temp[thid] = input[globalIdx];
    } else {
        temp[thid] = 0;
    }
    __syncthreads();
    
    for(int offset = 1; offset < blockDim.x; offset *= 2) {
        pout = 1 - pout;
        pin = 1 - pout;
        
        if(thid >= offset) {
            temp[pout * blockDim.x + thid] = temp[pin * blockDim.x + thid] + temp[pin * blockDim.x + thid - offset];
        } else {
            temp[pout * blockDim.x + thid] = temp[pin * blockDim.x + thid];
        }
        __syncthreads();
    }
    
    if(globalIdx < n) {
        output[globalIdx] = temp[pout * blockDim.x + thid];
    }
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
    
    fprintf(stderr, "GPU: Initialized CUDA device: %s\n", prop.name);
    fprintf(stderr, "GPU: Compute capability: %d.%d\n", prop.major, prop.minor);
    fprintf(stderr, "GPU: Total memory: %.2f GB\n", prop.totalGlobalMem / (1024.0*1024.0*1024.0));
    
    g_gpuInitialized = 1;
    return 0;
}


extern "C" void gpuWhereClauseCleanup(void) {
    if(g_gpuInitialized) {
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
    
    if(!h_data || !h_output || !h_outputCount) {
        fprintf(stderr, "GPU: Invalid parameters\n");
        return -1;
    }
    
    cudaError_t err;
    

    long long* d_data = NULL;
    long long* d_output = NULL;
    Condition* d_conditions = NULL;
    int* d_resultMask = NULL;
    int* d_scanIndices = NULL;
    int* h_resultMask = NULL;
    int* h_scanIndices = NULL;
    
    size_t dataSize = numRows * numColumns * sizeof(long long);
    size_t maskSize = numRows * sizeof(int);
    size_t condSize = numConditions * sizeof(Condition);
    
    err = cudaMalloc(&d_data, dataSize);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to allocate device data: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    err = cudaMalloc(&d_output, dataSize);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to allocate device output: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    err = cudaMalloc(&d_conditions, condSize);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to allocate device conditions: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    err = cudaMalloc(&d_resultMask, maskSize);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to allocate result mask: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    err = cudaMalloc(&d_scanIndices, maskSize);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to allocate scan indices: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    h_resultMask = (int*)malloc(maskSize);
    h_scanIndices = (int*)malloc(maskSize);
    if(!h_resultMask || !h_scanIndices) {
        fprintf(stderr, "GPU: Failed to allocate host memory\n");
        goto cleanup;
    }
    
    //Copy data to CUDA device
    err = cudaMemcpy(d_data, h_data, dataSize, cudaMemcpyHostToDevice);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to copy data to device: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    if(numConditions > 0) {
        err = cudaMemcpy(d_conditions, h_conditions, condSize, cudaMemcpyHostToDevice);
        if(err != cudaSuccess) {
            fprintf(stderr, "GPU: Failed to copy conditions to device: %s\n", cudaGetErrorString(err));
            goto cleanup;
        }
    }
    
    //Exec the WHERE kernel
    int numBlocks = (numRows + BLOCK_SIZE - 1) / BLOCK_SIZE;
    whereClauseKernel<<<numBlocks, BLOCK_SIZE>>>(
        d_data, d_resultMask, d_conditions, numRows, numColumns, rootConditionIndex
    );
    
    err = cudaGetLastError();
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Kernel launch failed: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    err = cudaDeviceSynchronize();
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Kernel execution failed: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    

    err = cudaMemcpy(h_resultMask, d_resultMask, maskSize, cudaMemcpyDeviceToHost);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to copy result mask: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    

    cpuPrefixSum(h_resultMask, h_scanIndices, numRows);
    
    int resultCount = h_scanIndices[numRows-1] + h_resultMask[numRows-1];
    

    err = cudaMemcpy(d_scanIndices, h_scanIndices, maskSize, cudaMemcpyHostToDevice);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to copy scan indices: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    

    compactResultsKernel<<<numBlocks, BLOCK_SIZE>>>(
        d_data, d_output, d_resultMask, d_scanIndices, numRows, numColumns
    );
    
    err = cudaGetLastError();
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Compact kernel launch failed: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    err = cudaDeviceSynchronize();
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Compact kernel execution failed: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    

    size_t outputSize = resultCount * numColumns * sizeof(long long);
    err = cudaMemcpy(h_output, d_output, outputSize, cudaMemcpyDeviceToHost);
    if(err != cudaSuccess) {
        fprintf(stderr, "GPU: Failed to copy results: %s\n", cudaGetErrorString(err));
        goto cleanup;
    }
    
    *h_outputCount = resultCount;
    
    //YES i know, goto cleanup, let me be man
cleanup:
    if(d_data) cudaFree(d_data);
    if(d_output) cudaFree(d_output);
    if(d_conditions) cudaFree(d_conditions);
    if(d_resultMask) cudaFree(d_resultMask);
    if(d_scanIndices) cudaFree(d_scanIndices);
    if(h_resultMask) free(h_resultMask);
    if(h_scanIndices) free(h_scanIndices);
    
    return (err == cudaSuccess) ? 0 : -1;
}
