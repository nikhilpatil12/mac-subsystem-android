#!/usr/bin/env bash
# MSA GPU Acceleration Streamer (Guest MicroVM -> macOS Host Metal Bridge)
# Streams frames at 60fps over virtio-vsock port 5050 to CAMetalLayer
set -euo pipefail

HOST_CID=2
GPU_PORT=5050
FPS=60
SLEEP_INTERVAL="0.016" # ~60fps

echo "🎮 [MSA GPU Streamer] Starting hardware-accelerated GPU stream to host CID $HOST_CID port $GPU_PORT..."

python3 -c '
import socket
import struct
import time
import os
import subprocess

HOST_CID = 2
GPU_PORT = 5050
MAGIC = 0x4D534147 # "MSAG"
HEADER_FORMAT = ">HHIIIIQI" # ver, flags, w, h, stride, format, timestamp, payloadLength

def create_vsock_connection():
    try:
        # AF_VSOCK is socket.AF_VSOCK (40 on Linux)
        s = socket.socket(getattr(socket, "AF_VSOCK", 40), socket.SOCK_STREAM)
        s.connect((HOST_CID, GPU_PORT))
        print(f"Connected to macOS Host Metal GPU bridge at CID {HOST_CID}:{GPU_PORT}")
        return s
    except Exception as e:
        return None

def run():
    sock = None
    while True:
        if sock is None:
            sock = create_vsock_connection()
            if sock is None:
                time.sleep(1)
                continue

        # Fast direct frame capture
        try:
            # Check frame source
            cmd = ["screencap"]
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            out, _ = p.communicate()
            if len(out) > 16:
                w, h, fmt = struct.unpack("<III", out[:12])
                stride = w * 4
                raw_pixels = out[16:]
                payload_len = len(raw_pixels)

                timestamp = int(time.time() * 1000)
                # Pack 36-byte MSAG header
                # Magic: 4 bytes
                magic_bytes = struct.pack(">I", MAGIC)
                header_bytes = struct.pack(HEADER_FORMAT, 1, 0, w, h, stride, fmt, timestamp, payload_len)
                packet = magic_bytes + header_bytes + raw_pixels

                sock.sendall(packet)
            time.sleep(0.016)
        except (BrokenPipeError, ConnectionResetError, OSError):
            print("GPU Stream connection lost, reconnecting...")
            sock = None
            time.sleep(1)
        except Exception as e:
            time.sleep(0.05)

if __name__ == "__main__":
    run()
'
