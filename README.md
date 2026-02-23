# ffmpeg-lgpl-decoder

Portable FFmpeg LGPL-oriented build pack based on `vcpkg` + GitHub Actions.

This module is intentionally isolated so it can be copied to a dedicated repository
(`23doors/ffmpeg-lgpl-decoder`) with minimal changes.

## What this builds

- Shared FFmpeg libraries (`avcodec`, `avformat`, `avutil`, `swresample`, `swscale`)
- Shared `libass` library for subtitle rendering (`libass` + pkg-config metadata)
- Slim decode-only profile (no encoders, no muxers, no ffmpeg/ffprobe binaries)
- Hardware decode path enabled per platform (always-on profile):
  - macOS/iOS: VideoToolbox
  - Windows: D3D11VA + DXVA2
  - Linux: VAAPI
  - Android: MediaCodec decoders
- Decoder/protocol/demuxer parser whitelist focused on playback:
  - video: AV1, HEVC, H.264, VP9/VP8, MPEG-1/2, MPEG-4 Part 2, VC-1/WMV3, Theora, ProRes
  - audio: AAC/AAC-LATM, MP2/MP3, AC-3, E-AC-3, DTS (dca), TrueHD/MLP, Opus, Vorbis, FLAC, ALAC, APE, WavPack, WMA, common PCM (LE/BE, int/float, a-law, mu-law)
  - images: MJPEG, PNG, BMP, GIF, WebP
  - subtitles: SubRip, ASS/SSA, MOV text, WebVTT, PGS, DVB, DVD, XSUB, MicroDVD/MPL2/PJS/SAMI/STL/SubViewer/VPlayer/JACOsub/RealText
  - streaming/containers: MKV/Matroska/WebM, MOV/MP4, MPEG-TS/PS, AVI, ASF, FLV, MXF, WAV/AIFF/AU/CAF, OGG, FLAC, raw AC-3/E-AC-3/DTS, HLS (`m3u8`), DASH (`mpd`), RTSP/RTP/SDP
  - protocols: file/pipe/http/https/rtmp/rtmps/rtmpt/rtmpe/tcp/tls/udp/rtp/crypto

Platform-specific hardware options live in `config/targets/*.args` and are appended
automatically by `scripts/build-one.sh` based on triplet.

## CI matrix

- linux-x64
- windows-x64
- windows-gnu-x64
- macos-arm64
- android-arm64
- android-armv7
- android-x64
- ios-arm64
- ios-sim-arm64

Workflow file: `.github/workflows/ffmpeg-lgpl-decoder.yml`

## Release outputs

- CI artifacts are uploaded for each matrix build.
- On tag push (`v*`) or manual dispatch with `publish_release=true`, workflow also publishes
  GitHub Release assets (non-expiring):
  - `ffmpeg-lgpl-decoder_<tag>_<target-id>_<triplet>.tar.gz`
  - matching `.sha256`
  - aggregate `SHA256SUMS`

## Local run (example)

```bash
bash scripts/prepare-vcpkg.sh ./.vcpkg
./.vcpkg/bootstrap-vcpkg.sh -disableMetrics
bash scripts/build-one.sh ./.vcpkg x64-linux-dynamic .
bash scripts/verify-one.sh . x64-linux-dynamic
bash scripts/package-one.sh . x64-linux-dynamic ./out
```

On Windows, bootstrap with:

```powershell
.\.vcpkg\bootstrap-vcpkg.bat -disableMetrics
```

## Notes

- This is an engineering setup, not legal advice.
- The pipeline pins a `vcpkg` commit in `VCPKG_COMMIT`.
- A local overlay port (`overlay-ports/ffmpeg`) applies `FFMPEG_EXTRA_CONFIGURE_OPTIONS`.
- Prebuilt consumption templates live under `templates/` and `docs/prebuilt-consumption.md`.
