#!/usr/bin/env bash

set -euo pipefail

REPO_SLUG="${REPO_SLUG:-itsasheruwu/responder-v1}"
APP_NAME="${APP_NAME:-Responder}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TAG="${1:-latest}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v ditto >/dev/null 2>&1; then
  echo "ditto is required." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

archive_name="${APP_NAME}.app.zip"

if [[ "$TAG" == "latest" ]]; then
  download_url="https://github.com/${REPO_SLUG}/releases/latest/download/${archive_name}"
else
  download_url="https://github.com/${REPO_SLUG}/releases/download/${TAG}/${archive_name}"
fi

archive_path="${tmpdir}/${archive_name}"
app_path="${tmpdir}/${APP_NAME}.app"
target_path="${INSTALL_DIR}/${APP_NAME}.app"

echo "Downloading ${download_url}"
curl -fL --progress-bar "$download_url" -o "$archive_path"

echo "Expanding archive"
ditto -x -k "$archive_path" "$tmpdir"

if [[ ! -d "$app_path" ]]; then
  echo "Expected ${app_path} after extraction." >&2
  exit 1
fi

echo "Installing to ${target_path}"
rm -rf "$target_path"
cp -R "$app_path" "$target_path"
xattr -dr com.apple.quarantine "$target_path" 2>/dev/null || true

echo "${APP_NAME} installed at ${target_path}"
if [[ "$TAG" == "latest" ]]; then
  echo "This build came from the latest GitHub Release (${archive_name}), not necessarily the latest commit on the default branch. Publish a new release (or pass an explicit tag) to update."
fi
