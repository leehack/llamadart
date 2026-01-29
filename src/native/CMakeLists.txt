cmake_minimum_required(VERSION 3.14)
project(llamadart_native)

# Force PIC so we can link static libs into shared
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Add llama.cpp as a subdirectory
# We assume llama_cpp is in the same directory as this file
add_subdirectory(llama_cpp)

# Create a shared library that links everything
# We use an empty source file because we are just packaging static libs
add_library(llamadart_shared SHARED "llamadart_empty.cpp")

# Link the llama library (which pulls in ggml and backends)
# On Linux/Android, we might need to use --whole-archive to ensure 
# that static constructors in backends are not stripped.
if (APPLE)
    target_link_libraries(llamadart_shared PUBLIC -Wl,-all_load llama)
elseif (MSVC)
    target_link_libraries(llamadart_shared PUBLIC llama)
    target_link_options(llamadart_shared PRIVATE /WHOLEARCHIVE:llama)
elseif (CMAKE_SYSTEM_NAME MATCHES "Android|Linux")
    target_link_libraries(llamadart_shared PUBLIC -Wl,--whole-archive llama -Wl,--no-whole-archive)
else()
    target_link_libraries(llamadart_shared PUBLIC llama)
endif()

# Set the output name to 'llama' so Flutter loader finds 'libllama.so'
set_target_properties(llamadart_shared PROPERTIES 
    OUTPUT_NAME llama
    LIBRARY_OUTPUT_NAME llama
)
