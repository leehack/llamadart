# build_windows.ps1 <backend> [clean]
# Example: .\scripts\build_windows.ps1 vulkan

param (
    [string]$Backend = "vulkan",
    [string]$Clean = ""
)

$BuildDir = "build-windows-$Backend"

if ($Clean -eq "clean") {
    if (Test-Path $BuildDir) {
        Remove-Item -Path $BuildDir -Recurse -Force
    }
}

$CmakeArgs = @(
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=ON",
    "-DLLAMA_BUILD_COMMON=OFF",
    "-DLLAMA_BUILD_TESTS=OFF",
    "-DLLAMA_BUILD_EXAMPLES=OFF",
    "-DLLAMA_BUILD_SERVER=OFF",
    "-DLLAMA_BUILD_TOOLS=OFF",
    "-DGGML_CPU_ALL_VARIANTS=ON",
    "-DGGML_BACKEND_DL=ON"
)

if ($Backend -eq "vulkan") {
    Write-Host "============================"
    Write-Host "Building for Windows (Vulkan)"
    Write-Host "============================"
    $CmakeArgs += "-DGGML_VULKAN=ON"
} elseif ($Backend -eq "cuda") {
    Write-Host "=========================="
    Write-Host "Building for Windows (CUDA)"
    Write-Host "=========================="
    $CmakeArgs += "-DGGML_CUDA=ON"
} else {
    Write-Error "Invalid backend '$Backend'. Use 'vulkan' or 'cuda'."
    exit 1
}

if (-not (Test-Path $BuildDir)) {
    New-Item -Path $BuildDir -ItemType Directory
}

cmake -S src/native/llama_cpp -B $BuildDir @CmakeArgs
cmake --build $BuildDir --config Release -j 4

# Artifacts
$LibDir = "windows/lib"
if (Test-Path $LibDir) {
    Remove-Item -Path $LibDir -Recurse -Force
}
New-Item -Path $LibDir -ItemType Directory

Write-Host "Copying libraries to $LibDir (cleaning leftovers)..."
Get-ChildItem -Path $BuildDir -Filter *.dll -Recurse | Copy-Item -Destination $LibDir

Write-Host "Windows build complete: $LibDir"
