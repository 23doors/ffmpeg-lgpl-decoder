#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <vcpkg-root>"
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VCPKG_ROOT="$1"
COMMIT="$(tr -d '[:space:]' < "${MANIFEST_ROOT}/VCPKG_COMMIT")"

if [[ -z "${COMMIT}" ]]; then
  echo "VCPKG_COMMIT is empty"
  exit 1
fi

if [[ -d "${VCPKG_ROOT}/.git" ]]; then
  git -C "${VCPKG_ROOT}" fetch --depth 1 origin "${COMMIT}"
else
  git clone https://github.com/microsoft/vcpkg "${VCPKG_ROOT}"
fi

git -C "${VCPKG_ROOT}" checkout --force "${COMMIT}"
git -C "${VCPKG_ROOT}" clean -fdx
