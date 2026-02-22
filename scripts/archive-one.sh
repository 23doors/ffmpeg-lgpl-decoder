#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 <manifest-root> <triplet> <target-id> <version> [out-root]"
  exit 2
fi

MANIFEST_ROOT="${1//\\//}"
TRIPLET="$2"
TARGET_ID="$3"
VERSION="$4"
OUT_ROOT_RAW="${5:-${MANIFEST_ROOT}/out-release}"
OUT_ROOT="${OUT_ROOT_RAW//\\//}"

SRC_DIR="${MANIFEST_ROOT}/out/${TRIPLET}"
if [[ ! -d "${SRC_DIR}" ]]; then
  echo "missing packaged directory: ${SRC_DIR}"
  exit 1
fi

mkdir -p "${OUT_ROOT}"

ASSET_BASE="ffmpeg-lgpl-decoder_${VERSION}_${TARGET_ID}_${TRIPLET}"
ARCHIVE_PATH="${OUT_ROOT}/${ASSET_BASE}.tar.gz"

tar_flags=()
if tar --help 2>/dev/null | grep -q -- "--force-local"; then
  # GNU tar treats paths with ':' as remote without this flag (e.g. C:/ on Windows)
  tar_flags+=(--force-local)
fi

tar "${tar_flags[@]}" -C "${MANIFEST_ROOT}/out" -czf "${ARCHIVE_PATH}" "${TRIPLET}"

if command -v sha256sum >/dev/null 2>&1; then
  checksum_line="$(sha256sum "${ARCHIVE_PATH}")"
else
  checksum_line="$(shasum -a 256 "${ARCHIVE_PATH}")"
fi
checksum="${checksum_line%% *}"
printf "%s  %s\n" "${checksum}" "$(basename "${ARCHIVE_PATH}")" > "${ARCHIVE_PATH}.sha256"

echo "archived ${TRIPLET} into ${ARCHIVE_PATH}"
