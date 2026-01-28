cmake_minimum_required(VERSION 3.10)
project(llamadart_android LANGUAGES C CXX)

# Ensure llama.cpp builds as a shared library and exports symbols
set(BUILD_SHARED_LIBS ON CACHE BOOL "Build shared libraries" FORCE)

set(CMAKE_CXX_VISIBILITY_PRESET default)
set(CMAKE_VISIBILITY_INLINES_HIDDEN OFF)

# =============================================================================
# GPU Backend Configuration for Android
# Vulkan is ENABLED by default. Use -DLLAMA_DART_NO_VULKAN=ON to disable.
# =============================================================================

# Force default to OFF if not set, to prevent accidental disabling
if(NOT DEFINED LLAMA_DART_NO_VULKAN)
    set(LLAMA_DART_NO_VULKAN OFF CACHE BOOL "Disable Vulkan GPU backend" FORCE)
endif()
option(LLAMA_DART_NO_VULKAN "Disable Vulkan GPU backend" OFF)

if(NOT LLAMA_DART_NO_VULKAN)
    # Android NDK provides Vulkan headers/libs automatically, but FindVulkan.cmake
    # often struggles to find them in the NDK layout without help.

    # 1. Find glslc (needed by ggml-vulkan)
    if(ANDROID_NDK)
        # Try finding glslc in the NDK shader-tools
        file(GLOB_RECURSE NDK_GLSLC_MATCHES "${ANDROID_NDK}/shader-tools/*/glslc" "${ANDROID_NDK}/shader-tools/*/glslc.exe")
        if(NDK_GLSLC_MATCHES)
            list(GET NDK_GLSLC_MATCHES 0 NDK_GLSLC)
            set(Vulkan_GLSLC_EXECUTABLE "${NDK_GLSLC}" CACHE FILEPATH "Path to glslc" FORCE)
            message(STATUS "llamadart: Found NDK glslc at ${Vulkan_GLSLC_EXECUTABLE}")
        endif()
    endif()

    # 2. Find Vulkan Lib (libvulkan.so)
    find_library(NDK_VULKAN_LIB vulkan)
    if(NDK_VULKAN_LIB)
        set(Vulkan_LIBRARY "${NDK_VULKAN_LIB}" CACHE FILEPATH "Path to Vulkan library" FORCE)
        message(STATUS "llamadart: Found NDK Vulkan lib at ${Vulkan_LIBRARY}")
    else()
        # Fallback: Trust the linker to find it in the sysroot
        set(Vulkan_LIBRARY "vulkan" CACHE FILEPATH "Path to Vulkan library" FORCE)
        message(STATUS "llamadart: Validating NDK Vulkan lib failed, falling back to 'vulkan'")
    endif()

    # 3. Find Vulkan Headers (vulkan/vulkan.h)
    # 3. Find Vulkan Headers (vulkan/vulkan.h)
    find_path(NDK_VULKAN_INC NAMES vulkan/vulkan.h)
    add_definitions(-DNDK_VULKAN_FIX)

if(NDK_VULKAN_INC)
    set(Vulkan_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../src/native/include;${NDK_VULKAN_INC}" CACHE PATH "Path to Vulkan includes" FORCE)
else()
    message(WARNING "llamadart: NDK Vulkan headers not found!")
endif()

    set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan backend" FORCE)
    set(Vulkan_FOUND TRUE CACHE BOOL "Vulkan found" FORCE)
    set(LLAMA_DART_NO_VULKAN OFF CACHE BOOL "Disable Vulkan backend" FORCE)
    message(STATUS "llamadart: Vulkan backend ENABLED for Android")
else()
    message(STATUS "llamadart: Vulkan backend DISABLED for Android")
    set(GGML_VULKAN OFF CACHE BOOL "Enable Vulkan backend" FORCE)
endif()

# =============================================================================
# Workaround for Android Vulkan Build (Host Toolchain for Shaders)
# =============================================================================
if(ANDROID AND GGML_VULKAN AND NOT GGML_VULKAN_SHADERS_GEN_TOOLCHAIN)
    message(STATUS "llamadart: Generating host toolchain for Vulkan shader compiler (Local Build)...")
    set(ENV{PATH} "${CMAKE_CURRENT_SOURCE_DIR}:$ENV{PATH}")
    
    # Detect host compilers
    if(NOT CMAKE_MAKE_PROGRAM)
        find_program(CMAKE_MAKE_PROGRAM NAMES ninja make)
    endif()

    set(HOST_TOOLCHAIN_FILE "${CMAKE_BINARY_DIR}/android-host-toolchain.cmake")
    file(WRITE "${HOST_TOOLCHAIN_FILE}" 
        "set(CMAKE_MAKE_PROGRAM \"${CMAKE_MAKE_PROGRAM}\" CACHE STRING \"make program\" FORCE)\n"
        "set(CMAKE_SYSTEM_NAME \"${CMAKE_HOST_SYSTEM_NAME}\")\n"
        "set(Threads_FOUND TRUE)\n"
        "set(CMAKE_THREAD_LIBS_INIT \"-pthread\")\n"
        "set(CMAKE_USE_PTHREADS_INIT TRUE)\n"
    )
    set(GGML_VULKAN_SHADERS_GEN_TOOLCHAIN "${HOST_TOOLCHAIN_FILE}" CACHE FILEPATH "Host toolchain" FORCE)
endif()

# Configure llama.cpp flags
set(BUILD_SHARED_LIBS ON CACHE BOOL "Build shared" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "Build common" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Build tests" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "Build tools" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Build examples" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Build server" FORCE)

# Include the submodule directly
add_subdirectory(../src/native/llama_cpp ${CMAKE_CURRENT_BINARY_DIR}/llama_cpp)
