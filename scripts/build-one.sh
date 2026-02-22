#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <vcpkg-root> <triplet> <manifest-root>"
  exit 2
fi

VCPKG_ROOT="$1"
TRIPLET="$2"
MANIFEST_ROOT="$3"

if [[ -x "${VCPKG_ROOT}/vcpkg" ]]; then
  VCPKG_CMD="${VCPKG_ROOT}/vcpkg"
elif [[ -x "${VCPKG_ROOT}/vcpkg.exe" ]]; then
  VCPKG_CMD="${VCPKG_ROOT}/vcpkg.exe"
else
  echo "vcpkg executable not found. bootstrap first in ${VCPKG_ROOT}"
  exit 1
fi

ARGS_FILE="${MANIFEST_ROOT}/config/ffmpeg-extra-configure.args"
if [[ ! -f "${ARGS_FILE}" ]]; then
  echo "missing configure args file: ${ARGS_FILE}"
  exit 1
fi

TARGET_ARGS_FILE="${MANIFEST_ROOT}/config/targets/${TRIPLET}.args"

EXTRA_OPTIONS=""
append_args_file() {
  local file_path="$1"
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "${line}" ]]; then
      continue
    fi
    EXTRA_OPTIONS+="${line} "
  done < "${file_path}"
}

append_args_file "${ARGS_FILE}"

if [[ -f "${TARGET_ARGS_FILE}" ]]; then
  append_args_file "${TARGET_ARGS_FILE}"
fi

export VCPKG_DISABLE_METRICS=1
export VCPKG_BUILD_TYPE=release
export FFMPEG_EXTRA_CONFIGURE_OPTIONS="${EXTRA_OPTIONS}"

if [[ -n "${VCPKG_KEEP_ENV_VARS:-}" ]]; then
  export VCPKG_KEEP_ENV_VARS="${VCPKG_KEEP_ENV_VARS};FFMPEG_EXTRA_CONFIGURE_OPTIONS"
else
  export VCPKG_KEEP_ENV_VARS="FFMPEG_EXTRA_CONFIGURE_OPTIONS"
fi

"${VCPKG_CMD}" install \
  --triplet "${TRIPLET}" \
  --x-manifest-root="${MANIFEST_ROOT}" \
  --overlay-triplets="${MANIFEST_ROOT}/triplets" \
  --overlay-ports="${MANIFEST_ROOT}/overlay-ports" \
  --x-install-root="${MANIFEST_ROOT}/vcpkg_installed" \
  --x-buildtrees-root="${MANIFEST_ROOT}/.buildtrees" \
  --x-packages-root="${MANIFEST_ROOT}/.packages" \
  --allow-unsupported
