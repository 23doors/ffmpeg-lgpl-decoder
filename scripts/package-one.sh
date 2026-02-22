#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <manifest-root> <triplet> <out-root>"
  exit 2
fi

MANIFEST_ROOT="$1"
TRIPLET="$2"
OUT_ROOT="$3"

PREFIX="${MANIFEST_ROOT}/vcpkg_installed/${TRIPLET}"
OUT_DIR="${OUT_ROOT}/${TRIPLET}"
LOG_PREFIX="${MANIFEST_ROOT}/.buildtrees/ffmpeg/build-${TRIPLET}-rel"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

for dir in bin include lib share tools; do
  if [[ -d "${PREFIX}/${dir}" ]]; then
    mkdir -p "${OUT_DIR}/${dir}"
    cp -a "${PREFIX}/${dir}/." "${OUT_DIR}/${dir}/"
  fi
done

mkdir -p "${OUT_DIR}/config"
cp "${MANIFEST_ROOT}/config/ffmpeg-extra-configure.args" "${OUT_DIR}/config/"

mkdir -p "${OUT_DIR}/logs"
for suffix in out err; do
  if [[ -f "${LOG_PREFIX}-${suffix}.log" ]]; then
    cp "${LOG_PREFIX}-${suffix}.log" "${OUT_DIR}/logs/"
  fi
done

if [[ -f "${MANIFEST_ROOT}/.buildtrees/ffmpeg/${TRIPLET}-rel/config.h" ]]; then
  cp "${MANIFEST_ROOT}/.buildtrees/ffmpeg/${TRIPLET}-rel/config.h" "${OUT_DIR}/logs/ffmpeg-config.h"
fi

if [[ -f "${MANIFEST_ROOT}/.buildtrees/ffmpeg/${TRIPLET}-rel/config_components.h" ]]; then
  cp "${MANIFEST_ROOT}/.buildtrees/ffmpeg/${TRIPLET}-rel/config_components.h" "${OUT_DIR}/logs/ffmpeg-config-components.h"
fi

BUILD_TIME_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
VCPKG_COMMIT="$(tr -d '[:space:]' < "${MANIFEST_ROOT}/VCPKG_COMMIT")"

cat > "${OUT_DIR}/build-manifest.json" <<EOF
{
  "triplet": "${TRIPLET}",
  "build_time_utc": "${BUILD_TIME_UTC}",
  "vcpkg_commit": "${VCPKG_COMMIT}",
  "profile": "lgpl-decode-only"
}
EOF

echo "packaged ${TRIPLET} into ${OUT_DIR}"
