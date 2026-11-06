#!/usr/bin/env bash
set -euo pipefail

# Rootfs image builder for MSA guest MicroVM
IMAGE_SIZE_MB=4096
OUTPUT_DIR="../../build/guest"
ROOTFS_IMG="$OUTPUT_DIR/rootfs.img"

echo "=== Building MSA Guest Rootfs Image ==="
mkdir -p "$OUTPUT_DIR"

if command -v qemu-img >/dev/null 2>&1; then
    qemu-img create -f raw "$ROOTFS_IMG" "${IMAGE_SIZE_MB}M"
else
    dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count="$IMAGE_SIZE_MB"
fi

echo "Formatting rootfs image (ext4)..."
if command -v mkfs.ext4 >/dev/null 2>&1; then
    mkfs.ext4 -F "$ROOTFS_IMG"
else
    echo "⚠️ mkfs.ext4 not found on host. Use Docker or Linux VM to populate filesystem."
fi

echo "Rootfs template created at: $ROOTFS_IMG"
