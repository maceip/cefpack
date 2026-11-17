#!/usr/bin/env bash
# The build, as it runs inside a sandbox.
#
# The script is started detached by `limrun-build.sh`: the platform ends a
# command that runs for a long time without saying anything, and the build
# of Chromium is nothing but that.  A detached build keeps running, and its
# log is read from the outside.
#
# The script runs the build of the engine and packs the bundle.  The
# toolchain comes with the build, in the order that the memory of the
# container allows.  The last line of the log says whether it worked.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

# The toolchain is **not** installed here.
#
# The build of the engine is in the order that the memory of the container
# allows, and that order is in `build-android.sh`: the Rust compiler, then
# the checkout of the sources, then the NDK, the SDK and depot_tools.  The
# checkout of the sources writes tens of gigabytes through the memory of the
# container, and it has to happen while the container holds nothing but the
# compiler of the service.  Installing the three gigabytes of the toolchain
# before the checkout takes that headroom away from the one step that
# needs it.
#
# The last line of the log says whether the build worked.

echo "== the engine =="
"${HERE}/build-android.sh"

echo "== the bundle =="
tar -czf cef-bundle.tar.gz -C cef-bundle .
sha256sum cef-bundle.tar.gz > cef-bundle.tar.gz.sha256
ls -la cef-bundle.tar.gz cef-bundle.tar.gz.sha256

echo "the bundle is ready"
