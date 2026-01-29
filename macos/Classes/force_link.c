#include <stdint.h>

// Forward declaration to avoid include path issues
void llama_backend_init(void);

__attribute__((visibility("default"))) __attribute__((used)) void
llamadart_init(void) {
  // Purposefully empty.
  // Symbols are loaded dynamically via FFI.
}
