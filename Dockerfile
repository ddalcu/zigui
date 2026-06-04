# Linux validation image for zigui.
#
# The zigui core (geometry, color, state, layout, theme, text, canvas, software
# rasterizer, view layer, components) has no C dependencies, so the entire test
# suite builds and runs on Linux with nothing but the Zig toolchain — no GPU,
# window server, or SDL required. This image downloads Zig 0.16.0 and runs
# `zig build test`; a successful build means the suite is green on Linux.
#
#   docker build -t zigui-test .
#
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH="$(uname -m)" \
    && case "$ARCH" in \
         x86_64) ZARCH=x86_64 ;; \
         aarch64|arm64) ZARCH=aarch64 ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz \
    && zig version

WORKDIR /app
COPY . .

# Build & run the full test suite. Fails the image build if any test fails.
RUN zig build test --summary all
