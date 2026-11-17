#!/usr/bin/env bash
# The build, as it runs inside a sandbox.
#
# The script is started detached by `limrun-build.sh`: the platform ends a
# command that runs for a long time without saying anything, and the build
# of Chromium is nothing but that.  A detached build keeps running, and its
# log is read from the outside.
#
# The script brings the toolchain (the Rust compiler is already there — the
# service was built with it), runs the build of the engine and packs the
# bundle.  The last line of the log says whether it worked.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

TOOLCHAIN="${CEF_TOOLCHAIN_DIR:-${HOME}/trap-toolchain}"

echo "== the toolchain =="
"${HERE}/install-toolchain.sh" "${TOOLCHAIN}"
# shellcheck disable=SC1091
. "${TOOLCHAIN}/env.sh"

echo "== the engine =="
"${HERE}/build-android.sh"

echo "== the bundle =="
tar -czf cef-bundle.tar.gz -C cef-bundle .
sha256sum cef-bundle.tar.gz > cef-bundle.tar.gz.sha256
ls -la cef-bundle.tar.gz cef-bundle.tar.gz.sha256

echo "the bundle is ready"
