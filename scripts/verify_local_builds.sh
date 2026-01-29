#!/bin/bash
set -e

# verify_local_builds.sh [clean]
# Refactored to use modular build scripts

CLEAN=$1

echo "========================================"
echo "Starting local build verification..."
echo "========================================"

# 1. macOS Build
./scripts/build_apple.sh macos $CLEAN

# 2. iOS Build
./scripts/build_apple.sh ios $CLEAN

# 3. Android Build
./scripts/build_android.sh arm64-v8a $CLEAN

echo "========================================"
echo "All local builds verified successfully!"
echo "========================================"
