# airos-video: RTSP streaming container for Jetson Orin NX
# Runs MediaMTX + GStreamer camera pipelines under s6-overlay

ARG MEDIAMTX_VERSION=v1.9.3

# ---------------------------------------------------------------------------
# Stage 1 – download MediaMTX arm64 binary
# ---------------------------------------------------------------------------
FROM alpine:3.20 AS mediamtx-dl
ARG MEDIAMTX_VERSION
RUN wget -qO- \
    "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64v8.tar.gz" \
    | tar xz -C /usr/local/bin mediamtx

# ---------------------------------------------------------------------------
# Stage 2 – runtime image
# ---------------------------------------------------------------------------
FROM nvcr.io/nvidia/l4t-base:r36.4.0 AS runtime

ARG MEDIAMTX_VERSION
ARG S6_OVERLAY_VERSION=3.2.0.2

# GStreamer + utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-rtsp \
        libgstreamer1.0-0 \
        v4l-utils \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# s6-overlay v3
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-aarch64.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-aarch64.tar.xz \
    && rm -f /tmp/s6-overlay-*.tar.xz

# MediaMTX binary from stage 1
COPY --from=mediamtx-dl /usr/local/bin/mediamtx /usr/local/bin/mediamtx

# MediaMTX configuration
COPY configs/mediamtx.yml /etc/mediamtx/mediamtx.yml

# s6 service definitions
COPY rootfs/ /

# Healthcheck helper
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

# Ensure run scripts and healthcheck are executable
RUN chmod +x \
    /etc/s6-overlay/s6-rc.d/mediamtx/run \
    /etc/s6-overlay/s6-rc.d/ar0234-stream/run \
    /etc/s6-overlay/s6-rc.d/imx678-stream/run \
    /usr/local/bin/healthcheck.sh

ENV ENABLE_AR0234=true

ENTRYPOINT ["/init"]

LABEL org.opencontainers.image.title="airos-video" \
      org.opencontainers.image.description="RTSP streaming for AR0234 and IMX678 cameras on Jetson Orin NX" \
      org.opencontainers.image.version="${MEDIAMTX_VERSION}" \
      org.opencontainers.image.vendor="Airolit"
