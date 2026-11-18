#!/usr/bin/env bash
# The measurement of the link of the engine.
#
# The engine of the browser is a shared library that carries the layer of
# the content of Chromium and Blink.  The link of that library is the step
# that costs the most memory of the whole build, and the step that has to
# be measured *before* anything is written on top of it: a linker that
# needs fourteen gigabytes in a container that allows sixteen, with the
# page cache of the tree of the sources in the same sixteen, is a wall that
# is found at the worst possible moment.
#
# The script is started detached by the driver of the build: the platform
# ends a command that runs for a long time without saying anything, and the
# compilation of Blink is nothing but that.
#
# The last lines of the log say what the link cost.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

TOOLCHAIN="${CEF_TOOLCHAIN_DIR:-${HOME}/trap-toolchain}"
OUT="${ROOT}/link-measure"
SRC="${ROOT}/cef-source/src"

# The paths of the service, absolute.  The service makes them absolute
# itself, and this is the second half of the same promise: the scripts and
# the service name the same directories.
export CEF_SOURCE_ROOT="${ROOT}/cef-source"
export CEF_OUT_DIR="${ROOT}/cef-out"
export CEF_BUNDLE_DIR="${ROOT}/cef-bundle"
export CEF_STAGING_DIR="${ROOT}/cef-staging"

# --- 1. the service --------------------------------------------------------
echo "== 1. the service =="
# Only the compiler of the service is installed before the checkout of the
# sources: the NDK, the SDK and depot_tools are three gigabytes of files
# that the container does not need for the checkout.
"${HERE}/install-toolchain.sh" "${TOOLCHAIN}" --rust-only
# shellcheck disable=SC1091
. "${TOOLCHAIN}/env.sh"
cargo build --release
CEFPACK="${ROOT}/target/release/cefpack"

# --- 2. the sources --------------------------------------------------------
echo "== 2. the sources =="
"${CEFPACK}" fetch

# --- 3. the toolchain ------------------------------------------------------
echo "== 3. the toolchain =="
"${HERE}/install-toolchain.sh" "${TOOLCHAIN}"
# shellcheck disable=SC1091
. "${TOOLCHAIN}/env.sh"

# --- 4. the target of the measurement ---------------------------------------
echo "== 4. the target of the measurement =="
cd "${SRC}"

# The patches that the service carries for the tree of Chromium: the ones
# that relax the assertions of Chromium that hold a desktop build.  The
# measurement and the service have to build the same tree, and the patches
# are part of it.
"${ROOT}/target/release/cefpack" patch --content-only true

if ! git apply --check "${ROOT}/scripts/content-link-measure.patch" 2>/dev/null; then
  git apply "${ROOT}/scripts/content-link-measure.patch"
fi
echo "the target is in the tree"

# The workers that read the input of the link.  Chromium computes them from
# the number of the cores — twenty-four on a machine of ninety-six cores —
# and every one of them holds the part of the input that it reads in
# memory.  The patch of the service bounds them by the memory of the
# machine, and the machine says how many it allows.
export CHROMIUM_LLD_WORKERS="$("${ROOT}/target/release/cefpack" linker-workers)"
echo "the workers of the linker: ${CHROMIUM_LLD_WORKERS}"

# --- 5. the configuration --------------------------------------------------
echo "== 5. the configuration =="
mkdir -p "${OUT}"

# The tree of Chromium is checked out with `gclient sync --nohooks` — the
# hook of CEF configures the build wrongly — and the files that the hooks
# write are therefore not written either.  One of them is read while the
# build is *configured*:
#
#   FileNotFoundError: .../build/util/LASTCHANGE.committime
#
# The service runs that one hook, by hand; this is the same call, so that
# the measurement and the service agree on what the tree looks like.
"${ROOT}/target/release/cefpack" lastchange

# The arguments of the build come from the service, so that the
# measurement and the engine agree on the configuration of Chromium that
# they share.  The flags of the desktop browser are turned off: the
# measurement is of the layer of the content.
#
# The flags that the bring-up adds are the ones that keep the link small:
# no symbols, no debug information, no thin LTO, and no component build.
CEF_CONTENT=1 "${ROOT}/target/release/cefpack" args \
  | sed 's/=/ = /' \
  > "${OUT}/args.gn"
cat >> "${OUT}/args.gn" <<EOF
use_thin_lto = false
android_sdk_root = "${TOOLCHAIN}/android-sdk"
android_ndk_root = "${TOOLCHAIN}/ndk-27.2.12479018"
android_ndk_version = "27.2.12479018"
EOF
gn gen "${OUT}" --root-target=//content/shell:content_link_measurement
echo "the build is configured"
# --- 6. the sampler --------------------------------------------------------
# The sampler reads the memory of the container and the largest process in
# it, once a second, for the whole of the build.  The link is the step
# that the measurement is about, and the link happens at the end of it.
echo "== 6. the build =="
SAMPLE="${ROOT}/link-measure.samples"
: > "${SAMPLE}"
(
  while true; do
    current="$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)"
    peak="$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0)"
    biggest="$(awk '/^VmHWM:/ {if ($2 > m) m = $2} END {print m+0}' /proc/[0-9]*/status 2>/dev/null || echo 0)"
    lld="$(awk '/^VmHWM:/ && /ld.lld/ {if ($2 > m) m = $2} END {print m+0}' /proc/[0-9]*/status 2>/dev/null || echo 0)"
    echo "$(date +%s) ${current} ${peak} ${biggest} ${lld}" >> "${SAMPLE}"
    sleep 1
  done
) &
SAMPLER=$!
trap 'kill ${SAMPLER} 2>/dev/null || true' EXIT

# The build.  `ninja` is the one that decides the order of the link, and
# the link is the last step of it.
ninja -C "${OUT}" content/shell:content_link_measurement
STATUS=$?

# --- 7. the verdict --------------------------------------------------------
echo "== 7. the measurement =="
kill ${SAMPLER} 2>/dev/null || true
trap - EXIT

PEAK="$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0)"
MAX="$(awk '{if ($5 > m) m = $5} END {print m+0}' "${SAMPLE}")"
MAXALL="$(awk '{if ($4 > m) m = $4} END {print m+0}' "${SAMPLE}")"
echo "the peak of the container : ${PEAK} bytes"
echo "the peak of the container : $((PEAK / 1024 / 1024)) MiB"
echo "the largest process       : ${MAXALL} kB"
echo "the largest linker        : ${MAX} kB"
ls -la "${OUT}"/content_link_measurement.so 2>/dev/null || \
  find "${OUT}" -name "*.so" -newer "${OUT}/args.gn" -exec ls -la {} \; 2>/dev/null | head -5
echo "CEF-LINK-MEASURE-EXIT:${STATUS}"
