# airos-flight: Flight controller container for Jetson Orin NX
# Runs 12+ processes (ACC, FC, mavlink-router, etc.) under s6-overlay
# with an internal D-Bus daemon for inter-process communication

# ---------------------------------------------------------------------------
# Stage 1 - Build mavlink-router from source
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS mavlink-router-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        meson \
        ninja-build \
        build-essential \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

ARG MAVLINK_ROUTER_VERSION=master

RUN git clone https://github.com/mavlink-router/mavlink-router.git /tmp/mavlink-router \
    && cd /tmp/mavlink-router \
    && git checkout ${MAVLINK_ROUTER_VERSION} \
    && git submodule update --recursive --init \
    && meson setup build . \
    && ninja -j$(nproc) -C build

# Output: /tmp/mavlink-router/build/src/mavlink-routerd

# ---------------------------------------------------------------------------
# Stage 2 - Build ACC (Airolit Component Controller)
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS acc-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        build-essential \
        cmake \
        ninja-build \
        python3 \
        python3-venv \
        python3-dev \
        pybind11-dev \
        libprotobuf-dev \
        protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

ARG ACC_VERSION=v1.5.2
ARG ACC_REPO=https://github.com/Airolit/Airolit_Component_Controller.git

RUN git clone ${ACC_REPO} /opt/acc \
    && cd /opt/acc \
    && git checkout ${ACC_VERSION} \
    && git submodule update --recursive --init

# Build ATP shared library
RUN cd /opt/acc && bash build_atp.sh

# Create venv and install Python dependencies
RUN cd /opt/acc \
    && python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir --prefer-binary lxml \
    && .venv/bin/pip install --no-cache-dir -r requirements_orin.txt

# Apply Blinka SPI1 patches for Jetson Orin NX
RUN echo '\n\
SCLK_1 = pin.SPI1_SCLK\n\
MOSI_1 = pin.SPI1_MOSI\n\
MISO_1 = pin.SPI1_MISO\n' \
    >> /opt/acc/.venv/lib/python3.10/site-packages/adafruit_blinka/board/nvidia/jetson_orin_nx.py

RUN echo '\n\
SPI1_SCLK = Pin((0, 115))\n\
SPI1_MOSI = Pin((0, 117))\n\
SPI1_MISO = Pin((0, 119))\n' \
    >> /opt/acc/.venv/lib/python3.10/site-packages/adafruit_blinka/microcontroller/tegra/t234/pin.py

# Patch busio.py spiPorts to include SPI1
RUN BUSIO=/opt/acc/.venv/lib/python3.10/site-packages/busio.py \
    && if [ -f "$BUSIO" ]; then \
        sed -i 's/spiPorts = (/spiPorts = (\n    (board.SCLK_1, board.MOSI_1, board.MISO_1),/' "$BUSIO"; \
    fi

# Output: /opt/acc/ with full source + .venv

# ---------------------------------------------------------------------------
# Stage 3 - Build nmea_over_udp
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS nmea-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

ARG NMEA_VERSION=v0.6.4

RUN git clone https://github.com/Airolit/nmea_over_udp.git /opt/nmea \
    && cd /opt/nmea \
    && git checkout ${NMEA_VERSION} \
    && python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt

# Output: /opt/nmea/

# ---------------------------------------------------------------------------
# Stage 4 - Build mavlink_logger
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS mavlink-logger-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

ARG MAVLINK_LOGGER_VERSION=master

RUN git clone https://github.com/Airolit/mavlink_logger.git /opt/mavlink-logger \
    && cd /opt/mavlink-logger \
    && git checkout ${MAVLINK_LOGGER_VERSION} \
    && python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt

# Output: /opt/mavlink-logger/

# ---------------------------------------------------------------------------
# Stage 5 - Build mavlink_sender
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS mavlink-sender-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

ARG MAVLINK_SENDER_VERSION=master

RUN git clone https://github.com/Airolit/mavlink_sender.git /opt/mavlink-sender \
    && cd /opt/mavlink-sender \
    && git checkout ${MAVLINK_SENDER_VERSION} \
    && python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt

# Output: /opt/mavlink-sender/

# ---------------------------------------------------------------------------
# Stage 6 - Runtime image
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS runtime

ARG S6_OVERLAY_VERSION=3.2.0.2

# Runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        dbus \
        libdbus-1-3 \
        libgpiod2 \
        v4l-utils \
        libprotobuf23 \
        procps \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# s6-overlay v3
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-aarch64.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-aarch64.tar.xz \
    && rm -f /tmp/s6-overlay-*.tar.xz

# mavlink-routerd binary from stage 1
COPY --from=mavlink-router-builder /tmp/mavlink-router/build/src/mavlink-routerd /usr/bin/mavlink-routerd

# Application code from builder stages
COPY --from=acc-builder /opt/acc /opt/acc
COPY --from=nmea-builder /opt/nmea /opt/nmea
COPY --from=mavlink-logger-builder /opt/mavlink-logger /opt/mavlink-logger
COPY --from=mavlink-sender-builder /opt/mavlink-sender /opt/mavlink-sender

# D-Bus configuration (container-internal bus)
COPY configs/dbus/ /etc/dbus-1/

# mavlink-router configuration
RUN mkdir -p /etc/mavlink-router
COPY configs/mavlink-router.conf /etc/mavlink-router/mavlink-router.conf

# Replace ACC systemd integration with s6-overlay shim
COPY patches/s6-systemd-shim.py /opt/acc/src/ACC/dbus/systemd.py

# s6 service definitions
COPY rootfs/ /

# Healthcheck script
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

# Ensure all run scripts and healthcheck are executable
RUN chmod +x \
    /etc/s6-overlay/s6-rc.d/dbus-daemon/run \
    /etc/s6-overlay/s6-rc.d/mavlink-router/run \
    /etc/s6-overlay/s6-rc.d/acc/run \
    /etc/s6-overlay/s6-rc.d/fc/run \
    /etc/s6-overlay/s6-rc.d/airolight/run \
    /etc/s6-overlay/s6-rc.d/peripheral-controller/run \
    /etc/s6-overlay/s6-rc.d/tether-switcher/run \
    /etc/s6-overlay/s6-rc.d/ev-control/run \
    /etc/s6-overlay/s6-rc.d/heading-offset-est/run \
    /etc/s6-overlay/s6-rc.d/mavlink-logger/run \
    /etc/s6-overlay/s6-rc.d/mavlink-sender/run \
    /etc/s6-overlay/s6-rc.d/nmea-over-udp/run \
    /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/init"]

LABEL org.opencontainers.image.title="airos-flight" \
      org.opencontainers.image.description="Flight controller container: ACC, FC, mavlink-router, and supporting services on Jetson Orin NX" \
      org.opencontainers.image.vendor="Airolit"
