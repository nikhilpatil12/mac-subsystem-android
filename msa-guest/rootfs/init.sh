#!/bin/sh
# Minimal init script for Mac Subsystem for Android (MSA) MicroVM

echo "🤖 [MSA Guest] Initializing Android Subsystem MicroVM..."

# Mount essential virtual filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/binderfs /run /tmp
mount -t devpts devpts /dev/pts
mount -t binder binder /dev/binderfs

# Enable core networking (DHCP over virtio-net)
ip link set lo up
ip link set eth0 up
udhcpc -i eth0 -q -n -s /etc/udhcpc/default.script || true

# Mount shared virtiofs directory (~/Downloads from macOS host)
mkdir -p /sdcard/Download
mount -t virtiofs shared_storage /sdcard/Download || true

# Mount Waydroid AOSP system and vendor images from attached virtio block devices
mkdir -p /var/lib/waydroid/images /system /vendor
if [ -b /dev/vdb ]; then
    echo "📦 [MSA Guest] Mounting Android system image from /dev/vdb..."
    mount -t ext4 -o ro /dev/vdb /system || true
fi
if [ -b /dev/vdc ]; then
    echo "📦 [MSA Guest] Mounting Waydroid vendor image from /dev/vdc..."
    mount -t ext4 -o ro /dev/vdc /vendor || true
fi

# Configure binfmt_misc for ARM binary translation (Houdini / libndk_translation)
if [ -d /proc/sys/fs/binfmt_misc ]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
    # Register ARM64 / ARM32 ELF interpreters
    if [ -f /etc/binfmt.d/arm.conf ]; then
        cat /etc/binfmt.d/arm.conf > /proc/sys/fs/binfmt_misc/register || true
    fi
fi

# Bridge Wayland unix socket (/run/wayland-0) to macOS host virtio-vsock (port 5000)
# vsock CID 2 is always the hypervisor host in Virtualization.framework
echo "🔌 [MSA Guest] Bridging Wayland display to host vsock..."
socat VSOCK-CONNECT:2:5000 UNIX-LISTEN:/run/wayland-0,fork,mode=777 &

# Set Wayland display environment for Android session
export WAYLAND_DISPLAY=/run/wayland-0
export XDG_RUNTIME_DIR=/run

# Initialize and launch Waydroid container in multi-window mode
if command -v waydroid >/dev/null 2>&1; then
    echo "📱 [MSA Guest] Launching Waydroid container..."
    waydroid prop set persist.waydroid.multi_windows true
    waydroid container start &
    waydroid session start &
fi

echo "✅ [MSA Guest] Subsystem ready for app requests."

# Keep PID 1 running
exec /bin/sh
