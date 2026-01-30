cmake_minimum_required(VERSION 3.14)
project(llamadart_native)

# Force PIC so we can link static libs into shared
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Add llama.cpp as a subdirectory
add_subdirectory(llama_cpp)

set(CONSOLIDATED_LIBS llama ggml ggml-base ggml-cpu ggml-vulkan ggml-blas ggml-metal ggml-cuda)

if (APPLE)
    add_library(llamadart_shared SHARED "llamadart_empty.cpp")
    target_link_libraries(llamadart_shared PUBLIC -Wl,-all_load llama)
elseif (MSVC)
    # On MSVC, we want to consolidate everything into a single DLL.
    # We use $<TARGET_OBJECTS:target> to pull in all objects into one DLL.
    set(COMBINED_OBJECTS "")
    set(ACTIVE_LIBS "")
    foreach(LIB ${CONSOLIDATED_LIBS})
        if(TARGET ${LIB})
            list(APPEND ACTIVE_LIBS ${LIB})
            # Force symbols to be exported by defining the BUILD macros
            target_compile_definitions(${LIB} PRIVATE 
                GGML_SHARED LLAMA_SHARED 
                GGML_BUILD LLAMA_BUILD 
                GGML_BACKEND_SHARED GGML_BACKEND_BUILD)
            list(APPEND COMBINED_OBJECTS $<TARGET_OBJECTS:${LIB}>)
        endif()
    endforeach()

    add_library(llamadart_shared SHARED "llamadart_empty.cpp" ${COMBINED_OBJECTS})
    target_link_libraries(llamadart_shared PUBLIC ${ACTIVE_LIBS})
elseif (CMAKE_SYSTEM_NAME MATCHES "Android|Linux" OR MINGW)
    add_library(llamadart_shared SHARED "llamadart_empty.cpp")
    if (MINGW)
        target_link_options(llamadart_shared PRIVATE -Wl,--export-all-symbols)
    endif()

    set(WHOLE_ARCHIVE_LIBS "")
    foreach(LIB ${CONSOLIDATED_LIBS})
        if(TARGET ${LIB})
            list(APPEND WHOLE_ARCHIVE_LIBS ${LIB})
        endif()
    endforeach()

    target_link_libraries(llamadart_shared PUBLIC -Wl,--whole-archive ${WHOLE_ARCHIVE_LIBS} -Wl,--no-whole-archive)
else()
    add_library(llamadart_shared SHARED "llamadart_empty.cpp")
    target_link_libraries(llamadart_shared PUBLIC llama)
endif()

# Set the output name to 'llamadart' to avoid conflict with submodule 'llama' target on Windows
set_target_properties(llamadart_shared PROPERTIES 
    OUTPUT_NAME llamadart
    LIBRARY_OUTPUT_NAME llamadart
)
