#ifndef GPU_MANAGER_H
#define GPU_MANAGER_H

#include "gpu_config.h"

#ifdef __cplusplus
extern "C" {
#endif

#define GPU_MIN_ROWS_THRESHOLD GPU_MIN_ROWS_FOR_ACCELERATION
#define GPU_MAX_COLUMNS GPU_MAX_COLUMNS_PER_QUERY
#define GPU_MAX_CONDITIONS GPU_MAX_CONDITIONS_PER_QUERY
#define GPU_DEFAULT_BATCH_SIZE GPU_BATCH_SIZE


typedef enum {
    GPU_OP_EQ = 0,      
    GPU_OP_NE = 1,      
    GPU_OP_LT = 2,      
    GPU_OP_LE = 3,     
    GPU_OP_GT = 4,   
    GPU_OP_GE = 5,      
    GPU_OP_AND = 6,     
    GPU_OP_OR = 7,      
    GPU_OP_NOT = 8,     
    GPU_OP_BETWEEN = 9, 
    GPU_OP_IN = 10      
} GpuOpCode;

// Aggregate term types and match the values used in GpuAggSpec.type
#define GPU_AGG_COUNT_STAR 0   
#define GPU_AGG_COUNT_COL  1   
#define GPU_AGG_SUM        2   
#define GPU_AGG_AVG        3   
#define GPU_AGG_MIN        4   
#define GPU_AGG_MAX        5  


typedef struct GpuAggSpec {
    int type;             
    int columnIndex;     
} GpuAggSpec;


typedef struct GpuAggPartial {
    unsigned long long sumLo;  
    unsigned long long sumHi;  
    long long minVal;          
    long long maxVal;          
    long long cnt;             
    unsigned int hasAny;       
} GpuAggPartial;


typedef struct GpuCondition {
    int opCode;              /* Operation code from GpuOpCode enum */
    int columnIndex;         /* Index of the column being compared */
    long long value1;        /* Primary comparison value */
    long long value2;        /* Secondary value (for BETWEEN) */
    int valueCount;          /* Number of values in inValues array (for IN) */
    long long inValues[16];  /* Array of values for IN operator */
    int leftChild;           /* Index of left child condition (for AND/OR/NOT) */
    int rightChild;          /* Index of right child condition (for AND/OR) */
} GpuCondition;

typedef struct GpuWhereContext {
    long long* dataBuffer;      /* Host buffer for table data */
    long long* outputBuffer;    /* Host buffer for filtered results */
    GpuCondition* conditions;   /* Array of WHERE conditions */
    int numConditions;          /* Number of conditions */
    int rootConditionIndex;     /* Index of root condition in tree */
    int numRows;                /* Number of rows in input */
    int numColumns;             /* Number of columns in table */
    int maxRows;                /* Maximum capacity of buffers */
    int isInitialized;          /* Initialization flag */
    int gpuAvailable;           /* GPU availability flag */
    const unsigned char* nullMask;
} GpuWhereContext;

int gpuManagerInit(void);

void gpuManagerCleanup(void);

int gpuManagerIsAvailable(void);

GpuWhereContext* gpuWhereContextCreate(int maxRows, int numColumns);

void gpuWhereContextDestroy(GpuWhereContext* ctx);

int gpuWhereContextAddCondition(GpuWhereContext* ctx, const GpuCondition* cond);

int gpuWhereContextSetRootCondition(GpuWhereContext* ctx, int rootIndex);

int gpuWhereContextSetData(GpuWhereContext* ctx, const long long* data, int numRows);

int gpuWhereContextSetNullMask(GpuWhereContext* ctx, const unsigned char* nullMask);

int gpuWhereContextExecute(GpuWhereContext* ctx, long long** outputData, int* outputRows);

int gpuWhereContextCount(GpuWhereContext* ctx, int* outputRows);

int gpuWhereContextRowids(GpuWhereContext* ctx, long long** outputRowids, int* outputRows);

int gpuWhereContextSubmitCount(GpuWhereContext* ctx, const long long* data, int numRows);
int gpuWhereContextCollectCount(int* outputRows);

int gpuWhereContextAggExecute(
    GpuWhereContext* ctx,
    const unsigned char* h_nullMask,
    long long** h_outputData,
    int* h_outputRows,
    GpuAggPartial* h_aggOut,   
    const GpuAggSpec* aggSpecs,
    int numAggs,
    int wantRows
);

int gpuShouldUseGPU(int numRows, int numColumns, int numConditions);

#ifdef __cplusplus
}
#endif

#endif
