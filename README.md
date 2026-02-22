# ffmpeg-lgpl-decoder

Portable FFmpeg LGPL-oriented build pack based on `vcpkg` + GitHub Actions.

This module is intentionally isolated so it can be copied to a dedicated repository
(`23doors/ffmpeg-lgpl-decoder`) with minimal changes.

## What this builds

- Shared FFmpeg libraries (`avcodec`, `avformat`, `avutil`, `swresample`, `swscale`)
- Slim decode-only profile (no encoders, no muxers, no ffmpeg/ffprobe binaries)
- Hardware decode path enabled per platform (always-on profile):
  - macOS/iOS: VideoToolbox
  - Windows: D3D11VA + DXVA2
  - Linux: VAAPI
  - Android: MediaCodec decoders
- Decoder/protocol/demuxer parser whitelist focused on playback:
  - video: AV1, HEVC, H.264, VP9
  - audio: AAC, Opus, Vorbis
  - images: MJPEG, PNG, BMP, GIF, WebP
  - subtitles: SubRip, ASS, MOV text, WebVTT, PGS
  - streaming: MKV/Matroska, HLS (`m3u8`), DASH (`mpd`), HTTPS
  - protocols: file/pipe/http/https/tcp/tls/udp/crypto

Platform-specific hardware options live in `config/targets/*.args` and are appended
automatically by `scripts/build-one.sh` based on triplet.

## CI matrix

- linux-x64
- windows-x64
- macos-arm64
- android-arm64
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
