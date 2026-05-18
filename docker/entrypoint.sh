#!/usr/bin/env bash
# Entrypoint: resolve LATENCY_PROFILE -> defaults, apply env overrides,
# pick the right encoder pipeline, render configs, supervise mediamtx + gstreamer.
set -Eeuo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

###############################################################################
# 1. Resolve the latency profile to default values.
#    Each var is only seeded if not already set, so explicit env overrides win.
###############################################################################
LATENCY_PROFILE="${LATENCY_PROFILE:-balanced}"
case "$LATENCY_PROFILE" in
  low)
    : "${KEYFRAME_INTERVAL_S:=1}"
    : "${FEC_PERCENT:=0}"
    : "${JITTER_BUFFER_HINT_MS:=0}"
    : "${BITRATE_MIN_KBPS:=800}"
    : "${BITRATE_MAX_KBPS:=6000}"
    : "${BITRATE_START_KBPS:=3000}"
    ;;
  balanced)
    : "${KEYFRAME_INTERVAL_S:=2}"
    : "${FEC_PERCENT:=10}"
    : "${JITTER_BUFFER_HINT_MS:=50}"
    : "${BITRATE_MIN_KBPS:=500}"
    : "${BITRATE_MAX_KBPS:=6000}"
    : "${BITRATE_START_KBPS:=4000}"
    ;;
  robust)
    : "${KEYFRAME_INTERVAL_S:=4}"
    : "${FEC_PERCENT:=25}"
    : "${JITTER_BUFFER_HINT_MS:=150}"
    : "${BITRATE_MIN_KBPS:=300}"
    : "${BITRATE_MAX_KBPS:=8000}"
    : "${BITRATE_START_KBPS:=2000}"
    ;;
  *)
    die "unknown LATENCY_PROFILE='$LATENCY_PROFILE' (expected: low|balanced|robust)"
    ;;
esac

###############################################################################
# 2. Camera + transport defaults.
###############################################################################
: "${CAMERA_DEVICE:=/dev/video0}"
: "${CAMERA_WIDTH:=1920}"
: "${CAMERA_HEIGHT:=1080}"
: "${CAMERA_FRAMERATE:=30}"
: "${CAMERA_INPUT_FORMAT:=mjpeg}"
: "${ENCODER:=auto}"
: "${WHEP_PORT:=8889}"
: "${STREAM_NAME:=cam}"
: "${ICE_HOST_CANDIDATE:=auto}"
# STUN is empty by default. On a flat LAN the host candidate is sufficient,
# and a srflx candidate from a public STUN server can actively hurt: it
# advertises the Pi's *public* WAN address, which the browser sitting in the
# same LAN cannot reach. We have observed Chrome flapping ICE state between
# 'succeeded' and 'disconnected' on Pi setups where the STUN reflexive
# address pointed at an unreachable IP. Operators on Tailscale, cellular,
# or cross-NAT paths can opt in by setting STUN_SERVER explicitly.
: "${STUN_SERVER:=}"
: "${RTX_ENABLED:=true}"

# Loopback credentials between gst and mediamtx. Random per container start
# so a stray client on the host network can't publish to our path even if
# they guess the path name.
: "${RTSP_USER:=streamer}"
: "${RTSP_PASS:=$(head -c 24 /dev/urandom | base64 | tr -d '+/=' | head -c 32)}"

# Derived: keyframe interval expressed in frames (encoders want frames).
KEYFRAME_INTERVAL_FRAMES=$(( CAMERA_FRAMERATE * KEYFRAME_INTERVAL_S ))
[ "$KEYFRAME_INTERVAL_FRAMES" -lt 1 ] && KEYFRAME_INTERVAL_FRAMES=1

# Derived: bitrate as bps (Pi v4l2h264enc) and kbps (x264/vah264).
BITRATE_START_BPS=$(( BITRATE_START_KBPS * 1000 ))

###############################################################################
# 3. ICE / STUN candidate lists for mediamtx YAML (must be valid YAML lists).
###############################################################################
build_yaml_list() {
  # Emit values as 'a, b, c' for inline YAML lists. Empty -> empty list.
  local IFS=','
  local out=""
  for item in $1; do
    item="$(echo "$item" | xargs)"
    [ -z "$item" ] && continue
    if [ -z "$out" ]; then out="$item"; else out="$out, $item"; fi
  done
  printf '%s' "$out"
}

build_ice_servers_block() {
  # Render comma-separated STUN URIs as a YAML block list of objects, the
  # shape mediamtx's webrtcICEServers2 expects:
  #   - url: stun:stun.l.google.com:19302
  # When empty, replace the indented placeholder with an inline empty list
  # so the surrounding key parses as `webrtcICEServers2: []`.
  local input="$1"
  if [ -z "$input" ]; then
    printf '  []'
    return
  fi
  local IFS=','
  local first=1
  for item in $input; do
    item="$(echo "$item" | xargs)"
    [ -z "$item" ] && continue
    if [ $first -eq 1 ]; then first=0; else printf '\n'; fi
    printf '  - url: %s' "$item"
  done
}

# Resolve the ICE host advertisement. The browser needs a candidate IP
# that's actually reachable from its network, and with `network_mode: host`
# we'd otherwise gather every host interface (docker-bridge, APIPA fallback,
# loopback...) and let the browser race them all to the timeout.
detect_lan_ip() {
  local iface ip
  iface="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -z "$iface" ] && return
  ip="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1)"
  printf '%s' "$ip"
}

ICE_HOST_SOURCE=""
if [ "$ICE_HOST_CANDIDATE" = "auto" ] || [ -z "$ICE_HOST_CANDIDATE" ]; then
  detected_ip="$(detect_lan_ip || true)"
  if [ -n "$detected_ip" ]; then
    ICE_HOST_CANDIDATE="$detected_ip"
    ICE_HOST_SOURCE="auto"
  else
    ICE_HOST_CANDIDATE=""
    ICE_HOST_SOURCE="all-interfaces"
  fi
else
  ICE_HOST_SOURCE="env"
fi

if [ -n "$ICE_HOST_CANDIDATE" ]; then
  ICE_HOST_CANDIDATE_LIST="$(build_yaml_list "$ICE_HOST_CANDIDATE")"
  ICE_USE_INTERFACES=no
  # When we know the LAN IP, bind the WebRTC UDP listener to it explicitly
  # instead of 0.0.0.0. With a 0.0.0.0 bind the kernel picks the source IP at
  # send time per-route, and on a multi-interface Pi (eth0=172.16.x for the
  # mainboard link, wlan0=192.168.x for the LAN) it sometimes sends RTP from
  # the wrong source IP - the browser then drops those packets because they
  # don't match the candidate it negotiated. Take the first IP from the list
  # if there are several (e.g. user supplied "tailscale,lan").
  WEBRTC_LISTEN_IP="${ICE_HOST_CANDIDATE%%,*}"
  WEBRTC_LISTEN_IP="$(echo "$WEBRTC_LISTEN_IP" | xargs)"
else
  ICE_HOST_CANDIDATE_LIST=""
  ICE_USE_INTERFACES=yes
  WEBRTC_LISTEN_IP=""
fi

WEBRTC_ICE_SERVERS_BLOCK="$(build_ice_servers_block "$STUN_SERVER")"

###############################################################################
# 4. Pick encoder pipeline.
###############################################################################
detect_encoder() {
  if [ -e /dev/video11 ] && v4l2-ctl -d /dev/video11 --info 2>/dev/null | grep -qi 'bcm2835-codec\|hantro\|rpivid'; then
    echo "pi"; return
  fi
  if [ -e /dev/dri/renderD128 ] && command -v vainfo >/dev/null 2>&1; then
    if vainfo --display drm --device /dev/dri/renderD128 2>/dev/null | grep -qi 'VAEntrypointEncSlice'; then
      echo "vaapi"; return
    fi
  fi
  echo "software"
}

if [ "$ENCODER" = "auto" ]; then
  ENCODER="$(detect_encoder)"
fi

case "$ENCODER" in
  pi)        PIPELINE_TEMPLATE=/opt/streamer/pipelines/pi.gst ;;
  vaapi)     PIPELINE_TEMPLATE=/opt/streamer/pipelines/x86.gst ;;
  software)  PIPELINE_TEMPLATE=/opt/streamer/pipelines/software.gst ;;
  *) die "unknown ENCODER='$ENCODER'" ;;
esac
[ -r "$PIPELINE_TEMPLATE" ] || die "pipeline template not readable: $PIPELINE_TEMPLATE"

###############################################################################
# 5. Render configs.
###############################################################################
export LATENCY_PROFILE CAMERA_DEVICE CAMERA_WIDTH CAMERA_HEIGHT CAMERA_FRAMERATE \
       CAMERA_INPUT_FORMAT ENCODER \
       BITRATE_MIN_KBPS BITRATE_MAX_KBPS BITRATE_START_KBPS BITRATE_START_BPS \
       KEYFRAME_INTERVAL_S KEYFRAME_INTERVAL_FRAMES \
       FEC_PERCENT JITTER_BUFFER_HINT_MS RTX_ENABLED \
       WHEP_PORT STREAM_NAME RTSP_USER RTSP_PASS \
       ICE_HOST_CANDIDATE_LIST WEBRTC_ICE_SERVERS_BLOCK ICE_USE_INTERFACES \
       WEBRTC_LISTEN_IP

MEDIAMTX_YML=/opt/streamer/config/mediamtx.yml
envsubst < /opt/streamer/config/mediamtx.yml.tmpl > "$MEDIAMTX_YML"

GST_PIPELINE="$(envsubst < "$PIPELINE_TEMPLATE" | tr -d '\\\n')"

###############################################################################
# 6. Print the resolved configuration once. Trivializes ops debugging.
###############################################################################
# GStreamer log level. Default is errors only - a healthy pipeline produces
# no output past the initial setup, so `docker logs` stays scannable for the
# things ops actually cares about (mediamtx WebRTC session events).
# When something breaks, raise it via the GST_DEBUG env. The most useful
# diagnostic recipe for this image is:
#   GST_DEBUG="*:2,GST_PADS:3,v4l2*:4,GST_TRACER:0"
# which surfaces caps-negotiation failures and v4l2 ioctl errors - the two
# silent killers we hit while bringing the Pi pipeline up.
export GST_DEBUG="${GST_DEBUG:-*:1}"

# Image version is baked at build time via ARG VERSION (see Dockerfile + GHA).
# Falls back to 'dev' for local builds.
IMAGE_VERSION="${IMAGE_VERSION:-dev}"

log "=============================================================="
log "  lowlatency-cam-streamer $IMAGE_VERSION"
log "  LATENCY_PROFILE   : $LATENCY_PROFILE"
log "  ENCODER           : $ENCODER  ($PIPELINE_TEMPLATE)"
log "  CAMERA            : $CAMERA_DEVICE @ ${CAMERA_WIDTH}x${CAMERA_HEIGHT}@${CAMERA_FRAMERATE}fps ($CAMERA_INPUT_FORMAT)"
log "  BITRATE           : start=${BITRATE_START_KBPS} min=${BITRATE_MIN_KBPS} max=${BITRATE_MAX_KBPS} kbps"
log "  KEYFRAME          : every ${KEYFRAME_INTERVAL_S}s ($KEYFRAME_INTERVAL_FRAMES frames)"
log "  FEC               : ${FEC_PERCENT}%"
log "  JITTER HINT       : ${JITTER_BUFFER_HINT_MS}ms"
log "  WHEP              : http://<host>:${WHEP_PORT}/${STREAM_NAME}/whep"
log "  RTSP loopback     : rtsp://127.0.0.1:8554/${STREAM_NAME}"
case "$ICE_HOST_SOURCE" in
  auto) log "  ICE host          : $ICE_HOST_CANDIDATE (auto-detected from default route)" ;;
  env)  log "  ICE host          : $ICE_HOST_CANDIDATE (from ICE_HOST_CANDIDATE env)" ;;
  *)    log "  ICE host          : auto-detect failed - announcing all interfaces" ;;
esac
log "  WebRTC UDP bind   : ${WEBRTC_LISTEN_IP:-0.0.0.0}:8189"
log "  STUN              : ${STUN_SERVER:-none}"
log "  GST_DEBUG         : $GST_DEBUG"
# Pi-only diagnostics: surface the two things that turn the bcm2835 H.264
# encoder's STREAMON ioctl into ESRCH (3) - too little GPU split memory or
# something else holding /dev/video11. Both are no-ops on x86 / non-Pi.
if [ "$ENCODER" = "pi" ]; then
  if command -v vcgencmd >/dev/null 2>&1; then
    log "  GPU memory        : $(vcgencmd get_mem gpu 2>/dev/null || echo unknown)"
  fi
  if [ -e /dev/video11 ] && command -v fuser >/dev/null 2>&1; then
    # `timeout 2s` guards against fuser hanging on Pi VPU locks. In
    # privileged Docker containers fuser walks /proc/*/fd via netlink
    # ioctls that block indefinitely when the bcm2835-codec driver
    # holds an exclusive lock - observed in v1.0.7 as a banner-only
    # restart loop where mediamtx never even started. Better to drop
    # the diagnostic line than to wedge the container.
    holders="$(timeout 2s fuser /dev/video11 2>/dev/null | tr -s ' ' || true)"
    log "  /dev/video11 held : ${holders:-none (or fuser timed out)}"
  fi
fi
log "=============================================================="

# Dump what the camera actually advertises - cheaper than guessing why
# v4l2src negotiates a different resolution than requested. We print the
# full list-formats-ext output (capped at 60 lines so the log stays
# scannable for cameras with very long format menus).
if [ -e "$CAMERA_DEVICE" ] && command -v v4l2-ctl >/dev/null 2>&1; then
  log "  camera capabilities ($CAMERA_DEVICE):"
  caps_output="$(v4l2-ctl -d "$CAMERA_DEVICE" --list-formats-ext 2>&1 | head -60 || true)"
  if [ -n "$caps_output" ]; then
    printf '%s\n' "$caps_output" | sed 's/^/    /' >&2
  else
    log "    (v4l2-ctl returned no output - device may not be ready yet)"
  fi
  log "=============================================================="
fi

###############################################################################
# 7. Supervise: mediamtx + gst-launch in parallel; if either dies, kill both
#    so tini propagates a non-zero exit and Docker restarts us cleanly.
###############################################################################
mediamtx_pid=""
gst_pid=""

shutdown() {
  local sig="$1"
  log "received $sig - shutting down"
  [ -n "$gst_pid" ]      && kill -TERM "$gst_pid"      2>/dev/null || true
  [ -n "$mediamtx_pid" ] && kill -TERM "$mediamtx_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 0
}
trap 'shutdown SIGTERM' SIGTERM
trap 'shutdown SIGINT'  SIGINT

log "starting mediamtx ..."
mediamtx "$MEDIAMTX_YML" &
mediamtx_pid=$!

# Wait for the RTSP listener to be ready before we start pushing frames.
# Otherwise GStreamer races mediamtx and exits with "Connection refused".
# Bails out fast and loud if mediamtx itself died (config rejected, port
# already in use, ...) instead of looping 50x with the same misleading
# "Connection refused" line that hides the real cause.
ready=0
for _ in $(seq 1 50); do
  if ! kill -0 "$mediamtx_pid" 2>/dev/null; then
    log "FATAL: mediamtx exited before its RTSP listener came up - check the"
    log "       error line printed above (typically a rejected config field)."
    wait "$mediamtx_pid" 2>/dev/null || true
    exit 1
  fi
  if exec 3<>/dev/tcp/127.0.0.1/8554 2>/dev/null; then
    exec 3<&- 3>&-
    ready=1
    break
  fi
  sleep 0.1
done
if [ $ready -eq 0 ]; then
  log "FATAL: mediamtx is alive but its RTSP listener didn't come up within 5s"
  kill -TERM "$mediamtx_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 1
fi

log "starting gstreamer pipeline ..."
log "  pipeline: $GST_PIPELINE"
# `-v` is REQUIRED here, not cosmetic. It looks like "verbose property
# notifications" but on the Pi bcm2835-codec path it keeps the event loop
# warm enough that rtpbin/rtpsession timestamps and drains RTP packets
# cleanly. Without `-v`, mediamtx happily accepts WebRTC sessions and
# reports the stream as online, but browsers receive zero playable bytes.
# Reproduced in v1.0.13 (no -v) vs v1.0.12 (with -v): identical pipeline,
# identical RTSP push, but only the `-v` build delivers a working stream.
# `-e` propagates EOS on shutdown so the pipeline drains cleanly.
# The grep filter discards the multi-KB RTP-session-stats blobs `-v` emits
# every second so `docker logs` stays scannable. Everything else
# (caps negotiation, errors, state changes) still passes through.
# shellcheck disable=SC2086
gst-launch-1.0 -v -e $GST_PIPELINE 2>&1 \
  | grep --line-buffered -v 'rtpsession0: stats =' &
gst_pid=$!

# Block on either child. Whichever exits first decides the container fate.
wait -n "$mediamtx_pid" "$gst_pid"
exit_code=$?
log "child exited with $exit_code - tearing down"
[ -n "$gst_pid" ]      && kill -TERM "$gst_pid"      2>/dev/null || true
[ -n "$mediamtx_pid" ] && kill -TERM "$mediamtx_pid" 2>/dev/null || true
wait 2>/dev/null || true
exit "$exit_code"
