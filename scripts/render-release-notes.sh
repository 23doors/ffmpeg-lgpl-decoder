#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <release-assets-dir> <tag> <output-file>"
  exit 2
fi

RELEASE_ASSETS_DIR="$1"
TAG="$2"
OUTPUT_FILE="$3"

archives=("${RELEASE_ASSETS_DIR}"/*.tar.gz)
if [[ ${#archives[@]} -eq 0 ]]; then
  echo "no archives found in ${RELEASE_ASSETS_DIR}"
  exit 1
fi

{
  printf '## FFmpeg LGPL decoder prebuilts\n\n'
  printf 'Tag: `%s`\n\n' "${TAG}"
  printf 'Assets are decode-only (no encoders, no muxers).\n\n'
  printf '### Archives\n'
  for archive in "${RELEASE_ASSETS_DIR}"/*.tar.gz; do
    printf -- '- `%s`\n' "$(basename "${archive}")"
  done
  printf '\nChecksums: `SHA256SUMS` and per-file `*.sha256`.\n'
} > "${OUTPUT_FILE}"

echo "wrote release notes to ${OUTPUT_FILE}"
