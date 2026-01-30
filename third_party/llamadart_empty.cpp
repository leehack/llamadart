// Empty file to allow creating a shared library via CMake wrapper
#include <stdio.h>

// Optional: Add a dummy symbol to ensure the library is not totally empty
extern "C" void llamadart_native_init() {
    // This function can be called from Dart if needed to ensure the library is loaded
}
