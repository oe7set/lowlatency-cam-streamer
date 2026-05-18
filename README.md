# lowlatency-cam-streamer

A small, single-container USB camera → browser pipeline that prefers picture
over packets: it adapts to bad WiFi instead of freezing, supports HD and
Full-HD on a Raspberry Pi without saturating the CPU, and exposes a standard
WHEP endpoint that any modern browser can play in ~60 lines of JavaScript.

Built for teleop / driving an autonomous robot, but nothing in here is
robot-specific - any UVC USB camera works.

## What's inside

```
camera (V4L2)
   │  capture as MJPEG (USB 2.0 fits 1080p30 only as MJPEG)
   ▼
GStreamer
   │  hardware H.264 encode (Pi v4l2h264enc / Intel VAAPI / x264 fallback)
   │  RTSP push, loopback only
   ▼
MediaMTX
   │  WHEP (WebRTC-HTTP Egress Protocol, IETF draft-ietf-wish-whep)
   ▼
browser  (RTCPeerConnection)
```

GStreamer and MediaMTX run in the same container, supervised by `tini`.
If either dies, the container exits and Docker restarts it.

The WebRTC/WHEP termination is owned by MediaMTX, so we don't need
`gst-plugins-rs` (`webrtcsink`, `rtspsrc2`, ...) in the image. That keeps
the build to plain Debian Bookworm packages, no Rust toolchain.

## Why not just MJPEG / mjpg-streamer?

| Problem with MJPEG over WiFi             | What WebRTC does instead                           |
|-----------------------------------------|----------------------------------------------------|
| Each frame is an independent JPEG       | H.264 only sends differences between frames        |
| 1080p30 needs ~30-60 Mbit/s             | Same picture in 4-6 Mbit/s, fits on flaky links    |
| Any packet loss freezes the image       | NACK retransmissions + FEC repair lost packets     |
| No way to slow down when the link suffers | TWCC feedback adapts the encoder bitrate live      |
| Browser uses `<img>` and prays          | `<video>` with a real jitter buffer                |

## Quickstart

### Test locally on a machine with a USB cam

```bash
docker run --rm \
  --privileged --network host \
  -v /dev:/dev \
  -e LATENCY_PROFILE=balanced \
  ghcr.io/oe7set/lowlatency-cam-streamer:1.0.13
```

Open `examples/index.html` in a browser, set the URL to
`http://<host-ip>:8889/cam/whep`, click *Connect*. You should see live video
within a second, with stats updating every second on the right.

### Add to a docker-compose stack

Copy `compose-snippet.yaml` into your stack and adjust the variables. See
that file for inline documentation of every option.

## Latency profiles

`LATENCY_PROFILE` picks sane defaults for the four knobs that trade latency
against robustness. Override any of them individually with the matching
`BITRATE_*`, `KEYFRAME_INTERVAL_S`, `FEC_PERCENT`, `JITTER_BUFFER_HINT_MS`
environment variables.

| Knob                       | `low` (close-range teleop) | `balanced` (default) | `robust` (bad WiFi)        |
|----------------------------|----------------------------|----------------------|----------------------------|
| Keyframe interval          | 1 s                        | 2 s                  | 4 s                        |
| FEC                        | off                        | ~10 %                | ~25 %                      |
| Jitter buffer hint         | 0 ms                       | 50 ms                | 150 ms                     |
| Bitrate floor / start / cap | 800 / 3000 / 6000 kbps    | 500 / 4000 / 6000    | 300 / 2000 / 8000          |
| Glass-to-glass on LAN      | 80-120 ms                  | 120-180 ms           | 200-350 ms                 |
| Behaviour at ~30 % loss    | breaks earlier             | quality dips, holds  | holds, slight detail loss  |

## Environment variables

All variables are optional. Profile defaults apply unless explicitly overridden.

| Variable                | Default        | Notes                                                  |
|-------------------------|----------------|--------------------------------------------------------|
| `LATENCY_PROFILE`       | `balanced`     | `low` / `balanced` / `robust`                          |
| `CAMERA_DEVICE`         | `/dev/video0`  | UVC input                                              |
| `CAMERA_WIDTH`          | `1920`         |                                                        |
| `CAMERA_HEIGHT`         | `1080`         |                                                        |
| `CAMERA_FRAMERATE`      | `30`           |                                                        |
| `CAMERA_INPUT_FORMAT`   | `mjpeg`        | `mjpeg` is required for 1080p over USB 2.0             |
| `ENCODER`               | `auto`         | `auto` / `pi` / `vaapi` / `software`                   |
| `BITRATE_MIN_KBPS`      | *from profile* |                                                        |
| `BITRATE_MAX_KBPS`      | *from profile* |                                                        |
| `BITRATE_START_KBPS`    | *from profile* | Initial encoder bitrate                                |
| `KEYFRAME_INTERVAL_S`   | *from profile* | Shorter = faster recovery, more bandwidth              |
| `FEC_PERCENT`           | *from profile* | Forward-error-correction redundancy (0-50 typical)     |
| `JITTER_BUFFER_HINT_MS` | *from profile* | Browser-side receiver buffer hint                      |
| `RTX_ENABLED`           | `true`         | NACK / retransmissions                                 |
| `WHEP_PORT`             | `8889`         | Browser endpoint                                       |
| `STREAM_NAME`           | `cam`          | Path component: `/<STREAM_NAME>/whep`                  |
| `ICE_HOST_CANDIDATE`    | `auto`         | Comma-separated host hints (e.g. Tailscale IP)         |
| `STUN_SERVER`           | empty          | Comma-separated STUN URIs; LAN/Tailscale needs none    |

## Encoder selection

`ENCODER=auto` detects at startup:

1. `/dev/video11` exists and reports a Pi codec (`bcm2835-codec` / `hantro` /
   `rpivid`) → **Pi V4L2 hardware encoder** (`v4l2h264enc`).
2. `/dev/dri/renderD128` exists and `vainfo` reports an `EncSlice`
   entrypoint → **Intel VAAPI** (`vah264enc`).
3. otherwise → **x264 software** (`tune=zerolatency speed-preset=ultrafast`).

Pin a specific path by setting `ENCODER` to `pi`, `vaapi`, or `software`.

## Verifying the deploy

1. **Container running.** `docker logs camera_streamer` should show the
   resolved configuration banner and `gst-launch` plus `mediamtx` lines.
2. **Pipeline alive.**
   `curl -i http://<host>:8889/cam/whep` returns either `405 Method Not
   Allowed` (POST-only) or a `Content-Type: application/sdp` body if you
   POST a real offer. The connection itself proves MediaMTX is up.
3. **Live video.** Open `examples/index.html`, click *Connect*. Stats card
   should show the H.264 codec, the camera resolution, and frame counters
   incrementing.
4. **Bad-network test.**

   ```bash
   sudo tc qdisc add dev wlan0 root netem loss 10% delay 50ms
   # bitrate visibly drops in the stats card, video keeps playing
   sudo tc qdisc del dev wlan0 root
   ```

## Pi-specific notes

> **Required before first run:** the Pi's GPU memory split must be
> raised. The default (76-128 MB depending on the model) is not enough
> for 1080p hardware H.264 encoding - the encoder fails STREAMON with
> errno 3 (ESRCH) and the pipeline dies after ~0.5 s. Set this once on
> the host, then reboot:
>
> ```bash
> # Check the current value first (typically 76-128 right out of the box)
> vcgencmd get_mem gpu
>
> # Append (or change) gpu_mem in the firmware config and reboot
> echo 'gpu_mem=256' | sudo tee -a /boot/firmware/config.txt
> sudo reboot
>
> # After reboot, this should now report 256M
> vcgencmd get_mem gpu
> ```

* The kernel must expose the V4L2 M2M H.264 encoder. Bookworm with kernel
  >= 6.1 ships it as `bcm2835-codec` and assigns it to `/dev/video11`.
* The hardware encoder is single-instance. If something else is already
  encoding (a second container, `libcamerasrc`, ...) the pipeline will
  fail with `EBUSY`. Check with `sudo fuser -v /dev/video11` on the host
  to see which process holds it.
* USB UVC at 1080p30 only works as MJPEG capture. Raw YUYV needs USB 3.0
  bandwidth.

## Pi with multiple network interfaces

If the Pi has more than one IP-bearing interface (e.g. `wlan0` to your LAN
plus `eth0` connected to the OpenMower mainboard / xCore at `172.16.78.1/24`),
the Linux kernel picks the source IP for outgoing UDP packets based on its
routing table. With `network_mode: host` the WebRTC UDP listener inherits
that decision, and on a misrouted setup the browser will receive media
packets with a source IP it never negotiated and silently drop them.

The container always binds the WebRTC UDP listener to the auto-detected
default-route IP, but the kernel still chooses the route. Diagnose with:

```bash
# What source IP / interface will the kernel use to reach the browser?
ip route get <browser-ip>
```

Expected: `... dev wlan0 src <pi-lan-ip> ...`. If the route goes via
`eth0` instead, add an explicit, higher-priority host route for the LAN:

```bash
sudo ip route add 192.168.1.0/24 dev wlan0 src 192.168.1.117 metric 1
# or persist via /etc/dhcpcd.conf / systemd-networkd
```

The container banner prints `WebRTC UDP bind` and the auto-detected ICE host
so you can verify which IP the server announces. If the browser shows
`bytesReceived: 0` in `chrome://webrtc-internals` despite an ICE
candidate-pair `succeeded`, this is almost always the cause.

## License

MIT - see [LICENSE](LICENSE).
