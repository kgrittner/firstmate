#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
#
# Selects the release artifact for the current platform (uname -s / uname -m):
#   Linux x86_64          -> shellcheck-v<V>.linux.x86_64.tar.xz
#   Darwin arm64          -> shellcheck-v<V>.darwin.aarch64.tar.xz
#   Windows (MSYS/Cygwin) -> shellcheck-v<V>.zip, installed as shellcheck.exe
#     (Git Bash and CI resolve "shellcheck" to shellcheck.exe on PATH)
# Each artifact is verified against its per-platform pinned SHA256 below.
# Unsupported platforms fail with an explicit error before downloading.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}

OS="$(uname -s)"
MACHINE="$(uname -m)"
case "$OS/$MACHINE" in
  Linux/x86_64)
    SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
    BINARY_NAME=shellcheck
    ;;
  Darwin/arm64)
    SHA256=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
    ARCHIVE="shellcheck-v${VERSION}.darwin.aarch64.tar.xz"
    BINARY_NAME=shellcheck
    ;;
  MINGW*/*|MSYS*/*|CYGWIN*/*)
    SHA256=8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e
    ARCHIVE="shellcheck-v${VERSION}.zip"
    BINARY_NAME=shellcheck.exe
    ;;
  *)
    printf 'fm-install-shellcheck.sh: unsupported platform %s/%s\n' "$OS" "$MACHINE" >&2
    exit 1
    ;;
esac

URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP/$ARCHIVE"
ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
case "$ARCHIVE" in
  *.zip)
    # The Windows zip is flat: shellcheck.exe sits at the archive root.
    unzip -q "$TMP/$ARCHIVE" "$BINARY_NAME" -d "$TMP"
    EXTRACTED="$TMP/$BINARY_NAME"
    ;;
  *)
    tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
    EXTRACTED="$TMP/shellcheck-v${VERSION}/$BINARY_NAME"
    ;;
esac
mkdir -p "$DESTINATION"
install -m 0755 "$EXTRACTED" "$DESTINATION/$BINARY_NAME"
"$DESTINATION/$BINARY_NAME" --version
