#!/usr/bin/env bash
set -euo pipefail

# Build script for Linux Kernel with Android Binder & Virtio drivers
ARCH="$(uname -m)"
OUTPUT_DIR="$HOME/.msa"
KERNEL_VERSION="6.6.21"

if [ "$ARCH" = "arm64" ]; then
    CONFIG_NAME="config-arm64"
    BUILD_TARGET="Image"
    IMAGE_PATH="arch/arm64/boot/Image"
else
    CONFIG_NAME="config-x86_64"
    BUILD_TARGET="bzImage"
    IMAGE_PATH="arch/x86/boot/bzImage"
fi

echo "========================================================"
echo "🔨 Compiling Custom Linux $KERNEL_VERSION with binderfs"
echo "   Target Architecture: $ARCH"
echo "   Make Target:         $BUILD_TARGET"
echo "   Output Destination:  $OUTPUT_DIR/vmlinuz"
echo "========================================================"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/cache"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$SCRIPT_DIR/msa-guest/kernel/$CONFIG_NAME"

if [ ! -f "$OUTPUT_DIR/cache/linux-$KERNEL_VERSION.tar.xz" ]; then
    echo "⬇️ Downloading Linux $KERNEL_VERSION source to cache..."
    curl -sSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz" -o "$OUTPUT_DIR/cache/linux-$KERNEL_VERSION.tar.xz"
fi

cat << DOCKER_EOF | docker run -i --rm \
    -v "$CONFIG_PATH:/config.txt:ro" \
    -v "$OUTPUT_DIR/cache/linux-$KERNEL_VERSION.tar.xz:/tmp/linux-$KERNEL_VERSION.tar.xz:ro" \
    -v "$OUTPUT_DIR:/out" \
    debian:bookworm-slim bash
set -euo pipefail
echo '📦 Installing build dependencies...'
apt-get update -qq && apt-get install -qq -y \
    build-essential flex bison bc libssl-dev libelf-dev xz-utils >/dev/null

echo '📦 Extracting Linux $KERNEL_VERSION source...'
cd /tmp
tar -xf "linux-$KERNEL_VERSION.tar.xz"
cd "linux-$KERNEL_VERSION"

echo '⚙️ Configuring kernel...'
cp /config.txt .config
make olddefconfig

echo "🔨 Compiling kernel with \$(nproc) threads..."
make -j\$(nproc) $BUILD_TARGET

echo '🚚 Exporting uncompressed kernel to /out/vmlinuz...'
cat $IMAGE_PATH > /out/vmlinuz
chmod 644 /out/vmlinuz
echo '✅ Kernel compilation complete!'
DOCKER_EOF

echo "🎉 Custom kernel with binderfs installed to: $OUTPUT_DIR/vmlinuz"
file "$OUTPUT_DIR/vmlinuz"
