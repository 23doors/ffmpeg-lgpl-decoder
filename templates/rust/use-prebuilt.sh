#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <triplet> <ffmpeg-root>"
  echo "example: $0 arm64-osx-dynamic third_party/ffmpeg"
  exit 2
fi

TRIPLET="$1"
FFMPEG_ROOT="$2"
PKGCONFIG_DIR="${FFMPEG_ROOT}/${TRIPLET}/lib/pkgconfig"

if [[ ! -d "${PKGCONFIG_DIR}" ]]; then
  echo "missing pkgconfig directory: ${PKGCONFIG_DIR}"
  exit 1
fi

if [[ -n "${PKG_CONFIG_PATH:-}" ]]; then
  export PKG_CONFIG_PATH="${PKGCONFIG_DIR}:${PKG_CONFIG_PATH}"
else
  export PKG_CONFIG_PATH="${PKGCONFIG_DIR}"
fi

if [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
  export CMAKE_PREFIX_PATH="${FFMPEG_ROOT}/${TRIPLET}:${CMAKE_PREFIX_PATH}"
else
  export CMAKE_PREFIX_PATH="${FFMPEG_ROOT}/${TRIPLET}"
fi

echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH}"
echo "CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"
echo "run cargo build (or cargo test) in this shell"
