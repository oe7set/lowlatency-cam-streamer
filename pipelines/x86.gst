v4l2src device=${CAMERA_DEVICE} do-timestamp=true ! \
  image/jpeg,width=${CAMERA_WIDTH},height=${CAMERA_HEIGHT},framerate=${CAMERA_FRAMERATE}/1 ! \
  jpegparse ! jpegdec ! \
  videoconvert ! video/x-raw,format=NV12 ! \
  vah264enc \
    bitrate=${BITRATE_START_KBPS} \
    target-usage=7 \
    rate-control=cbr \
    key-int-max=${KEYFRAME_INTERVAL_FRAMES} \
    b-frames=0 ! \
  video/x-h264,profile=main ! \
  h264parse config-interval=-1 ! \
  rtspclientsink location=rtsp://127.0.0.1:8554/${STREAM_NAME} \
    protocols=tcp latency=0 \
    user-id=${RTSP_USER} user-pw=${RTSP_PASS}
