---
title: Linux Prerequisites
---

Linux runtime requirements depend on selected backend modules.

## Dependency mapping

- `cpu`: OpenMP runtime (`libgomp.so.1`). `libggml-base.so` links it too, so
  every llama.cpp load needs it whichever backend modules are selected; without
  it `libllamadart.so` fails to load with `libgomp.so.1: cannot open shared
  object file`.
- `vulkan`: Vulkan loader and valid GPU driver/ICD.
- `blas`: OpenBLAS runtime (`libopenblas.so.0`).
- `cuda`: NVIDIA driver plus the CUDA 12 runtime libraries.
  `libggml-cuda.so` links `libcudart.so.12` and `libcublas.so.12`, and
  llamadart does not ship them on Linux. Without them the CUDA module fails to
  load and llama.cpp runs on CPU. A GPU-ready cloud image can ship the driver
  alone: the GCE `ubuntu-accelerator-2404-amd64-with-nvidia-580` image does.
- `hip`: ROCm runtime libs (for example `libhipblas.so.2`).

## Package examples

Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y libgomp1 libvulkan1 vulkan-tools libopenblas0
```

Fedora/RHEL/CentOS:

```bash
sudo dnf install -y libgomp vulkan-loader vulkan-tools openblas
```

Arch Linux:

```bash
sudo pacman -S --needed libgomp vulkan-icd-loader vulkan-tools openblas
```

Minimal cloud and container images can omit `libgomp1`; the stock GCE Ubuntu
24.04 accelerator image does.

## Quick link check

```bash
for f in .dart_tool/lib/libggml-*.so; do
  LD_LIBRARY_PATH=.dart_tool/lib ldd "$f" | grep "not found" || true
done
```

For containerized checks, see repository scripts under `docker/validation` and
`scripts/check_native_link_deps.sh`.
