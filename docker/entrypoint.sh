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

if [ "$ICE_HOST_CANDIDATE" = "auto" ] || [ -z "$ICE_HOST_CANDIDATE" ]; then
  ICE_HOST_CANDIDATE_LIST=""
else
  ICE_HOST_CANDIDATE_LIST="$(build_yaml_list "$ICE_HOST_CANDIDATE")"
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
       ICE_HOST_CANDIDATE_LIST WEBRTC_ICE_SERVERS_BLOCK

MEDIAMTX_YML=/opt/streamer/config/mediamtx.yml
envsubst < /opt/streamer/config/mediamtx.yml.tmpl > "$MEDIAMTX_YML"

GST_PIPELINE="$(envsubst < "$PIPELINE_TEMPLATE" | tr -d '\\\n')"

###############################################################################
# 6. Print the resolved configuration once. Trivializes ops debugging.
###############################################################################
# GStreamer log level. Plain integers like "2" only catch generic
# WARNING/ERROR; pipelines that die during caps negotiation or v4l2 ioctl
# require category-specific levels to surface a useful message. The default
# below names the categories we care about explicitly:
#   *:2                generic WARNING for everything
#   GST_PADS:3         caps negotiation (the silent killer)
#   v4l2*:4            v4l2src + v4l2h264enc internals
#   GST_TRACER:0       suppress tracer noise
# Override with GST_DEBUG=... for full custom control.
export GST_DEBUG="${GST_DEBUG:-*:2,GST_PADS:3,v4l2*:4,GST_TRACER:0}"

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
log "  ICE host hint     : ${ICE_HOST_CANDIDATE_LIST:-auto}"
log "  STUN              : ${STUN_SERVER:-none}"
log "  GST_DEBUG         : $GST_DEBUG"
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
# `-v` prints every caps negotiation step. Together with GST_DEBUG above
# this is what turns "Execution ended after 0:00:00.x" with no message
# into a usable error trace. Stderr is merged so docker logs sees
# everything in order.
# shellcheck disable=SC2086
gst-launch-1.0 -v -e $GST_PIPELINE 2>&1 &
gst_pid=$!

# Block on either child. Whichever exits first decides the container fate.
wait -n "$mediamtx_pid" "$gst_pid"
exit_code=$?
log "child exited with $exit_code - tearing down"
[ -n "$gst_pid" ]      && kill -TERM "$gst_pid"      2>/dev/null || true
[ -n "$mediamtx_pid" ] && kill -TERM "$mediamtx_pid" 2>/dev/null || true
wait 2>/dev/null || true
exit "$exit_code"
