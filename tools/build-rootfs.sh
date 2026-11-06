#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$HOME/.msa"
ROOTFS_IMG="$OUTPUT_DIR/rootfs.img"
IMAGE_SIZE="4G"

echo "========================================================"
echo "📦 Building Populated MSA Guest Rootfs (Debian + Waydroid)"
echo "   Output Destination: $ROOTFS_IMG"
echo "   Filesystem:         ext4 ($IMAGE_SIZE)"
echo "========================================================"

mkdir -p "$OUTPUT_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure msa-builder docker image exists
if ! docker image inspect msa-builder:latest >/dev/null 2>&1; then
    echo "🔨 Building msa-builder image..."
    docker build -t msa-builder:latest -f "$SCRIPT_DIR/msa-guest/Dockerfile" "$SCRIPT_DIR/msa-guest"
fi

echo "🚚 Generating rootfs filesystem image inside Docker..."
cat << 'DOCKER_EOF' | docker run -i --rm -v "$OUTPUT_DIR:/out" msa-builder:latest bash
set -euo pipefail
echo '📂 Staging root filesystem...'
mkdir -p /staging

# Export base image filesystem into staging
tar -cf - --one-file-system -C / . | tar -xf - -C /staging 2>/dev/null || true

# Ensure essential directories exist
mkdir -p /staging/dev/binderfs /staging/dev/pts /staging/dev/shm
mkdir -p /staging/proc /staging/sys /staging/run /staging/tmp
mkdir -p /staging/sys/fs/cgroup /staging/sdcard/Download
mkdir -p /staging/etc/waydroid-extra/images
mkdir -p /staging/var/lib/waydroid/rootfs
mkdir -p /staging/var/lib/waydroid/overlay/vendor
mkdir -p /staging/var/lib/waydroid/overlay_rw/system
mkdir -p /staging/var/lib/waydroid/overlay_rw/vendor
mkdir -p /staging/var/lib/waydroid/overlay_work/system
mkdir -p /staging/var/lib/waydroid/overlay_work/vendor
mkdir -p /staging/var/lib/waydroid/data
mkdir -p /staging/var/lib/waydroid/lxc/waydroid

# Create fundamental device nodes required for Linux boot & PID 1 console
mknod -m 600 /staging/dev/console c 5 1 || true
mknod -m 666 /staging/dev/null c 1 3 || true
mknod -m 666 /staging/dev/zero c 1 5 || true
mknod -m 666 /staging/dev/ptmx c 5 2 || true
mknod -m 666 /staging/dev/tty c 5 0 || true
mknod -m 660 /staging/dev/hvc0 c 229 0 || true

# Setup symlinks for block devices attached to MicroVM
# /dev/vdb is system.img, /dev/vdc is vendor.img
ln -sf /dev/vdb /staging/etc/waydroid-extra/images/system.img
ln -sf /dev/vdc /staging/etc/waydroid-extra/images/vendor.img

# Symlinks for binder nodes
ln -sf /dev/binderfs/binder /staging/dev/binder
ln -sf /dev/binderfs/hwbinder /staging/dev/hwbinder
ln -sf /dev/binderfs/vndbinder /staging/dev/vndbinder

# Initialize Waydroid configuration and LXC profiles
echo '⚙️ Initializing Waydroid configuration and LXC profiles...'
mkdir -p /dev/binderfs /etc/waydroid-extra/images
touch /etc/waydroid-extra/images/system.img /etc/waydroid-extra/images/vendor.img
touch /dev/binder /dev/vndbinder /dev/hwbinder
waydroid --details-to-stdout init -f

# Configure waydroid.cfg for multi-window and ADB
cat << 'CFG_EOF' > /var/lib/waydroid/waydroid.cfg
[waydroid]
arch = arm64_only
vendor_type = MAINLINE
system_datetime = 9999999999
vendor_datetime = 9999999999
suspend_action = freeze
mount_overlays = True
auto_adb = True
images_path = /etc/waydroid-extra/images
binder = binder
vndbinder = vndbinder
hwbinder = hwbinder
system_ota = None
vendor_ota = None
wayland_display = /run/wayland-0

[properties]
persist.waydroid.multi_windows = true
persist.adb.tcp.port = 5555
service.adb.tcp.port = 5555
ro.adb.secure = 0
ro.debuggable = 1
persist.sys.timezone = UTC
CFG_EOF

# Copy generated Waydroid configuration to staging
cp -a /var/lib/waydroid/* /staging/var/lib/waydroid/
cp -a /var/lib/waydroid/waydroid.cfg /staging/var/lib/waydroid/
cat << "NODES_EOF" >> /staging/var/lib/waydroid/lxc/waydroid/config_nodes
lxc.mount.entry = /dev/urandom dev/hw_random none bind,create=file,optional 0 0
NODES_EOF

# Configure iptables alternatives to legacy (built into MSA kernel)
ln -sf /usr/sbin/iptables-legacy /staging/etc/alternatives/iptables
ln -sf /usr/sbin/ip6tables-legacy /staging/etc/alternatives/ip6tables
ln -sf /usr/sbin/iptables-legacy /staging/sbin/iptables
ln -sf /usr/sbin/ip6tables-legacy /staging/sbin/ip6tables

python3 -c '
with open("/staging/usr/lib/waydroid/tools/helpers/lxc.py", "r") as f:
    lxc = f.read()
lxc = lxc.replace("make_entry(pulse_host_socket, pulse_container_socket[1:])", "if os.path.exists(pulse_host_socket): make_entry(pulse_host_socket, pulse_container_socket[1:])")
target_char = "make_entry(\"/dev/char\", options=\"bind,create=dir,optional 0 0\")"
replacement_char = target_char + "\n    make_entry(\"/dev/urandom\", \"dev/hw_random\")"
lxc = lxc.replace(target_char, replacement_char)
with open("/staging/usr/lib/waydroid/tools/helpers/lxc.py", "w") as f:
    f.write(lxc)
'

# Setup fstab
cat << 'FSTAB_EOF' > /staging/etc/fstab
/dev/vda / ext4 defaults,noatime 0 1
FSTAB_EOF

# Setup DNS
cat << 'RESOLV_EOF' > /staging/etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV_EOF

# Write custom /init script
echo '📝 Creating /init entrypoint script...'
cat << 'INIT_EOF' > /staging/init
#!/bin/sh
# Ensure stdio is attached to system console
exec 0</dev/console 1>/dev/console 2>/dev/console

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root

echo "=========================================================="
echo "🤖 [MSA Guest] Initializing Mac Subsystem for Android microVM"
echo "=========================================================="

# 1. Mount virtual filesystems
mount -t proc proc /proc
echo 0 > /proc/sys/kernel/printk_ratelimit
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/shm /run /tmp /dev/binderfs /sys/fs/cgroup /run/pulse
ln -sf /dev/urandom /dev/hw_random
touch /run/pulse/native
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /dev/shm
mount -t cgroup2 none /sys/fs/cgroup

# 2. Mount binderfs
echo "📱 [MSA Guest] Mounting binderfs..."
mount -t binder binder /dev/binderfs || true

# Dynamically allocate binder nodes via binder-control
python3 -c '
import fcntl, struct
def IOC(d, t, nr, size): return (d << 30) | (t << 8) | (nr << 0) | (size << 16)
try:
    with open("/dev/binderfs/binder-control", "rb") as f:
        for node in ["binder", "hwbinder", "vndbinder"]:
            try: fcntl.ioctl(f.fileno(), IOC(3, 98, 1, 264), struct.pack("256sII", node.encode(), 0, 0))
            except OSError: pass
except Exception as e:
    print(f"Binderfs allocation: {e}")
' || true

ln -sf /dev/binderfs/binder /dev/binder
ln -sf /dev/binderfs/hwbinder /dev/hwbinder
ln -sf /dev/binderfs/vndbinder /dev/vndbinder
chmod 666 /dev/binder /dev/hwbinder /dev/vndbinder /dev/binderfs/* || true

# 3. Mount shared virtiofs directory (~/Downloads)
mkdir -p /sdcard/Download
mount -t virtiofs shared_storage /sdcard/Download || true

# 4. Enable networking
echo "🌐 [MSA Guest] Configuring networking..."
ip link set lo up 2>/dev/null || true
ip link set eth0 up 2>/dev/null || true
dhclient -4 -nw eth0 2>/dev/null || true
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s 192.168.240.0/24 ! -d 192.168.240.0/24 -j MASQUERADE 2>/dev/null || true
iptables -I FORWARD -i waydroid0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -o waydroid0 -j ACCEPT 2>/dev/null || true

# 5. Start system & session D-Bus daemons
echo "🚌 [MSA Guest] Starting system and session D-Bus daemons..."
mkdir -p /run/dbus /var/run/dbus
dbus-uuidgen --ensure 2>/dev/null || true
dbus-daemon --system --fork
dbus-daemon --session --fork --address=unix:path=/run/user_bus.sock
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user_bus.sock

# 6. Wayland bridge over virtio-vsock
# Expose /run/wayland-0 and bridge each connection to macOS host vsock CID 2 port 5000
echo "🔌 [MSA Guest] Bridging Wayland display to macOS host (vsock port 5000)..."
rm -f /run/wayland-0
(
  while true; do
    socat UNIX-LISTEN:/run/wayland-0,fork,unlink-early,mode=777 VSOCK-CONNECT:2:5000 2>/dev/null || true
    sleep 1
  done
) &

export WAYLAND_DISPLAY=/run/wayland-0
export XDG_RUNTIME_DIR=/run

# 7. Initialize Waydroid container if needed
if [ ! -f /var/lib/waydroid/lxc/waydroid/config ]; then
  echo "⚙️ [MSA Guest] Initializing Waydroid container..."
  waydroid init -f
  cat << 'CFG_EOF' > /var/lib/waydroid/waydroid.cfg
[waydroid]
arch = arm64_only
vendor_type = MAINLINE
system_datetime = 9999999999
vendor_datetime = 9999999999
suspend_action = freeze
mount_overlays = True
auto_adb = True
images_path = /etc/waydroid-extra/images
binder = binder
vndbinder = vndbinder
hwbinder = hwbinder
system_ota = None
vendor_ota = None
wayland_display = /run/wayland-0

[properties]
persist.waydroid.multi_windows = true
persist.adb.tcp.port = 5555
service.adb.tcp.port = 5555
ro.adb.secure = 0
ro.debuggable = 1
persist.sys.timezone = UTC
CFG_EOF
fi

# 7. Start Waydroid network bridge
echo "🌐 [MSA Guest] Starting Waydroid network bridge..."
/usr/lib/waydroid/data/scripts/waydroid-net.sh start || true

# 8. Start Waydroid container daemon
echo "📱 [MSA Guest] Starting Waydroid container daemon..."
waydroid container start &

# 9. Start Waydroid session
(
  echo "✨ [MSA Guest] Waiting for D-Bus and Wayland display..."
  for w in $(seq 1 20); do
    if [ -S /run/wayland-0 ]; then break; fi
    sleep 0.5
  done
  sleep 2
  echo "✨ [MSA Guest] Starting Waydroid session..."
  export WAYLAND_DISPLAY=/run/wayland-0
  export XDG_RUNTIME_DIR=/run
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user_bus.sock
  waydroid session start &
) &

# 10. Forward ADB ports over vsock 5555 and TCP 5555
(
  while true; do
    sleep 2
    IP=$(lxc-info -P /var/lib/waydroid/lxc -n waydroid -i 2>/dev/null | awk '{print $2}' | head -n 1)
    if [ -z "$IP" ]; then
      IP=$(python3 -c "import sys; sys.path.append('/usr/lib/waydroid'); from tools.helpers.net import get_device_ip_address; print(get_device_ip_address() or '')" 2>/dev/null || true)
    fi
    if [ -n "$IP" ]; then
      echo "🚀 [MSA Guest] Android container active at IP: $IP"
      echo "🔌 [MSA Guest] Exposing ADB on TCP:5555 and VSOCK:5555..."
      ( while true; do socat TCP-LISTEN:5555,fork,reuseaddr TCP:$IP:5555 2>/dev/null || true; sleep 1; done ) &
      ( while true; do socat VSOCK-LISTEN:5555,fork,reuseaddr TCP:$IP:5555 2>/dev/null || true; sleep 1; done ) &
      break
    fi
  done
) &

echo "✅ [MSA Guest] Subsystem initialization script complete. Shell ready."
exec /bin/sh
INIT_EOF

chmod +x /staging/init

echo '🔨 Formatting and populating rootfs.img with mke2fs...'
rm -f /out/rootfs.img
mke2fs -t ext4 -d /staging -b 4096 /out/rootfs.img 4G
chmod 644 /out/rootfs.img
echo '✅ rootfs.img created successfully!'
DOCKER_EOF

echo "🎉 MSA guest rootfs successfully built at: $ROOTFS_IMG"
file "$ROOTFS_IMG"
ls -lh "$ROOTFS_IMG"
