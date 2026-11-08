###############################################
#
# Makefile — zigui
#
# `make validate` is the pre-commit gate; `make build` is the entry point.
#
###############################################

# Optional include to extend the makefile targets
-include ../styleguide/Makefile.in

.DEFAULT_GOAL := all

.PHONY: build dist run demo edit test docs clean windows linux linux-arm64 macos-arm64 cross

# ---------------------------------------------
# Configuration
# ---------------------------------------------

# The released version, read from build.zig.zon (the source of truth).
VERSION := $(shell sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon)

# ---------------------------------------------
# Primary workflows
# ---------------------------------------------

# Build, format, and test.
all: build format test
	@echo "done"

# ---------------------------------------------
# Build
# ---------------------------------------------

# Build the library and examples.
build:
	zig build

# Build optimized for release.
dist:
	zig build --release=fast

# ---------------------------------------------
# Cross-platform builds
# ---------------------------------------------

# Release builds of both examples for each platform, into zig-out/<target>/bin.
# SDL3 is compiled from source per target, so no SDL install is needed for any
# of them. Linux binaries load X11/Wayland/GL/Vulkan at runtime.
CROSS = zig build showcase edit -Doptimize=ReleaseFast -Dtarget=$(1) --prefix zig-out/$(1) $(2)

# The macOS SDK (Xcode or Command Line Tools): an explicit macOS target is a
# cross build to Zig, so SDL needs the SDK's frameworks passed in.
MACOS_SDK = $(shell xcrun --show-sdk-path 2>/dev/null)

windows:
	$(call CROSS,x86_64-windows-gnu)

linux:
	$(call CROSS,x86_64-linux-gnu)

linux-arm64:
	$(call CROSS,aarch64-linux-gnu)

macos-arm64:
	@test -n "$(MACOS_SDK)" || { echo "❌ macOS SDK not found (needs macOS + xcode-select --install)"; exit 1; }
	$(call CROSS,aarch64-macos,-Dmacos-sdk=$(MACOS_SDK))

# All four platforms.
cross: windows linux linux-arm64 macos-arm64

# Build and launch the showcase (the kitchen-sink gallery) in a window.
# SDL3 is fetched and compiled from source by Zig on first use — no Homebrew.
# ReleaseFast because the software rasterizer is ~10x slower in Debug.
demo:
	zig build run-showcase -Doptimize=ReleaseFast -- $(ARGS)

# Build the edit example (the multi-line text editor) into zig-out/bin.
edit:
	zig build edit

# Build and run the showcase in a window. Pass arguments with `make run ARGS="--dark"`.
run:
	zig build run-showcase -- $(ARGS)

# ---------------------------------------------
# Test
# ---------------------------------------------

# Run the unit test suite.
test:
	zig build test --summary all

# ---------------------------------------------
# Documentation
# ---------------------------------------------

# Build the API docs and serve them locally (Ctrl-C stops the server).
# The browser opens only once the server answers — opening it first raced the
# server's startup and showed "can't connect". A busy port fails loudly.
# Not 8080: other local tools (e.g. llama.cpp's web UI) leave a service worker
# registered on 127.0.0.1:8080 that keeps serving their app instead of these
# docs. A service worker is per origin, so a dedicated port sidesteps it.
DOCS_PORT ?= 8080
OPEN ?= open
docs:
	zig build docs
	@! curl -s -o /dev/null "http://127.0.0.1:$(DOCS_PORT)/" || { echo "❌ port $(DOCS_PORT) is already serving something (an old 'make docs'?) — stop it or use DOCS_PORT=8081"; exit 1; }
	@echo "Serving zig-out/docs at http://127.0.0.1:$(DOCS_PORT)/ (Ctrl-C to stop)"
	@python3 -m http.server -b 127.0.0.1 $(DOCS_PORT) -d zig-out/docs & pid=$$!; \
	trap 'kill $$pid 2>/dev/null' INT TERM EXIT; \
	until curl -fs -o /dev/null "http://127.0.0.1:$(DOCS_PORT)/"; do \
		kill -0 $$pid 2>/dev/null || { echo "❌ docs server failed to start (port $(DOCS_PORT) in use? try DOCS_PORT=8081)"; exit 1; }; \
		sleep 0.1; \
	done; \
	$(OPEN) "http://127.0.0.1:$(DOCS_PORT)/"; \
	wait $$pid

# ---------------------------------------------
# Release
# ---------------------------------------------

# Tag the build.zig.zon version (e.g. 1.0.0) and push it.
tag:
	@test -n "$(VERSION)" || { echo "❌ could not read .version from build.zig.zon"; exit 1; }
	git tag -a "$(VERSION)" -m "$(VERSION)"
	git push
	git push --tags

# ---------------------------------------------
# Environment
# ---------------------------------------------

# Open the working copy in SourceTree.
st:
	open -a SourceTree .

# Open the project in the editor.
open:
	code .

# Open the repository on GitHub.
github:
	open "https://github.com/ddalcu/zigui"

# Clone a fresh working copy.
clone:
	git clone git@github.com:ddalcu/zigui.git

# Start Claude Code here.
claude:
	claude

# ---------------------------------------------
# Housekeeping
# ---------------------------------------------

# Remove every build artifact.
clean:
	rm -rf .zig-cache
	rm -rf zig-out
