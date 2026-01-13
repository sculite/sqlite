#include "gpu_manager.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

extern int gpuWhereClauseInit(void);
extern void gpuWhereClauseCleanup(void);
extern int gpuWhereClause(
    const long long* h_data,
    long long* h_output,
    int* h_outputCount,
    const GpuCondition* h_conditions,
    int numRows,
    int numColumns,
    int numConditions,
    int rootConditionIndex
);

static int g_gpuInitialized = 0;
static int g_gpuAvailable = 0;

int gpuManagerInit(void) {
    if(g_gpuInitialized) {
        return g_gpuAvailable ? 0 : -1;
    }
    
    int result = gpuWhereClauseInit();
    g_gpuInitialized = 1;
    
    if(result == 0) {
        g_gpuAvailable = 1;
        return 0;
    } else {
        g_gpuAvailable = 0;
        return -1;
    }
}

void gpuManagerCleanup(void) {
    if(g_gpuInitialized && g_gpuAvailable) {
        gpuWhereClauseCleanup();
    }
    g_gpuInitialized = 0;
    g_gpuAvailable = 0;
}

int gpuManagerIsAvailable(void) {
    if(!g_gpuInitialized) {
        gpuManagerInit();
    }
    return g_gpuAvailable;
}

GpuWhereContext* gpuWhereContextCreate(int maxRows, int numColumns) {
    if(!gpuManagerIsAvailable()) {
        return NULL;
    }
    // If maxRows is not specified or too small/large, use the default batch size
    if(maxRows <= 0 || maxRows > GPU_DEFAULT_BATCH_SIZE) {
        maxRows = GPU_DEFAULT_BATCH_SIZE;
    }
    if(numColumns <= 0 || numColumns > GPU_MAX_COLUMNS) {
        return NULL;
    }
    GpuWhereContext* ctx = (GpuWhereContext*)malloc(sizeof(GpuWhereContext));
    if(!ctx) {
        return NULL;
    }
    memset(ctx, 0, sizeof(GpuWhereContext));
    ctx->dataBuffer = (long long*)malloc(maxRows * numColumns * sizeof(long long));
    if(!ctx->dataBuffer) {
        free(ctx);
        return NULL;
    }
    ctx->outputBuffer = (long long*)malloc(maxRows * numColumns * sizeof(long long));
    if(!ctx->outputBuffer) {
        free(ctx->dataBuffer);
        free(ctx);
        return NULL;
    }
    ctx->conditions = (GpuCondition*)malloc(GPU_MAX_CONDITIONS * sizeof(GpuCondition));
    if(!ctx->conditions) {
        free(ctx->outputBuffer);
        free(ctx->dataBuffer);
        free(ctx);
        return NULL;
    }
    ctx->maxRows = maxRows;
    ctx->numColumns = numColumns;
    ctx->numConditions = 0;
    ctx->rootConditionIndex = -1;
    ctx->numRows = 0;
    ctx->isInitialized = 1;
    ctx->gpuAvailable = 1;
    return ctx;
}

void gpuWhereContextDestroy(GpuWhereContext* ctx) {
    if(!ctx) return;
    
    if(ctx->dataBuffer) free(ctx->dataBuffer);
    if(ctx->outputBuffer) free(ctx->outputBuffer);
    if(ctx->conditions) free(ctx->conditions);
    free(ctx);
}

int gpuWhereContextAddCondition(GpuWhereContext* ctx, const GpuCondition* cond) {
    if(!ctx || !cond) return -1;
    if(ctx->numConditions >= GPU_MAX_CONDITIONS) return -1;
    
    memcpy(&ctx->conditions[ctx->numConditions], cond, sizeof(GpuCondition));
    return ctx->numConditions++;
}

int gpuWhereContextSetRootCondition(GpuWhereContext* ctx, int rootIndex) {
    if(!ctx) return -1;
    if(rootIndex < 0 || rootIndex >= ctx->numConditions) return -1;
    
    ctx->rootConditionIndex = rootIndex;
    return 0;
}

int gpuWhereContextSetData(GpuWhereContext* ctx, const long long* data, int numRows) {
    if(!ctx || !data) return -1;
    if(numRows <= 0 || numRows > ctx->maxRows) return -1;
    
    size_t dataSize = numRows * ctx->numColumns * sizeof(long long);
    memcpy(ctx->dataBuffer, data, dataSize);
    ctx->numRows = numRows;
    
    return 0;
}

int gpuWhereContextExecute(GpuWhereContext* ctx, long long** outputData, int* outputRows) {
    if(!ctx || !outputData || !outputRows) return -1;
    if(ctx->numRows <= 0) return -1;
    
    int resultCount = 0;
    int result = gpuWhereClause(
        ctx->dataBuffer,
        ctx->outputBuffer,
        &resultCount,
        ctx->conditions,
        ctx->numRows,
        ctx->numColumns,
        ctx->numConditions,
        ctx->rootConditionIndex
    );
    
    if(result != 0) {
        return -1;
    }
    
    *outputData = ctx->outputBuffer;
    *outputRows = resultCount;
    
    return 0;
}

int gpuShouldUseGPU(int numRows, int numColumns, int numConditions) {
    if(!gpuManagerIsAvailable()) return 0;
    if(numRows < GPU_MIN_ROWS_THRESHOLD) return 0;
    if(numColumns <= 0 || numColumns > GPU_MAX_COLUMNS) return 0;
    if(numConditions <= 0 || numConditions > GPU_MAX_CONDITIONS) return 0;
    
    return 1;
}
//Yes no comments, I cant