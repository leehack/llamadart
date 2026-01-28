cmake_minimum_required(VERSION 3.10)
project(llamadart_linux LANGUAGES C CXX)

# Determine architecture
set(ARCH ${CMAKE_SYSTEM_PROCESSOR})
if(ARCH STREQUAL "aarch64" OR ARCH STREQUAL "arm64")
    set(ARCH "arm64")
else()
    set(ARCH "x64")
endif()

set(PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib/${ARCH}")

if(NOT EXISTS "${PREBUILT_DIR}/libllama.so")
    message(FATAL_ERROR "llamadart: Pre-built binary not found at ${PREBUILT_DIR}/libllama.so. Please run scripts/build_linux.sh first.")
endif()

message(STATUS "llamadart: Using pre-built binaries for Linux (${ARCH})")

# Create an imported target for the pre-built library
add_library(llama SHARED IMPORTED)
set_target_properties(llama PROPERTIES
    IMPORTED_LOCATION "${PREBUILT_DIR}/libllama.so"
)

# Install all .so files in the folder to the app bundle
file(GLOB PREBUILT_LIBS "${PREBUILT_DIR}/*.so*")
install(FILES ${PREBUILT_LIBS} DESTINATION "${CMAKE_INSTALL_PREFIX}/lib")
