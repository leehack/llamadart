cmake_minimum_required(VERSION 3.10)
project(llamadart_android LANGUAGES C CXX)

# Check for pre-built binaries in jniLibs
set(PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/main/jniLibs/${ANDROID_ABI}")

if(NOT EXISTS "${PREBUILT_DIR}/libllama.so")
    message(FATAL_ERROR "llamadart: Pre-built binary not found at ${PREBUILT_DIR}/libllama.so. Please run scripts/build_android.sh first.")
endif()

message(STATUS "llamadart: Using pre-built binaries for Android (${ANDROID_ABI})")

# Create an imported target for the pre-built library
add_library(llama SHARED IMPORTED)
set_target_properties(llama PROPERTIES
    IMPORTED_LOCATION "${PREBUILT_DIR}/libllama.so"
)

# Gradle's jniLibs handling will take care of the actual bundling into the APK.
