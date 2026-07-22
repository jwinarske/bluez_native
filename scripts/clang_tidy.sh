#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${1:-build}"

if [[ ! -f "${BUILD_DIR}/compile_commands.json" ]]; then
    echo "ERROR: compile_commands.json not found in ${BUILD_DIR}."
    echo "Build the project first with -DCMAKE_EXPORT_COMPILE_COMMANDS=ON."
    exit 1
fi

CLANG_TIDY="clang-tidy-19"
if ! command -v "${CLANG_TIDY}" &>/dev/null; then
    CLANG_TIDY="clang-tidy"
fi

echo "Using: $(command -v "${CLANG_TIDY}")"

# Only run on project source files — exclude vendored Dart API headers,
# glaze_meta.h, and third_party/.
find "${ROOT_DIR}/native/src" "${ROOT_DIR}/native/include" \
    \( -name '*.cpp' -o -name '*.h' \) \
    ! -path '*/third_party/*' \
    ! -path '*/internal/*' \
    ! -name 'dart_api.h' \
    ! -name 'dart_api_dl.h' \
    ! -name 'dart_native_api.h' \
    ! -name 'dart_version.h' \
    ! -name 'glaze_meta.h' \
    -print | sort | \
    xargs "${CLANG_TIDY}" -p "${BUILD_DIR}" --warnings-as-errors='*' 2>&1

echo "clang-tidy passed."
