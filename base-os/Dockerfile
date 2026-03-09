# syntax=docker/dockerfile:1.5
# Build container for AirOS Base OS image
# Provides proper QEMU cross-arch chroot environment
#
# Build context must be the project root (airosV2/)
FROM ubuntu:22.04

LABEL maintainer="Airolit"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        qemu-user-static \
        binfmt-support \
        build-essential \
        bc \
        bison \
        flex \
        openssl \
        libssl-dev \
        git \
        wget \
        ca-certificates \
        uuid-runtime \
        sshpass \
        abootimg \
        binutils \
        cpio \
        cpp \
        device-tree-compiler \
        dosfstools \
        iproute2 \
        iputils-ping \
        lbzip2 \
        libxml2-utils \
        netcat \
        nfs-kernel-server \
        python3-yaml \
        rsync \
        udev \
        whois \
        xmlstarlet \
        gzip \
        file \
        gettext \
        openssh-client \
        pigz \
        zstd \
        kmod \
        vim \
        less && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /AirOS

# Copy all base-os build files including camera drivers
COPY base-os/ /AirOS/

# Copy project-level files needed by Phase 3
COPY docker-compose.yml versions.env .env /project/

ENTRYPOINT ["/AirOS/build-base-os.sh"]
