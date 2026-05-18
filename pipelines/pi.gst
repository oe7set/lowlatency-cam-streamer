v4l2src device=${CAMERA_DEVICE} do-timestamp=true ! \
  image/jpeg,width=${CAMERA_WIDTH},height=${CAMERA_HEIGHT},framerate=${CAMERA_FRAMERATE}/1 ! \
  queue max-size-buffers=4 max-size-bytes=0 max-size-time=0 leaky=downstream ! \
  jpegdec ! \
  queue max-size-buffers=4 max-size-bytes=0 max-size-time=0 leaky=downstream ! \
  videoconvert ! video/x-raw,format=NV12 ! \
  queue max-size-buffers=4 max-size-bytes=0 max-size-time=0 leaky=downstream ! \
  v4l2h264enc \
    extra-controls=controls,h264_profile=1,h264_level=11,video_bitrate=${BITRATE_START_BPS},h264_i_frame_period=${KEYFRAME_INTERVAL_FRAMES},repeat_sequence_header=1 ! \
  video/x-h264,level=(string)4 ! \
  h264parse config-interval=-1 ! \
  queue max-size-buffers=8 max-size-bytes=0 max-size-time=0 ! \
  rtspclientsink location=rtsp://127.0.0.1:8554/${STREAM_NAME} \
    protocols=tcp latency=0 \
    user-id=${RTSP_USER} user-pw=${RTSP_PASS}
