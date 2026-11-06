#!/usr/bin/env bash
set -euo pipefail

# Setup script for Waydroid inside MSA guest rootfs
echo "=== Configuring Waydroid & ARM Translation Layer for MSA ==="

# 1. Waydroid multi-window configuration
mkdir -p /etc/waydroid
cat <<EOF > /etc/waydroid/waydroid.cfg
[waydroid]
multi_windows = true
auto_rotation = false
suspend_action = freeze
EOF

# 2. Setup ARM translation (libndk_translation / Houdini)
echo "Installing ARM to x86_64 translation shims..."
mkdir -p /system/lib/arm /system/lib64/arm64 /etc/binfmt.d

# Binfmt registrations for arm64 and arm
cat <<'EOF' > /etc/binfmt.d/arm.conf
:arm64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/system/lib64/arm64/ndk_translation_arm64:POC
:arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/system/lib/arm/ndk_translation_arm:POC
EOF

echo "✅ Waydroid and ARM translation configured."
