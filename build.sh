#!/usr/bin/env bash

set -euo pipefail

echo "========================================"
echo " SQLite CUDA GPU Accelerated Build"
echo "========================================"
echo

# ============================================================
# CONFIGURATION
# ============================================================

BUILD_DIR="build_gpu"
CUDA_ARCH="sm_89"
DEBUG="${DEBUG:-0}"

CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"

NVCC="${CUDA_HOME}/bin/nvcc"

if [[ ! -x "$NVCC" ]]; then
    echo "ERROR: nvcc not found at:"
    echo "  $NVCC"
    exit 1
fi

# Compiler flags
if [[ "$DEBUG" == "1" ]]; then
    NVCC_FLAGS=(
        -O0
        -g
        -G
        "-arch=${CUDA_ARCH}"
        -lineinfo
        -Xcompiler
        "-O0"
        -allow-unsupported-compiler
        -diag-suppress=546
    )

    C_FLAGS=(
        -O0
        -g3
        -fno-omit-frame-pointer
        -march=native
        -mtune=native
        -Wall
        -Wextra
        -DSQLITE_THREADSAFE=1
        -DSQLITE_ENABLE_COLUMN_METADATA=1
        -DSQLITE_ENABLE_FTS5=1
        -DSQLITE_ENABLE_GPU_SCAN=1
        -DSQLITE_OMIT_GPU=0
    )
    LINK_FLAGS=(-g)
else
    NVCC_FLAGS=(
        -O3
        "-arch=${CUDA_ARCH}"
        --use_fast_math
        --ptxas-options=-O3
        --extra-device-vectorization
        -lineinfo
        -Xcompiler
        "-O3"
        -allow-unsupported-compiler
        -diag-suppress=546
    )

    C_FLAGS=(
        -O3
        -march=native
        -mtune=native
        -fomit-frame-pointer
        -ffast-math
        -Wall
        -Wextra
        -DSQLITE_THREADSAFE=1
        -DSQLITE_ENABLE_COLUMN_METADATA=1
        -DSQLITE_ENABLE_FTS5=1
        -DSQLITE_ENABLE_GPU_SCAN=1
        -DSQLITE_OMIT_GPU=0
        -DNDEBUG
    )
    LINK_FLAGS=(-O3)
fi

# ============================================================
# CHECK DEPENDENCIES
# ============================================================

echo "[Check] Checking build dependencies..."
echo

if ! command -v gcc >/dev/null 2>&1; then
    echo "ERROR: gcc not found."
    exit 1
fi

if ! command -v g++ >/dev/null 2>&1; then
    echo "ERROR: g++ not found."
    exit 1
fi

if ! command -v make >/dev/null 2>&1; then
    echo "ERROR: make not found."
    exit 1
fi

if ! command -v "$NVCC" >/dev/null 2>&1; then
    echo "ERROR: nvcc not found."
    exit 1
fi

echo "gcc:"
gcc --version | head -1

echo "g++:"
g++ --version | head -1

echo "nvcc:"
"$NVCC" --version | tail -1

echo


# ============================================================
# CREATE BUILD DIRECTORY
# ============================================================

mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR"


# ============================================================
# STEP 1
# ============================================================

echo "[Step 1/6] Generating amalgamation files..."
echo

if [[ ! -f "sqlite3.c" ]]; then

    cd ..

    # Linux SQLite source tree.
    #
    # The Windows build uses:
    #
    #   nmake /f Makefile.msc sqlite3.c sqlite3.h
    #
    # On Linux, the normal Makefile generation path is:
    #   ./configure
    #   make sqlite3.c sqlite3.h
    #
    # But if the repository already contains the generated
    # amalgamation, this step is unnecessary.

    if [[ -f "Makefile" ]]; then

        make sqlite3.c sqlite3.h

    elif [[ -x "./configure" ]]; then

        echo "Generating SQLite Makefile..."

        ./configure

        make sqlite3.c sqlite3.h

    else

        echo "ERROR: Cannot generate SQLite amalgamation."
        echo "No Makefile or configure script found."
        exit 1
    fi

    if [[ ! -f "sqlite3.c" || ! -f "sqlite3.h" ]]; then
        echo "ERROR: Failed to generate amalgamation files."
        exit 1
    fi

    cp sqlite3.c "$BUILD_DIR/"
    cp sqlite3.h "$BUILD_DIR/"

    if [[ -f "sqlite3ext.h" ]]; then
        cp sqlite3ext.h "$BUILD_DIR/"
    fi

    if [[ -f "shell.c" ]]; then
        cp shell.c "$BUILD_DIR/"
    fi

    cd "$BUILD_DIR"

else

    echo "Amalgamation files already exist, skipping generation."

fi

echo


# ============================================================
# STEP 2
# ============================================================

echo "[Step 2/6] Copying GPU source files..."
echo

cp ../src/gpu_where.cu .
cp ../src/gpu_manager.h .
cp ../src/gpu_manager.c .
cp ../src/gpu_config.h .

if [[ ! -f "gpu_where.cu" ]]; then
    echo "ERROR: gpu_where.cu not found."
    exit 1
fi

if [[ ! -f "gpu_manager.c" ]]; then
    echo "ERROR: gpu_manager.c not found."
    exit 1
fi

if [[ ! -f "gpu_manager.h" ]]; then
    echo "ERROR: gpu_manager.h not found."
    exit 1
fi

if [[ ! -f "gpu_config.h" ]]; then
    echo "ERROR: gpu_config.h not found."
    exit 1
fi

echo "GPU source files copied successfully."
echo


# ============================================================
# STEP 3
# ============================================================

echo "[Step 3/6] Compiling CUDA kernels..."
echo

"$NVCC" \
    "${NVCC_FLAGS[@]}" \
    -I. \
    -c gpu_where.cu \
    -o gpu_where.o

echo "Successfully compiled CUDA kernels."
echo


# ============================================================
# STEP 4
# ============================================================

echo "[Step 4/6] Compiling GPU manager..."
echo

gcc \
    "${C_FLAGS[@]}" \
    -I"$CUDA_HOME/include" \
    -I. \
    -c gpu_manager.c \
    -o gpu_manager.o

echo "Successfully compiled GPU manager."
echo


# ============================================================
# STEP 5
# ============================================================

echo "[Step 5/6] Compiling SQLite core with GPU support..."
echo

gcc \
    "${C_FLAGS[@]}" \
    -I"$CUDA_HOME/include" \
    -I. \
    -c sqlite3.c \
    -o sqlite3.o

echo "Successfully compiled SQLite core."
echo


# ============================================================
# STEP 6
# ============================================================

echo "[Step 6/6] Compiling shell and linking final executable..."
echo

gcc \
    "${C_FLAGS[@]}" \
    -I"$CUDA_HOME/include" \
    -I. \
    -c shell.c \
    -o shell.o

echo "Successfully compiled SQLite shell."
echo


# ============================================================
# LINK
# ============================================================

"$NVCC" \
    -arch="$CUDA_ARCH" \
    "${LINK_FLAGS[@]}" \
    -o sqlite3_gpu \
    shell.o \
    sqlite3.o \
    gpu_manager.o \
    gpu_where.o \
    -L"$CUDA_HOME/lib64" \
    -lcudart \
    -lpthread \
    -ldl \
    -lm

echo


# ============================================================
# VERIFY
# ============================================================

if [[ ! -x "sqlite3_gpu" ]]; then
    echo "ERROR: Build completed but sqlite3_gpu was not created."
    exit 1
fi

echo "========================================"
echo " Build completed successfully!"
echo "========================================"
echo

echo "Output:"
echo "  ${BUILD_DIR}/sqlite3_gpu"
echo

echo "Binary:"
file sqlite3_gpu

echo

echo "CUDA dependencies:"
ldd sqlite3_gpu | grep -E 'cuda|cudart' || true

echo

echo "To test:"
echo "  cd ${BUILD_DIR}"
echo "  ./sqlite3_gpu"

echo

cd ..