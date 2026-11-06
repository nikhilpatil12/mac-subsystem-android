.PHONY: all build test clean setup-guest download-android build-kernel install

BUILD_DIR = build
HOST_DIR = msa-host
ENTITLEMENTS = $(HOST_DIR)/entitlements.plist

ARCH := $(shell uname -m)
ifeq ($(ARCH),arm64)
    ALPINE_ARCH = aarch64
else
    ALPINE_ARCH = x86_64
endif

all: build

build:
	@echo "🔨 Building Mac Subsystem for Android (MSA)..."
	cd $(HOST_DIR) && swift build -c release
	mkdir -p $(BUILD_DIR)/bin
	cp $(HOST_DIR)/.build/release/msa $(BUILD_DIR)/bin/
	cp $(HOST_DIR)/.build/release/msa-cli $(BUILD_DIR)/bin/
	@echo "🔏 Signing binaries with virtualization entitlements..."
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/bin/msa
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/bin/msa-cli
	@echo "✅ Binaries built and signed in $(BUILD_DIR)/bin/"

test:
	@echo "🧪 Running unit tests..."
	cd $(HOST_DIR) && swift test

setup-guest:
	@echo "📦 Setting up MSA guest directory in ~/.msa for $(ALPINE_ARCH)..."
	mkdir -p $(HOME)/.msa
	@if [ ! -f $(HOME)/.msa/vmlinuz ]; then \
		echo "⬇️ Downloading Linux kernel..."; \
		curl -Lo $(HOME)/.msa/vmlinuz.tmp https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/$(ALPINE_ARCH)/netboot/vmlinuz-virt; \
		if [ "$(ALPINE_ARCH)" = "aarch64" ]; then \
			echo "Decompressing raw ARM64 kernel Image..."; \
			python3 -c 'import zlib; data = open("$(HOME)/.msa/vmlinuz.tmp", "rb").read(); idx = data.find(b"\x1f\x8b\x08"); open("$(HOME)/.msa/vmlinuz", "wb").write(zlib.decompressobj(wbits=31).decompress(data[idx:]))'; \
			rm $(HOME)/.msa/vmlinuz.tmp; \
		else \
			mv $(HOME)/.msa/vmlinuz.tmp $(HOME)/.msa/vmlinuz; \
		fi; \
	fi
	@if [ ! -f $(HOME)/.msa/initrd.img ]; then \
		echo "⬇️ Downloading initramfs..."; \
		curl -Lo $(HOME)/.msa/initrd.img https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/$(ALPINE_ARCH)/netboot/initramfs-virt; \
	fi
	@if [ ! -f $(HOME)/.msa/rootfs.img ]; then \
		echo "Creating rootfs.img storage disk..."; \
		dd if=/dev/zero of=$(HOME)/.msa/rootfs.img bs=1m count=512; \
	fi
	@echo "✅ Guest setup complete in ~/.msa/"

download-android:
	@echo "📱 Fetching official Waydroid Android 13 images..."
	python3 tools/fetch-waydroid-images.py

build-kernel:
	@echo "🔨 Compiling custom Linux kernel with binderfs..."
	./tools/build-kernel.sh

install: build
	@echo "🚀 Installing msa and msa-cli to /usr/local/bin..."
	sudo cp $(BUILD_DIR)/bin/msa /usr/local/bin/
	sudo cp $(BUILD_DIR)/bin/msa-cli /usr/local/bin/
	@echo "✅ Installed successfully."

clean:
	cd $(HOST_DIR) && swift package clean
	rm -rf $(BUILD_DIR)
