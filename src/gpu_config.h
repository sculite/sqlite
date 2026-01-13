#ifndef GPU_CONFIG_H
#define GPU_CONFIG_H


#define GPU_MIN_ROWS_FOR_ACCELERATION 1000

#define GPU_MAX_COLUMNS_PER_QUERY 64

#define GPU_MAX_CONDITIONS_PER_QUERY 32

#define GPU_MAX_IN_VALUES 16

#define GPU_CUDA_BLOCK_SIZE 256

#define GPU_CUDA_COMPUTE_ARCH "sm_89"

#define GPU_DEFAULT_ENABLED 1

#define GPU_VERBOSE_LOGGING 0

#define GPU_BATCH_SIZE 10000000

#if GPU_VERBOSE_LOGGING
#define GPU_LOG(fmt, ...) fprintf(stderr, "[GPU] " fmt "\n", ##__VA_ARGS__)
#else
#define GPU_LOG(fmt, ...)
#endif

#endif 
