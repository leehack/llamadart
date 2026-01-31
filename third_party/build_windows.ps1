# build_windows.ps1 <backend> [clean]
# Example: .\scripts\build_windows.ps1 vulkan

param (
    [string]$Backend = "vulkan",
    [string]$Clean = "",
    [string]$VulkanSdk = ""
)

$BuildDir = if ($Backend -eq "vulkan") { "build-vulkan" } else { "build-cpu" }
if ($Clean -eq "clean") {
    if (Test-Path $BuildDir) {
        Remove-Item -Path $BuildDir -Recurse -Force
    }
}

$CmakeArgs = @(
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DLLAMA_BUILD_COMMON=OFF",
    "-DLLAMA_BUILD_TESTS=OFF",
    "-DLLAMA_BUILD_EXAMPLES=OFF",
    "-DLLAMA_BUILD_SERVER=OFF",
    "-DLLAMA_BUILD_TOOLS=OFF",
    "-DLLAMA_HTTPLIB=OFF",
    "-DLLAMA_OPENSSL=OFF"
)

if ($Backend -eq "vulkan") {
    Write-Host "============================"
    Write-Host "Building for Windows (Vulkan)"
    Write-Host "============================"
    
    # 1. Handle explicit SDK path from parameter
    if ($VulkanSdk -ne "") {
        $env:VULKAN_SDK = $VulkanSdk
        Write-Host "Using explicitly provided Vulkan SDK: $env:VULKAN_SDK"
    } 

    # 2. If not set, try to auto-detect from glslc.exe in PATH
    if (-not $env:VULKAN_SDK) {
        Write-Host "Checking for glslc.exe in PATH to auto-detect Vulkan SDK..."
        $Glslc = Get-Command glslc.exe -ErrorAction SilentlyContinue
        if ($Glslc) {
            $GlslcPath = $Glslc.Source.Replace('\', '/')
            Write-Host "Found glslc.exe: $GlslcPath"
            
            $SdkBin = [System.IO.Path]::GetDirectoryName($Glslc.Source)
            $SdkRoot = [System.IO.Path]::GetDirectoryName($SdkBin)
            
            # Verify structure
            if ((Test-Path "$SdkRoot/Include/vulkan/vulkan.h") -or (Test-Path "$SdkRoot/Lib/vulkan-1.lib")) {
                $env:VULKAN_SDK = $SdkRoot
                Write-Host "Auto-detected Vulkan SDK root: $env:VULKAN_SDK"
            } else {
                Write-Warning "Found glslc.exe but could not verify SDK root structure at $SdkRoot"
            }
        } else {
            Write-Warning "glslc.exe not found in PATH."
        }
    }
    
    # 3. Configure CMake with explicit Vulkan_ROOT hint and Debugging
    if ($env:VULKAN_SDK) {
        # Sanitize path for CMake (forward slashes)
        $env:VULKAN_SDK = $env:VULKAN_SDK.Replace('\', '/')
        $SdkRoot = $env:VULKAN_SDK
        Write-Host "Configuring CMake with Vulkan SDK root: $SdkRoot"
        
        # DEBUG: List SDK contents to verify layout
        Write-Host "--- SDK Directory Layout (Depth 2) ---"
        Get-ChildItem -Path $SdkRoot -Depth 2 -ErrorAction SilentlyContinue | Select-Object FullName | Format-Table -HideTableHeaders
        Write-Host "--------------------------------------"

        $CmakeArgs += "-DVulkan_ROOT=$SdkRoot"
        $CmakeArgs += "-DVulkan_INCLUDE_DIR=$SdkRoot/Include"

        # Prioritize 64-bit library in 'Lib' folder
        $VulkanLib = Get-ChildItem -Path "$SdkRoot/Lib" -Filter "vulkan-1.lib" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if (-not $VulkanLib) {
            # Retry generic search if not in Lib
            $VulkanLib = Get-ChildItem -Path $SdkRoot -Filter "vulkan-1.lib" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        }

        if ($VulkanLib) {
             $VPath = $VulkanLib.FullName.Replace('\', '/')
             Write-Host "Found vulkan-1.lib at $VPath"
             $CmakeArgs += "-DVulkan_LIBRARY=$VPath"
        } else {
             # Fallback to vulkan.lib
             $VulkanLibLegacy = Get-ChildItem -Path $SdkRoot -Filter "vulkan.lib" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
             if ($VulkanLibLegacy) {
                 $VPath = $VulkanLibLegacy.FullName.Replace('\', '/')
                 Write-Host "Found vulkan.lib at $VPath"
                 $CmakeArgs += "-DVulkan_LIBRARY=$VPath"
             } else {
                 Write-Warning "Could NOT find vulkan-1.lib or vulkan.lib in SDK!"
             }
        }
        
        # Explicitly find glslc
        $GlslcExe = Get-ChildItem -Path $SdkRoot -Filter "glslc.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($GlslcExe) {
             $GPath = $GlslcExe.FullName.Replace('\', '/')
             Write-Host "Found glslc.exe at $GPath"
             $CmakeArgs += "-DVulkan_GLSLC_EXECUTABLE=$GPath"
        } else {
             Write-Warning "Could NOT find glslc.exe in SDK!"
        }
    }
    
    if (-not $env:VULKAN_SDK) {
         Write-Warning "VULKAN_SDK environment variable is not set. CMake might fail."
    } else {
         Write-Host "VULKAN_SDK: $env:VULKAN_SDK"
    }

    $CmakeArgs += "-DGGML_VULKAN=ON"
} elseif ($Backend -eq "cpu") {
    Write-Host "============================"
    Write-Host "Building for Windows (CPU)"
    Write-Host "============================"
} else {
    Write-Error "Invalid backend '$Backend'. Use 'vulkan' or 'cpu'."
    exit 1
}

if (-not (Test-Path $BuildDir)) {
    New-Item -Path $BuildDir -ItemType Directory
}

# Helper to source VS environment
function Invoke-VCVars64 {
    param([string]$BatchFile)
    Write-Host "Sourcing Visual Studio environment from $BatchFile..."
    $tempFile = [IO.Path]::GetTempFileName()
    cmd /c " `"$BatchFile`" && set > `"$tempFile`" "
    Get-Content $tempFile | Foreach-Object {
        if ($_ -match "^(.*?)=(.*)$") {
            Set-Item -Path "env:$($matches[1])" -Value $matches[2]
        }
    }
    Remove-Item $tempFile
}

function Get-VCVarsPath {
    $PossiblePaths = @(
        "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
    )
    foreach ($Path in $PossiblePaths) {
        if (Test-Path $Path) { return $Path }
    }
    return $null
}

# Source VS environment if cl.exe is not in PATH
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $VCVars = Get-VCVarsPath
    if ($VCVars) {
        Invoke-VCVars64 $VCVars
    } else {
        Write-Warning "Could not find vcvars64.bat. Build might fail if compiler is not in PATH."
    }
}

# Helper to find CMake if not in PATH
function Get-CMake {
    $CmakeCmd = Get-Command "cmake" -ErrorAction SilentlyContinue
    if ($CmakeCmd) {
        return "cmake"
    }

    # Common locations (Scoop, VS)
    $PossiblePaths = @(
        "$env:USERPROFILE\scoop\apps\cmake\current\bin\cmake.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    )

    foreach ($Path in $PossiblePaths) {
        if (Test-Path $Path) {
            return $Path
        }
    }
    return $null
}

# Helper to find ccache
function Get-Ccache {
    $CcacheCmd = Get-Command "ccache" -ErrorAction SilentlyContinue
    if ($CcacheCmd) {
        return "ccache"
    }
    return $null
}

$CcacheExe = Get-Ccache
if ($CcacheExe) {
    Write-Host "Found ccache: $CcacheExe"
    $CmakeArgs += "-DCMAKE_C_COMPILER_LAUNCHER=$CcacheExe"
    $CmakeArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER=$CcacheExe"
} else {
    Write-Warning "ccache not found. Build will not be cached."
}

$CmakeExe = Get-CMake
if (-not $CmakeExe) {
    Write-Error "CMake not found in PATH or standard locations."
    exit 1
}
Write-Host "Using CMake: $CmakeExe"
# Point to src/native (parent of llama_cpp)
& "$CmakeExe" -G Ninja -S . -B $BuildDir @CmakeArgs
if ($LASTEXITCODE -ne 0) { Write-Error "CMake configure failed with exit code $LASTEXITCODE"; exit 1 }

Write-Host "Running CMake build..."
& "$CmakeExe" --build $BuildDir -j 8
if ($LASTEXITCODE -ne 0) { Write-Error "CMake build failed with exit code $LASTEXITCODE"; exit 1 }

# Artifacts
Write-Host "Processing artifacts..."
$LibDir = "bin/windows/x64"
if (Test-Path $LibDir) {
    Remove-Item -Path $LibDir -Recurse -Force
}
New-Item -Path $LibDir -ItemType Directory -Force

Write-Host "Copying libraries to $LibDir (cleaning leftovers)..."
# Copy dlls
Get-ChildItem -Path $BuildDir -Filter *.dll -Recurse | ForEach-Object {
    $Name = $_.Name
    $DestName = if ($Name -eq "llamadart.dll") { "libllamadart.dll" } else { $Name }
    $DestPath = Join-Path $LibDir $DestName
    
    # Avoid copying the same file multiple times
    if (-not (Test-Path $DestPath)) {
        Copy-Item -Path $_.FullName -Destination $DestPath -Force
        Write-Host "Copied $Name to $DestPath"
    }
}

Write-Host "Windows build complete: $LibDir\libllamadart.dll"
