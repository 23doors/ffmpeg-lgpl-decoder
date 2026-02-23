#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <github-repo> <release-tag> <output-root>"
  echo "example: $0 23doors/ffmpeg-lgpl-decoder v0.1.0 third_party/ffmpeg"
  exit 2
fi

GITHUB_REPO="$1"
RELEASE_TAG="$2"
OUTPUT_ROOT="$3"

mkdir -p "${OUTPUT_ROOT}"

download_one() {
  local target_id="$1"
  local triplet="$2"
  local required="${3:-true}"
  local asset_name="ffmpeg-lgpl-decoder_${RELEASE_TAG}_${target_id}_${triplet}.tar.gz"
  local url="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${asset_name}"
  local archive_path="${OUTPUT_ROOT}/${asset_name}"

  if [[ ! -f "${archive_path}" ]]; then
    if ! curl -fL "${url}" -o "${archive_path}"; then
      rm -f "${archive_path}"
      if [[ "${required}" == "false" ]]; then
        echo "warning: optional archive not found: ${asset_name}" >&2
        return 0
      fi
      echo "error: failed to download required archive: ${asset_name}" >&2
      return 1
    fi
  fi

  if [[ ! -d "${OUTPUT_ROOT}/${triplet}" ]]; then
    tar -xzf "${archive_path}" -C "${OUTPUT_ROOT}"
  fi
}

download_one "macos-arm64" "arm64-osx-dynamic"
download_one "macos-x64" "x64-osx-dynamic" "false"
download_one "ios-arm64" "arm64-ios-dynamic"
download_one "ios-sim-arm64" "arm64-ios-simulator-dynamic"

echo "downloaded Apple prebuilts into ${OUTPUT_ROOT}"
echo "note: for iOS app distribution, prefer static libs/XCFramework packaging"
