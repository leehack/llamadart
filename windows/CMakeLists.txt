cmake_minimum_required(VERSION 3.10)
project(llamadart_windows LANGUAGES C CXX)

# Check for pre-built binaries
set(PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")

if(NOT EXISTS "${PREBUILT_DIR}/llama.dll" AND NOT EXISTS "${PREBUILT_DIR}/libllama.dll")
    message(FATAL_ERROR "llamadart: Pre-built binary not found in ${PREBUILT_DIR}. Please run scripts/build_windows.ps1 first.")
endif()

message(STATUS "llamadart: Using pre-built binaries for Windows")

# Identify which one exists
if(EXISTS "${PREBUILT_DIR}/llama.dll")
    set(LLAMA_DLL_PATH "${PREBUILT_DIR}/llama.dll")
else()
    set(LLAMA_DLL_PATH "${PREBUILT_DIR}/libllama.dll")
endif()

# Create an imported target for the pre-built library
add_library(llama SHARED IMPORTED)
set_target_properties(llama PROPERTIES
    IMPORTED_LOCATION "${LLAMA_DLL_PATH}"
)

# Install the DLL(s) so they are bundled with the app
file(GLOB PREBUILT_LIBS "${PREBUILT_DIR}/*.dll")
install(FILES ${PREBUILT_LIBS} DESTINATION "${CMAKE_INSTALL_PREFIX}")
