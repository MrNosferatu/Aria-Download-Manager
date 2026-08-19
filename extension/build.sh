#!/usr/bin/env bash
# Package the extension. Everything here runs through web-ext, fetched on
# demand with npx so there is nothing to install first.
#
#   ./build.sh lint     validate the sources the way AMO will
#   ./build.sh build    -> dist/aria2c_manager-<version>.zip  (upload this to AMO)
#   ./build.sh sign     -> dist/*.xpi, signed via your AMO API credentials
#   ./build.sh run      launch a scratch Firefox with the extension loaded
#
# `sign` needs credentials from https://addons.mozilla.org/developers/addon/api/key/
#   export WEB_EXT_API_KEY=user:12345678:123
#   export WEB_EXT_API_SECRET=...
# Use `sign unlisted` for a self-hosted .xpi, or `sign listed` to push a new
# version to an existing AMO listing.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p dist

version=$(python3 -c "import json; print(json.load(open('manifest.json'))['version'])")

case "${1:-build}" in
  lint)
    npx --yes web-ext lint --source-dir . --ignore-files 'dist/**' 'build.sh' 'store/**' 'README.md'
    ;;
  build)
    npx --yes web-ext build --source-dir . --artifacts-dir dist --overwrite-dest \
      --ignore-files 'dist/**' 'build.sh' 'store/**' 'README.md'
    echo "built dist/ for version $version"
    ;;
  sign)
    channel="${2:-unlisted}"
    : "${WEB_EXT_API_KEY:?set WEB_EXT_API_KEY (see the header of this script)}"
    : "${WEB_EXT_API_SECRET:?set WEB_EXT_API_SECRET}"
    npx --yes web-ext sign --source-dir . --artifacts-dir dist --channel "$channel" \
      --ignore-files 'dist/**' 'build.sh' 'store/**' 'README.md'
    ;;
  run)
    npx --yes web-ext run --source-dir . --target firefox-desktop
    ;;
  *)
    echo "usage: $0 {lint|build|sign [unlisted|listed]|run}" >&2
    exit 2
    ;;
esac
