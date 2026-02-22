#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <manifest-root> <triplet>"
  exit 2
fi

MANIFEST_ROOT="${1//\\//}"
TRIPLET="$2"
PREFIX="${MANIFEST_ROOT}/vcpkg_installed/${TRIPLET}"
LOG_FILE="${MANIFEST_ROOT}/.buildtrees/ffmpeg/build-${TRIPLET}-rel-out.log"
CONFIG_H="${MANIFEST_ROOT}/.buildtrees/ffmpeg/${TRIPLET}-rel/config.h"
CONFIG_COMPONENTS_H="${MANIFEST_ROOT}/.buildtrees/ffmpeg/${TRIPLET}-rel/config_components.h"

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "missing build log: ${LOG_FILE}"
  exit 1
fi

if [[ ! -f "${CONFIG_H}" ]]; then
  echo "missing config header: ${CONFIG_H}"
  exit 1
fi

if [[ ! -f "${CONFIG_COMPONENTS_H}" ]]; then
  echo "missing config components header: ${CONFIG_COMPONENTS_H}"
  exit 1
fi

if ! grep -q "License: LGPL" "${LOG_FILE}"; then
  echo "expected LGPL build, got different license"
  exit 1
fi

if grep -q "License: GPL" "${LOG_FILE}" || grep -q "nonfree and unredistributable" "${LOG_FILE}"; then
  echo "build contains GPL/nonfree license marker"
  exit 1
fi

assert_define_in() {
  local file="$1"
  local macro="$2"
  local expected="$3"
  local line
  line="$(grep -E "^#define ${macro} " "${file}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    echo "missing ${macro} in ${file}"
    exit 1
  fi
  local value="${line##* }"
  if [[ "${value}" != "${expected}" ]]; then
    echo "expected ${macro}=${expected}, got ${value}"
    exit 1
  fi
}

assert_define_in "${CONFIG_H}" CONFIG_ENCODERS 0
assert_define_in "${CONFIG_H}" CONFIG_DECODERS 1
assert_define_in "${CONFIG_H}" CONFIG_MUXERS 0
assert_define_in "${CONFIG_H}" CONFIG_DEMUXERS 1
assert_define_in "${CONFIG_H}" CONFIG_PROTOCOLS 1
assert_define_in "${CONFIG_H}" CONFIG_PARSERS 1

assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_H264_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HEVC_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_AV1_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_VP9_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_AAC_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_OPUS_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_MJPEG_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_PNG_DECODER 1

assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_SUBRIP_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_ASS_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_MOVTEXT_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_WEBVTT_DECODER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_PGSSUB_DECODER 1

assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HTTP_PROTOCOL 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HTTPS_PROTOCOL 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_FILE_PROTOCOL 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_UDP_PROTOCOL 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_CRYPTO_PROTOCOL 1

assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HLS_DEMUXER 1
assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_DASH_DEMUXER 1

case "${TRIPLET}" in
  arm64-osx-dynamic)
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_H264_VIDEOTOOLBOX_HWACCEL 1
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HEVC_VIDEOTOOLBOX_HWACCEL 1
    ;;
  arm64-ios-dynamic|arm64-ios-simulator-dynamic)
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_H264_VIDEOTOOLBOX_HWACCEL 1
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HEVC_VIDEOTOOLBOX_HWACCEL 1
    ;;
  x64-windows-dynamic|x64-windows-gnu-dynamic)
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_H264_D3D11VA_HWACCEL 1
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HEVC_D3D11VA_HWACCEL 1
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_H264_DXVA2_HWACCEL 1
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HEVC_DXVA2_HWACCEL 1
    ;;
  x64-linux-dynamic)
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_H264_VAAPI_HWACCEL 1
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HEVC_VAAPI_HWACCEL 1
    ;;
  arm64-android-dynamic|arm-neon-android-dynamic|x64-android-dynamic)
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_H264_MEDIACODEC_DECODER 1
    assert_define_in "${CONFIG_COMPONENTS_H}" CONFIG_HEVC_MEDIACODEC_DECODER 1
    ;;
esac

if [[ "${TRIPLET}" == *windows* ]]; then
  shopt -s nullglob
  for lib in avcodec avformat avutil swresample swscale; do
    matches=(
      "${PREFIX}/bin/${lib}"*.dll
      "${PREFIX}/bin/lib${lib}"*.dll
      "${PREFIX}/tools/ffmpeg/bin/${lib}"*.dll
      "${PREFIX}/tools/ffmpeg/bin/lib${lib}"*.dll
    )
    if (( ${#matches[@]} == 0 )); then
      echo "missing runtime DLL for ${lib} in ${PREFIX}/bin or ${PREFIX}/tools/ffmpeg/bin"
      exit 1
    fi
  done
  shopt -u nullglob
else
  for lib in avcodec avformat avutil swresample swscale; do
    if ! compgen -G "${PREFIX}/lib/lib${lib}*.so*" > /dev/null \
      && ! compgen -G "${PREFIX}/lib/lib${lib}*.dylib" > /dev/null; then
      echo "missing runtime shared library for ${lib} in ${PREFIX}/lib"
      exit 1
    fi
  done
fi

echo "verification OK for ${TRIPLET}"
