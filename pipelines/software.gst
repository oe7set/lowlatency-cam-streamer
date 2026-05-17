v4l2src device=${CAMERA_DEVICE} do-timestamp=true ! \
  image/jpeg,width=${CAMERA_WIDTH},height=${CAMERA_HEIGHT},framerate=${CAMERA_FRAMERATE}/1 ! \
  jpegparse ! jpegdec ! \
  videoconvert ! video/x-raw,format=I420 ! \
  x264enc \
    tune=zerolatency \
    speed-preset=ultrafast \
    bitrate=${BITRATE_START_KBPS} \
    key-int-max=${KEYFRAME_INTERVAL_FRAMES} \
    bframes=0 \
    byte-stream=true \
    threads=2 ! \
  video/x-h264,profile=baseline ! \
  h264parse config-interval=-1 ! \
  rtspclientsink location=rtsp://127.0.0.1:8554/${STREAM_NAME} \
    protocols=tcp latency=0 \
    user-id=${RTSP_USER} user-pw=${RTSP_PASS}
