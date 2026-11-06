#!/usr/bin/env python3
"""
Downloads and extracts the latest official Waydroid AOSP (LineageOS) system and vendor images
for the target architecture (arm64 or x86_64).
Uses curl with resume (-C -) and retry logic to reliably handle CDN mirror drops.
"""

import sys
import os
import platform
import urllib.request
import json
import subprocess
import shutil
import time

def get_arch():
    machine = platform.machine().lower()
    if "arm64" in machine or "aarch64" in machine:
        return "arm64"
    elif "x86_64" in machine or "amd64" in machine:
        return "x86_64"
    return "arm64"

def download_with_curl(url, dest_path, max_attempts=5):
    print(f"⬇️ Downloading: {os.path.basename(dest_path)} (resumable)...")
    for attempt in range(1, max_attempts + 1):
        cmd = [
            "curl",
            "-L",
            "-C", "-",
            "--retry", "5",
            "--retry-delay", "3",
            "--connect-timeout", "30",
            "--progress-bar",
            "-o", dest_path,
            url
        ]
        ret = subprocess.call(cmd)
        if ret == 0:
            print("   ✅ Download complete.")
            return
        elif ret == 33: # Range not satisfiable (e.g. file already fully downloaded)
            print("   ✅ File fully downloaded.")
            return
        else:
            print(f"\n⚠️ Connection interrupted (curl exit code {ret}). Retrying attempt {attempt}/{max_attempts} in 3s...")
            time.sleep(3)
    raise RuntimeError(f"curl failed after {max_attempts} attempts.")

def extract_image(zip_path, img_name, target_dir):
    print(f"📦 Extracting {img_name}...")
    cmd = ["unzip", "-q", "-o", zip_path, img_name, "-d", target_dir]
    ret = subprocess.call(cmd)
    if ret != 0:
        raise RuntimeError(f"unzip failed to extract {img_name} from {zip_path}")
    if os.path.exists(zip_path):
        os.remove(zip_path)
    print(f"   ✅ {img_name} extracted.")

def fetch_images(target_dir=None, arch=None):
    if arch is None:
        arch = get_arch()
    if target_dir is None:
        target_dir = os.path.expanduser("~/.msa/waydroid")

    os.makedirs(target_dir, exist_ok=True)
    print(f"📱 Setting up Waydroid Android 13 (LineageOS 20) images for '{arch}'...")

    # 1. System image
    system_img_path = os.path.join(target_dir, "system.img")
    if not os.path.exists(system_img_path):
        system_json_url = f"https://ota.waydro.id/system/lineage/waydroid_{arch}/VANILLA.json"
        req = urllib.request.urlopen(system_json_url)
        sys_info = json.loads(req.read().decode())["response"][0]
        zip_url = sys_info["url"]
        temp_zip = os.path.join(target_dir, "system.zip")
        download_with_curl(zip_url, temp_zip)
        extract_image(temp_zip, "system.img", target_dir)
    else:
        print(f"   ✓ system.img already present ({os.path.getsize(system_img_path) // (1024*1024)} MB)")

    # 2. Vendor image
    vendor_img_path = os.path.join(target_dir, "vendor.img")
    if not os.path.exists(vendor_img_path):
        vendor_json_url = f"https://ota.waydro.id/vendor/waydroid_{arch}/MAINLINE.json"
        req = urllib.request.urlopen(vendor_json_url)
        vendor_info = json.loads(req.read().decode())["response"][0]
        zip_url = vendor_info["url"]
        temp_zip = os.path.join(target_dir, "vendor.zip")
        download_with_curl(zip_url, temp_zip)
        extract_image(temp_zip, "vendor.img", target_dir)
    else:
        print(f"   ✓ vendor.img already present ({os.path.getsize(vendor_img_path) // (1024*1024)} MB)")

    print(f"\n🎉 Waydroid AOSP images ready in: {target_dir}")

if __name__ == "__main__":
    target_arch = sys.argv[1] if len(sys.argv) > 1 else None
    fetch_images(arch=target_arch)
