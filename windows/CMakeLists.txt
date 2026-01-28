cmake_minimum_required(VERSION 3.10)
project(llamadart_windows LANGUAGES C CXX)

# Include the central native build logic
# Configure llama.cpp flags
set(BUILD_SHARED_LIBS ON CACHE BOOL "Build shared" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "Build common" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Build tests" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "Build tools" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Build examples" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Build server" FORCE)

# Include the submodule directly
add_subdirectory(../src/native/llama_cpp ${CMAKE_CURRENT_BINARY_DIR}/llama_cpp)
