#!/bin/sh
# Compile the GLSL shaders to the SPIR-V blobs committed next to them (used by
# SDL_GPU's Vulkan backend on Linux/Windows; the Metal backend compiles the
# .metal sources at runtime instead). Requires glslc (shaderc), e.g.
# `brew install shaderc` / `apt install glslc`. Run from this directory after
# editing any .vert/.frag, and commit the regenerated .spv files.
set -e
cd "$(dirname "$0")"
for f in prim.vert quad.vert prim.frag blur_h.frag blur_v.frag; do
    glslc --target-env=vulkan1.0 -O "$f" -o "$f.spv"
    echo "compiled $f -> $f.spv"
done
