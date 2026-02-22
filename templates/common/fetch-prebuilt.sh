#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "usage: $0 <github-repo> <release-tag> <target-id> <triplet> <output-root>"
  echo "example: $0 23doors/ffmpeg-lgpl-decoder v0.1.0 macos-arm64 arm64-osx-dynamic third_party/ffmpeg"
  exit 2
fi

GITHUB_REPO="$1"
RELEASE_TAG="$2"
TARGET_ID="$3"
TRIPLET="$4"
OUTPUT_ROOT="$5"

mkdir -p "${OUTPUT_ROOT}"

ASSET_NAME="ffmpeg-lgpl-decoder_${RELEASE_TAG}_${TARGET_ID}_${TRIPLET}.tar.gz"
URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
ARCHIVE_PATH="${OUTPUT_ROOT}/${ASSET_NAME}"

curl -fL "${URL}" -o "${ARCHIVE_PATH}"
tar -xzf "${ARCHIVE_PATH}" -C "${OUTPUT_ROOT}"

echo "downloaded and extracted ${ASSET_NAME} into ${OUTPUT_ROOT}/${TRIPLET}"
