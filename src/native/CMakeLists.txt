cmake_minimum_required(VERSION 3.10)
project(llamadart_native LANGUAGES C CXX)

message(STATUS "llamadart: Configuring native build for Android...")



# Backend Options (can be overridden by parent project)
option(GGML_CUDA "Enable CUDA backend" OFF)
# REMOVED option(GGML_VULKAN ...) to avoid cache conflicts

# Version info for all platforms
set(LLAMA_INSTALL_VERSION "0.0.1")

# Standardize output directories (essential for some platforms/frameworks)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# Global visibility settings to ensure symbols are exported
set(CMAKE_CXX_VISIBILITY_PRESET default)
set(CMAKE_C_VISIBILITY_PRESET default)
set(CMAKE_VISIBILITY_INLINES_HIDDEN OFF)

# Ensure the output directory exists
file(MAKE_DIRECTORY "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")

# Global PIC for shared libraries
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Force llama to be built as a static library
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static" FORCE)

# =============================================================================
# GPU Backend Configuration
# These are ENABLED by default. Use -DLLAMA_DART_NO_<BACKEND>=ON to disable.
# =============================================================================

# Metal: Auto-enabled on Apple platforms (cannot be disabled on Apple)
if(APPLE)
    set(GGML_METAL ON CACHE BOOL "Enable Metal backend" FORCE)
    add_compile_definitions(GGML_USE_METAL)
    message(STATUS "llamadart: Metal backend ENABLED (Apple platform)")
endif()

option(LLAMA_DART_NO_VULKAN "Disable Vulkan GPU backend" OFF)

if(NOT APPLE AND NOT LLAMA_DART_NO_VULKAN)
    # If parent (android/CMakeLists.txt) already enabled Vulkan via CACHE variable, trust it.
    if(GGML_VULKAN OR CMAKE_SYSTEM_NAME MATCHES "Android")
         message(STATUS "llamadart: Vulkan enabled by parent/platform (Android detected). Configuring definitions...")
         set(Vulkan_FOUND TRUE)
         set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan backend" FORCE)
    else()
        message(STATUS "llamadart: Checking for Vulkan SDK...")
        find_package(Vulkan QUIET)
    endif()

    if(Vulkan_FOUND OR GGML_VULKAN)
        set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan backend" FORCE)
        # Use a list variable to defer application to target
        set(LLAMA_DART_COMPILE_DEFS GGML_USE_VULKAN)
        add_compile_definitions(GGML_USE_VULKAN)
        message(WARNING "llamadart: Vulkan backend ENABLED (Setting GGML_USE_VULKAN globally)")
        
        # Ensure we link against Vulkan
        if(NOT TARGET Vulkan::Vulkan)
            message(STATUS "llamadart: Creating manual Vulkan::Vulkan target for ggml compatibility")
            add_library(Vulkan::Vulkan INTERFACE IMPORTED)
            if(Vulkan_LIBRARY)
                 set_target_properties(Vulkan::Vulkan PROPERTIES INTERFACE_LINK_LIBRARIES "${Vulkan_LIBRARY}")
                 message(STATUS "llamadart: Vulkan::Vulkan mapped to ${Vulkan_LIBRARY}")
            else()
                 set_target_properties(Vulkan::Vulkan PROPERTIES INTERFACE_LINK_LIBRARIES "vulkan")
                 message(STATUS "llamadart: Vulkan::Vulkan mapped to 'vulkan'")
            endif()

            if(Vulkan_INCLUDE_DIR)
                set_target_properties(Vulkan::Vulkan PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${Vulkan_INCLUDE_DIR}")
            endif()
        endif()


    else()
        message(WARNING "llamadart: Vulkan SDK not found, Vulkan backend DISABLED")
    endif()
endif()

# CUDA: Enabled by default on Linux/Windows if toolkit is available
option(LLAMA_DART_NO_CUDA "Disable CUDA GPU backend" OFF)
if(NOT APPLE AND NOT LLAMA_DART_NO_CUDA AND NOT CMAKE_SYSTEM_NAME MATCHES "Android")
    include(CheckLanguage)
    check_language(CUDA)
    if(CMAKE_CUDA_COMPILER)
        set(GGML_CUDA ON CACHE BOOL "Enable CUDA backend" FORCE)
        message(STATUS "llamadart: CUDA backend ENABLED")
    else()
        message(STATUS "llamadart: CUDA toolkit not found, CUDA backend DISABLED")
    endif()
endif()

# =============================================================================
# Include llama.cpp
# =============================================================================

# Add local cmake modules (e.g. FindVulkan.cmake shim)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# Configure llama.cpp options to avoid building extras
set(LLAMA_BUILD_COMMON ON CACHE BOOL "Build common" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Build tests" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Build examples" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Build server" FORCE)
set(LLAMA_HTTPLIB OFF CACHE BOOL "Build httplib" FORCE)
# Note: Newer llama.cpp versions might use different flags, check upstream if needed

# =============================================================================
# Workaround for Android Vulkan Build
# =============================================================================
# The vendored ggml-vulkan build script fails to find the make program (Ninja)
# when building vulkan-shaders-gen (a host tool) inside the Android cross-compilation context.
# We generate a custom host toolchain file to pass CMAKE_MAKE_PROGRAM explicitly.
if(ANDROID AND NOT GGML_VULKAN_SHADERS_GEN_TOOLCHAIN)
    message(STATUS "llamadart: Generating host toolchain for Vulkan shader compiler...")
    
    # Add our local ninja shim to PATH for subprocesses
    set(ENV{PATH} "${CMAKE_CURRENT_SOURCE_DIR}:$ENV{PATH}")
    message(STATUS "llamadart: Added ${CMAKE_CURRENT_SOURCE_DIR} to PATH (for ninja shim)")
    
    # Detect host compilers (matches logic in ggml-vulkan/CMakeLists.txt but exposes variables we need)
    message(STATUS "llamadart: CMAKE_MAKE_PROGRAM is ${CMAKE_MAKE_PROGRAM}")
    if(APPLE)
        find_program(HOST_C_COMPILER NAMES clang gcc cc NO_CMAKE_FIND_ROOT_PATH)
        find_program(HOST_CXX_COMPILER NAMES clang++ g++ c++ NO_CMAKE_FIND_ROOT_PATH)
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        find_program(HOST_C_COMPILER NAMES cl gcc clang NO_CMAKE_FIND_ROOT_PATH)
        find_program(HOST_CXX_COMPILER NAMES cl g++ clang++ NO_CMAKE_FIND_ROOT_PATH)
    else()
        find_program(HOST_C_COMPILER NAMES gcc clang NO_CMAKE_FIND_ROOT_PATH)
        find_program(HOST_CXX_COMPILER NAMES g++ clang++ NO_CMAKE_FIND_ROOT_PATH)
    endif()

    if(NOT HOST_C_COMPILER OR NOT HOST_CXX_COMPILER)
        message(WARNING "llamadart: Could not find host compiler! Vulkan build might fail.")
    else()
        set(HOST_TOOLCHAIN_FILE "${CMAKE_BINARY_DIR}/android-host-toolchain.cmake")
        
        # Write the toolchain file
        # We explicitly set CMAKE_MAKE_PROGRAM to ensure the inner ExternalProject uses the correct builder (e.g. NDK Ninja)
        if(NOT CMAKE_MAKE_PROGRAM)
            find_program(CMAKE_MAKE_PROGRAM NAMES ninja make)
        endif()
        message(STATUS "llamadart: Resolved CMAKE_MAKE_PROGRAM for host: ${CMAKE_MAKE_PROGRAM}")

        file(WRITE "${HOST_TOOLCHAIN_FILE}" 
            "set(CMAKE_MAKE_PROGRAM \"${CMAKE_MAKE_PROGRAM}\" CACHE STRING \"make program\" FORCE)\n"
            "set(CMAKE_SYSTEM_NAME \"${CMAKE_HOST_SYSTEM_NAME}\")\n"
            "set(Threads_FOUND TRUE)\n"
            "set(CMAKE_THREAD_LIBS_INIT \"-pthread\")\n"
            "set(CMAKE_USE_PTHREADS_INIT TRUE)\n"
        )
        
        set(GGML_VULKAN_SHADERS_GEN_TOOLCHAIN "${HOST_TOOLCHAIN_FILE}" CACHE FILEPATH "Host toolchain for Vulkan shader generation" FORCE)
        message(STATUS "llamadart: Using generated host toolchain (cached): ${HOST_TOOLCHAIN_FILE}")
    endif()
endif()

# Include the submodule
add_subdirectory(llama_cpp)

# Define our plugin library
# We rename the target to 'llamadart_plugin' to avoid conflict with the directory name 'llama_cpp' 
# or any potential targets in the submodule.
add_library(llamadart_plugin SHARED llamadart.cpp)

# Set the output name to 'llama_cpp' so the file on disk is 'libllama_cpp.so' / 'llama_cpp.dll'
# This matches what the Dart FFI expects (if it looks for 'llama_cpp').
set_target_properties(llamadart_plugin PROPERTIES OUTPUT_NAME "llama_cpp")

# Link against the 'llama' target from the submodule
if(GGML_VULKAN)
    target_compile_definitions(llamadart_plugin PUBLIC GGML_USE_VULKAN)
    # The submodule's 'llama' target should already carry usage requirements, 
    # but we ensure visibility and linking here.
endif()

if(LLAMA_DART_COMPILE_DEFS)
    target_compile_definitions(llamadart_plugin PUBLIC ${LLAMA_DART_COMPILE_DEFS})
endif()

# Links
if(APPLE)
    target_link_libraries(llamadart_plugin PRIVATE llama)
    set_target_properties(llamadart_plugin PROPERTIES 
        LINK_FLAGS "-Wl,-all_load -Wl,-export_dynamic"
    )
elseif(ANDROID)
    target_link_libraries(llamadart_plugin PRIVATE -Wl,--whole-archive llama -Wl,--no-whole-archive log)
    set_target_properties(llamadart_plugin PROPERTIES 
        LINK_FLAGS "-Wl,-export-dynamic"
    )
else()
    # Linux / Windows
    if(MSVC)
        target_link_libraries(llamadart_plugin PRIVATE llama)
    else()
        target_link_libraries(llamadart_plugin PRIVATE -Wl,--whole-archive llama -Wl,--no-whole-archive)
        set_target_properties(llamadart_plugin PROPERTIES 
            LINK_FLAGS "-Wl,-export-dynamic"
        )
    endif()
endif()

if(GGML_VULKAN)
     # If the submodule defines Vulkan::Vulkan or similar, we might need it. 
     # Usually linking 'llama' is enough if 'llama' links 'ggml-backend' which links Vulkan.
     # But we keep explicit link just in case.
    target_link_libraries(llamadart_plugin PRIVATE Vulkan::Vulkan)
endif()


if(GGML_VULKAN)
    target_link_libraries(llama_cpp PRIVATE Vulkan::Vulkan)
endif()

# Install the shared library to the bundle
include(GNUInstallDirs)
install(TARGETS llamadart_plugin
    RUNTIME DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
)
