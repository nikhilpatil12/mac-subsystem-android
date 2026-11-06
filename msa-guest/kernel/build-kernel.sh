#!/usr/bin/env bash
set -euo pipefail

# Build script for Linux Kernel with Android Binder & Virtio drivers for x86_64
KERNEL_VERSION="6.6.21"
ARCH="x86_64"
OUTPUT_DIR="../../build/guest"

echo "=== Building Minimal Linux Kernel for MSA ($ARCH) ==="
mkdir -p "$OUTPUT_DIR"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"
echo "Fetching Linux $KERNEL_VERSION source..."
curl -sSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz" | tar -xJ

cd "linux-$KERNEL_VERSION"
echo "Applying MSA kernel configuration..."
cp "$OLDPWD/config-x86_64" .config

make olddefconfig
echo "Compiling vmlinux / bzImage..."
make -j"$(sysctl -n hw.ncpu || nproc)" bzImage

cp arch/x86/boot/bzImage "$OUTPUT_DIR/vmlinuz"
echo "✅ Kernel built successfully: $OUTPUT_DIR/vmlinuz"
