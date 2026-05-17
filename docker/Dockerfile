# syntax=docker/dockerfile:1.7

# Multi-arch image: linux/amd64 + linux/arm64.
# Combines GStreamer (capture + HW H.264 encode) with MediaMTX (WHEP egress)
# in a single container. tini supervises both processes; if either dies
# the container exits and Docker restarts it.

ARG MEDIAMTX_VERSION=1.18.2

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS mediamtx-fetch
ARG TARGETARCH
ARG MEDIAMTX_VERSION
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tar \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) MTX_ARCH=linux_amd64 ;; \
      arm64) MTX_ARCH=linux_arm64v8 ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac; \
    curl -fL "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_${MTX_ARCH}.tar.gz" \
      -o mediamtx.tar.gz; \
    tar -xzf mediamtx.tar.gz mediamtx; \
    chmod +x mediamtx

FROM debian:bookworm-slim AS runtime
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      tini \
      ca-certificates \
      gettext-base \
      v4l-utils \
      gstreamer1.0-tools \
      gstreamer1.0-plugins-base \
      gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad \
      gstreamer1.0-plugins-ugly \
      gstreamer1.0-libav \
      gstreamer1.0-rtsp \
      gstreamer1.0-x \
 && rm -rf /var/lib/apt/lists/*

# VA-API stack only on amd64 (Pi has no VA-API).
RUN set -eux; \
    if [ "$TARGETARCH" = "amd64" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        gstreamer1.0-vaapi \
        va-driver-all \
        intel-media-va-driver-non-free \
        vainfo \
      && rm -rf /var/lib/apt/lists/*; \
    fi

COPY --from=mediamtx-fetch /tmp/mediamtx /usr/local/bin/mediamtx

RUN mkdir -p /opt/streamer/pipelines /opt/streamer/config
COPY pipelines/ /opt/streamer/pipelines/
COPY docker/mediamtx.yml.tmpl /opt/streamer/config/mediamtx.yml.tmpl
COPY docker/entrypoint.sh /opt/streamer/entrypoint.sh
RUN chmod +x /opt/streamer/entrypoint.sh

# WHEP egress (Browser pulls here). RTSP loopback stays on 8554 (host network).
EXPOSE 8889/tcp
EXPOSE 8554/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/streamer/entrypoint.sh"]
