#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-Responder}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-Responder}"
VERSION="${VERSION:-1.0.0}"
RELEASE_DIR="${ROOT_DIR}/release/${VERSION}"
BUILD_DIR="${ROOT_DIR}/build/${VERSION}"
ARCHIVE_NAME="${APP_NAME}.xcarchive"
ARCHIVE_PATH="${BUILD_DIR}/${ARCHIVE_NAME}"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
ZIP_PATH="${RELEASE_DIR}/${APP_NAME}.app.zip"
PKG_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}.pkg"
INSTALLER_PATH="${RELEASE_DIR}/install.sh"

rm -rf "$RELEASE_DIR" "$BUILD_DIR"
mkdir -p "$RELEASE_DIR" "$BUILD_DIR"

cd "$ROOT_DIR"
xcodegen generate

xcodebuild archive \
  -project Responder.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO

mkdir -p "$EXPORT_DIR"
cp -R "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
pkgbuild \
  --root "$EXPORT_DIR" \
  --install-location /Applications \
  "$PKG_PATH"
cp "${ROOT_DIR}/install.sh" "$INSTALLER_PATH"

printf '%s\n' "$ZIP_PATH" "$PKG_PATH" "$INSTALLER_PATH"
