#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "SQLite CUDA GPU Accelerated Build"
echo "========================================"
echo

BUILD_DIR="build_gpu"
CUDA_ARCH="sm_89"

# ------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------

echo "[0/6] Checking build environment..."
echo

if ! command -v gcc >/dev/null 2>&1; then
    echo "ERROR: gcc not found"
    exit 1
fi

if ! command -v nvcc >/dev/null 2>&1; then
    echo "ERROR: nvcc not found"
    exit 1
fi

echo "GCC:"
gcc --version | head -n 1

echo
echo "CUDA:"
nvcc --version | tail -n 1

echo
echo "CUDA architecture: ${CUDA_ARCH}"

# Verify the GPU/driver if nvidia-smi is available.
if command -v nvidia-smi >/dev/null 2>&1; then
    echo
    echo "GPU:"
    nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader
fi

echo

# ------------------------------------------------------------
# Compiler flags
# ------------------------------------------------------------

# Linux/GCC equivalents of the newer build_gpu.bat flags.
# MSVC-only options such as /MT, /Ob3, /Oi, /Ot, /Oy, /GF, /Gy,
# /fp:fast and /W3 are translated to their closest GCC equivalents.

CFLAGS=(
    -O3
    -pthread
    -ffast-math
    -fomit-frame-pointer
    -Wall
    -DSQLITE_THREADSAFE=1
    -DSQLITE_ENABLE_COLUMN_METADATA=1
    -DSQLITE_ENABLE_FTS5=1
    -DSQLITE_ENABLE_GPU_SCAN=1
    -DNDEBUG
)

NVCC_FLAGS=(
    -O3
    "-arch=${CUDA_ARCH}"
    --use_fast_math
    --ptxas-options=-O3
    --extra-device-vectorization
    -lineinfo
    -allow-unsupported-compiler
    -diag-suppress=546
)

# ------------------------------------------------------------
# Build directory
# ------------------------------------------------------------

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# ------------------------------------------------------------
# Step 1: Generate SQLite amalgamation
# ------------------------------------------------------------

echo "========================================"
echo "[Step 1/6] Generating amalgamation files"
echo "========================================"
echo

if [[ ! -f "sqlite3.c" ]]; then
    cd ..

    make sqlite3.c sqlite3.h

    cd "${BUILD_DIR}"

    cp ../sqlite3.c .
    cp ../sqlite3.h .
    cp ../sqlite3ext.h .
    cp ../shell.c .
else
    echo "Amalgamation files already exist, skipping generation."
fi

echo

# ------------------------------------------------------------
# Step 2: Copy GPU source files
# ------------------------------------------------------------

echo "========================================"
echo "[Step 2/6] Copying GPU source files"
echo "========================================"
echo

cp ../src/gpu_where.cu .
cp ../src/gpu_manager.h .
cp ../src/gpu_manager.c .
cp ../src/gpu_config.h .

if [[ ! -f "gpu_where.cu" ]]; then
    echo "ERROR: gpu_where.cu not found"
    exit 1
fi

if [[ ! -f "gpu_manager.c" ]]; then
    echo "ERROR: gpu_manager.c not found"
    exit 1
fi

if [[ ! -f "gpu_manager.h" ]]; then
    echo "ERROR: gpu_manager.h not found"
    exit 1
fi

if [[ ! -f "gpu_config.h" ]]; then
    echo "ERROR: gpu_config.h not found"
    exit 1
fi

echo "GPU source files copied successfully."
echo

# ------------------------------------------------------------
# Step 3: Compile CUDA kernels
# ------------------------------------------------------------

echo "========================================"
echo "[Step 3/6] Compiling CUDA kernels"
echo "========================================"
echo

nvcc \
    "${NVCC_FLAGS[@]}" \
    -c gpu_where.cu \
    -o gpu_where.o

echo
echo "Successfully compiled CUDA kernels."
echo

# ------------------------------------------------------------
# Step 4: Compile GPU manager
# ------------------------------------------------------------

echo "========================================"
echo "[Step 4/6] Compiling GPU manager"
echo "========================================"
echo

gcc \
    "${CFLAGS[@]}" \
    -I/usr/local/cuda/include \
    -c gpu_manager.c \
    -o gpu_manager.o

echo
echo "Successfully compiled GPU manager."
echo

# ------------------------------------------------------------
# Step 5: Compile SQLite core
# ------------------------------------------------------------

echo "========================================"
echo "[Step 5/6] Compiling SQLite core"
echo "========================================"
echo

gcc \
    "${CFLAGS[@]}" \
    -DSQLITE_OMIT_GPU=0 \
    -I/usr/local/cuda/include \
    -c sqlite3.c \
    -o sqlite3.o

echo
echo "Successfully compiled SQLite core."
echo

# ------------------------------------------------------------
# Step 6: Compile shell and link
# ------------------------------------------------------------

echo "========================================"
echo "[Step 6/6] Compiling shell and linking"
echo "========================================"
echo

gcc \
    "${CFLAGS[@]}" \
    -DSQLITE_OMIT_GPU=0 \
    -I/usr/local/cuda/include \
    -c shell.c \
    -o shell.o

echo "Shell compiled successfully."
echo

gcc \
    -o sqlite3_gpu \
    shell.o \
    sqlite3.o \
    gpu_manager.o \
    gpu_where.o \
    -L/usr/local/cuda/lib64 \
    -lcudart \
    -ldl \
    -lpthread \
    -lm

echo
echo "========================================"
echo "Build completed successfully!"
echo "========================================"
echo
echo "Output:"
echo "  ${BUILD_DIR}/sqlite3_gpu"
echo
echo "To run:"
echo "  cd ${BUILD_DIR}"
echo "  ./sqlite3_gpu"
echo
