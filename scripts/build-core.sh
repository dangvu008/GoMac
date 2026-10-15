#!/bin/bash
set -e

# Source rustup environment
if [ -f "$HOME/.cargo/env" ]; then
    source "$HOME/.cargo/env"
fi

echo "🦀 Building Rust core..."

cd "$(dirname "$0")/../core"

# Build for macOS (universal binary)
echo "Building for aarch64-apple-darwin..."
cargo build --release --target aarch64-apple-darwin

echo "Building for x86_64-apple-darwin..."
cargo build --release --target x86_64-apple-darwin

# Create universal binary
echo "Creating universal binary..."
lipo -create \
    target/aarch64-apple-darwin/release/libvkey_core.a \
    target/x86_64-apple-darwin/release/libvkey_core.a \
    -output ../platforms/macos/libvkey_core.a

echo "✅ Rust core built successfully!"
echo "📦 Output: platforms/macos/libvkey_core.a"
