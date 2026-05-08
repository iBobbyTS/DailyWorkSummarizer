#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/DeskBrief.xcarchive"
APP_PATH="${BUILD_DIR}/DeskBrief.app"
ARCHIVED_APP_PATH="${ARCHIVE_PATH}/Products/Applications/DeskBrief.app"

PROJECT="${PROJECT:-DeskBrief.xcodeproj}"
SCHEME="${SCHEME:-DeskBrief}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/DeskBriefArchiveDerivedData}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"

cd "${ROOT_DIR}"
mkdir -p "${BUILD_DIR}"

rm -rf "${ARCHIVE_PATH}" "${APP_PATH}"

xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED}"

if [[ ! -d "${ARCHIVED_APP_PATH}" ]]; then
  echo "error: archived app not found at ${ARCHIVED_APP_PATH}" >&2
  exit 1
fi

ditto "${ARCHIVED_APP_PATH}" "${APP_PATH}"

echo "Archive: ${ARCHIVE_PATH}"
echo "App: ${APP_PATH}"
