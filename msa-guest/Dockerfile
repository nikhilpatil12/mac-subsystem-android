FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -qq -y \
    curl \
    ca-certificates \
    gnupg \
    procps \
    kmod \
    iptables \
    iproute2 \
    dnsmasq \
    lxc \
    socat \
    dbus \
    libglib2.0-0 \
    python3 \
    python3-pip \
    e2fsprogs \
    tar \
    xz-utils \
    net-tools \
    isc-dhcp-client \
    systemd \
    systemd-sysv \
    udev \
    dbus-user-session \
    && rm -rf /var/lib/apt/lists/*

RUN curl -s https://repo.waydro.id | bash && \
    apt-get update -qq && \
    apt-get install -qq -y waydroid && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /root
