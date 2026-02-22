#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <download-root> <release-assets-dir>"
  exit 2
fi

DOWNLOAD_ROOT="$1"
RELEASE_ASSETS_DIR="$2"

rm -rf "${RELEASE_ASSETS_DIR}"
mkdir -p "${RELEASE_ASSETS_DIR}"

shopt -s nullglob
for artifact_dir in "${DOWNLOAD_ROOT}"/*; do
  [[ -d "${artifact_dir}" ]] || continue
  for file in "${artifact_dir}"/*.tar.gz "${artifact_dir}"/*.sha256; do
    [[ -f "${file}" ]] || continue
    cp "${file}" "${RELEASE_ASSETS_DIR}/"
  done
done

archives=("${RELEASE_ASSETS_DIR}"/*.tar.gz)
if [[ ${#archives[@]} -eq 0 ]]; then
  echo "no release archives found in ${DOWNLOAD_ROOT}"
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${RELEASE_ASSETS_DIR}" && sha256sum *.tar.gz > SHA256SUMS)
else
  (cd "${RELEASE_ASSETS_DIR}" && shasum -a 256 *.tar.gz > SHA256SUMS)
fi

echo "prepared release assets in ${RELEASE_ASSETS_DIR}"
