@echo off
setlocal enabledelayedexpansion

echo ========================================
echo SQLite CUDA GPU Accelerated Build
echo ========================================
echo.

set BUILD_DIR=build_gpu
set CUDA_ARCH=sm_89

set NVCC_FLAGS=-O3 ^
-arch=%CUDA_ARCH% ^
--use_fast_math ^
--ptxas-options=-O3 ^
--extra-device-vectorization ^
-lineinfo ^
-Xcompiler "/MT /O2 /Ob3 /Oi /Ot /fp:fast /W3" ^
-allow-unsupported-compiler ^
-diag-suppress=546

set CL_FLAGS=/MT /O2 /Ob3 /Oi /Ot /Oy /GF /Gy /fp:fast /W3 ^
/D SQLITE_THREADSAFE=1 ^
/D SQLITE_ENABLE_COLUMN_METADATA=1 ^
/D SQLITE_ENABLE_FTS5=1 ^
/D SQLITE_ENABLE_GPU_SCAN=1 ^
/D NDEBUG

set LINK_FLAGS=/INCREMENTAL:NO /OPT:REF /OPT:ICF /MACHINE:X64


if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd "%BUILD_DIR%"

echo [Step 1/6] Generating amalgamation files...
echo.

if not exist "sqlite3.c" (
    cd ..
    nmake /f Makefile.msc sqlite3.c sqlite3.h
    if errorlevel 1 (
        echo ERROR: Failed to generate amalgamation files
        exit /b 1
    )
    copy sqlite3.c "%BUILD_DIR%\" >nul
    copy sqlite3.h "%BUILD_DIR%\" >nul
    copy sqlite3ext.h "%BUILD_DIR%\" >nul
    copy shell.c "%BUILD_DIR%\" >nul
    cd "%BUILD_DIR%"
) else (
    echo Amalgamation files already exist, skipping generation.
)

echo [Step 2/6] Copying GPU source files...
echo.

copy ..\src\gpu_where.cu . >nul 2>&1
copy ..\src\gpu_manager.h . >nul 2>&1
copy ..\src\gpu_manager.c . >nul 2>&1
copy ..\src\gpu_config.h . >nul 2>&1

if not exist "gpu_where.cu" (
    echo ERROR: GPU source files not found
    exit /b 1
)

echo [Step 3/6] Compiling CUDA kernels...
echo.

nvcc %NVCC_FLAGS% -c gpu_where.cu -o gpu_where.obj
if errorlevel 1 (
    echo ERROR: CUDA kernel compilation failed
    exit /b 1
)

echo Successfully compiled CUDA kernels
echo.

echo [Step 4/6] Compiling GPU manager...
echo.

cl %CL_FLAGS% /I"%CUDA_PATH%\include" /c gpu_manager.c
if errorlevel 1 (
    echo ERROR: GPU manager compilation failed
    exit /b 1
)

echo Successfully compiled GPU manager
echo.

echo [Step 5/6] Compiling SQLite core with GPU support...
echo.

cl %CL_FLAGS% /D SQLITE_OMIT_GPU=0 /I"%CUDA_PATH%\include" /c sqlite3.c
if errorlevel 1 (
    echo ERROR: SQLite core compilation failed
    exit /b 1
)

echo Successfully compiled SQLite core
echo.

echo [Step 6/6] Compiling shell and linking final executable...
echo.

cl %CL_FLAGS% /D SQLITE_OMIT_GPU=0 /I"%CUDA_PATH%\include" /c shell.c
if errorlevel 1 (
    echo ERROR: Shell compilation failed
    exit /b 1
)

link %LINK_FLAGS% /OUT:sqlite3_gpu.exe ^
    shell.obj ^
    sqlite3.obj ^
    gpu_manager.obj ^
    gpu_where.obj ^
    "%CUDA_PATH%\lib\x64\cudart.lib" ^
    kernel32.lib user32.lib advapi32.lib

if errorlevel 1 (
    echo ERROR: Linking failed
    exit /b 1
)

echo.
echo ========================================
echo Build completed successfully!
echo ========================================
echo.
echo Output: %BUILD_DIR%\sqlite3_gpu.exe
echo.
echo To test:
echo   cd %BUILD_DIR%
echo   sqlite3_gpu.exe
echo.

cd ..
endlocal
