---
title: Linux prerequisites
description: The system libraries each Linux backend module needs, such as OpenMP, Vulkan and OpenBLAS, with package names and a link check.
---

Each llama.cpp backend module the app bundles needs its own system libraries on
Linux. Install them on every machine that runs the app. Choosing modules:
[Native runtime configuration](./native-build-hooks#choose-llamacpp-backend-modules).

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
  without them.
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

Minimal cloud and container images may lack `libgomp1`. Building the
[chat app](../examples/chat-app) on Linux has its own extra requirements.

## Studio audio playback

Studio's Speech and Notes workspaces use GStreamer to play WAV audio. The
development packages needed to build the app do not include all runtime plugins.
Install these on Ubuntu/Debian systems running Studio:

```bash
sudo apt-get install -y gstreamer1.0-plugins-base gstreamer1.0-plugins-good
```

`playbin` comes from the base plugins; WAV parsing and automatic audio sink
selection come from the good plugins. Studio checks that it can create `playbin`,
`autoaudiosink` and `wavparse` before constructing its playback plugin. Missing
elements produce an actionable playback error; entering Speech or Notes, speech
inference, WAV export, recording and note editing do not initialize playback.
This check does not qualify an audio output device or guarantee audible playback.

To inspect the runtime independently, optionally install `gstreamer1.0-tools` and
run `gst-inspect-1.0 playbin`, `gst-inspect-1.0 autoaudiosink` and
`gst-inspect-1.0 wavparse`. Restart Studio after installing missing plugins.

## Quick link check

```bash
for f in .dart_tool/lib/libggml-*.so; do
  LD_LIBRARY_PATH=.dart_tool/lib ldd "$f" | grep "not found" || true
done
```

Any `not found` line names a missing system library for that module. The check
covers only the `libggml-*.so` libraries in `.dart_tool/lib`; it does not
check `libllamadart.so`, an app bundle's library directory, LiteRT-LM or the
stable-diffusion Vulkan build.
