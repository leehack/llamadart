#!/bin/bash
set -e

# verify_app_linux.sh
# Builds the native library and runs the basic example app in a Linux Docker container.

# Get the project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 0. Backend selection
BACKEND=${1:-vulkan}
if [[ "$BACKEND" != "vulkan" && "$BACKEND" != "cuda" ]]; then
    echo "Error: Invalid backend '$BACKEND'. Use 'vulkan' or 'cuda'."
    exit 1
fi

echo "========================================"
echo "Verifying App on Linux ($BACKEND) via Docker"
echo "========================================"

# 1. Build the Docker image (reusing existing Dockerfile)
echo "Step 1: Building Docker image (llamadart_linux_builder)..."
docker build -t llamadart_linux_builder -f "$SCRIPT_DIR/Dockerfile.linux" "$SCRIPT_DIR"

# 2. Run the build and app execution inside the container
echo "Step 2: Building native lib and running basic_app..."
docker run --rm \
  -v "$PROJECT_ROOT:/app" \
  llamadart_linux_builder \
  bash -c "
    set -e
    echo '---- Building Native Library ----'
    cd /app
    ./scripts/build_linux.sh $BACKEND clean
    
    echo '---- Running Basic App ----'
    cd example/basic_app
    
    dart pub get
    dart run bin/llamadart_basic_example.dart
  "

echo "========================================"
echo "Linux App Verification Complete!"
echo "========================================"
