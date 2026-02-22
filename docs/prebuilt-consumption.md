# Using prebuilt media artifacts

This document shows how to consume release assets from `23doors/ffmpeg-lgpl-decoder`
in Rust (`winit/core`) and Flutter builds.

Each archive includes FFmpeg shared libraries and `libass` shared library with
pkg-config metadata under `lib/pkgconfig`.

## Asset naming

Each release publishes files with a stable name:

`ffmpeg-lgpl-decoder_<tag>_<target-id>_<triplet>.tar.gz`

Examples:

- `ffmpeg-lgpl-decoder_v0.1.0_linux-x64_x64-linux-dynamic.tar.gz`
- `ffmpeg-lgpl-decoder_v0.1.0_android-arm64_arm64-android-dynamic.tar.gz`

Checksums:

- `SHA256SUMS`
- `<archive>.sha256`

## Target mapping

- Linux x64: `target-id=linux-x64`, `triplet=x64-linux-dynamic`
- Windows x64: `target-id=windows-x64`, `triplet=x64-windows-dynamic`
- Windows x64 (GNU): `target-id=windows-gnu-x64`, `triplet=x64-windows-gnu-dynamic`
- macOS arm64: `target-id=macos-arm64`, `triplet=arm64-osx-dynamic`
- Android arm64: `target-id=android-arm64`, `triplet=arm64-android-dynamic`
- Android armv7: `target-id=android-armv7`, `triplet=arm-neon-android-dynamic`
- Android x64: `target-id=android-x64`, `triplet=x64-android-dynamic`
- iOS arm64: `target-id=ios-arm64`, `triplet=arm64-ios-dynamic`
- iOS simulator arm64: `target-id=ios-sim-arm64`, `triplet=arm64-ios-simulator-dynamic`

## Rust (winit/core)

1. Download + extract one archive (or all needed archives):

```bash
bash templates/common/fetch-prebuilt.sh \
  23doors/ffmpeg-lgpl-decoder \
  v0.1.0 \
  macos-arm64 \
  arm64-osx-dynamic \
  third_party/ffmpeg
```

2. Export build env for Cargo:

```bash
bash templates/rust/use-prebuilt.sh \
  arm64-osx-dynamic \
  third_party/ffmpeg
```

3. Build:

```bash
cargo build
```

If your native layer uses CMake, include:

- `templates/cmake/use_ffmpeg_prebuilt.cmake`

and call `target_link_ffmpeg_prebuilt(<target>)`.

## Flutter Android

Use the Gradle template:

- `templates/flutter/android/fetch_ffmpeg.gradle`

It downloads `android-arm64` + `android-armv7` + `android-x64` archives and copies `.so` files into
`src/main/jniLibs/<abi>`.

Set:

- `FFMPEG_RELEASE_REPO` (default `23doors/ffmpeg-lgpl-decoder`)
- `FFMPEG_RELEASE_TAG` (for example `v0.1.0`)

## Flutter macOS / iOS

Use:

```bash
bash templates/flutter/apple/fetch_ffmpeg_apple.sh \
  23doors/ffmpeg-lgpl-decoder \
  v0.1.0 \
  third_party/ffmpeg
```

For iOS distribution, prefer static libs or XCFramework packaging.
Current artifacts are dynamic-library oriented.

## Flutter desktop (Windows/Linux/macOS)

Use CMake integration template:

- `templates/cmake/use_ffmpeg_prebuilt.cmake`

Set:

- `FFMPEG_PREBUILT_DIR` to your extracted root (for example `third_party/ffmpeg`)
- `FFMPEG_TRIPLET` per target platform
