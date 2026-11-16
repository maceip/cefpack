#!/usr/bin/env bash
# Install the toolchain that builds CEF for Android.
#
# The toolchain is three things:
#
#   * the Android NDK — the only C++ toolchain that can target Android;
#   * the Android SDK — the platform that the build reads its resources from;
#   * depot_tools — `gclient` and `gn`, which fetch the Chromium sources and
#     drive the build.
#
# Everything lands in one directory and one `env.sh` points at it.  The
# versions are read from the pinned manifest, so the toolchain and the build
# can never drift apart.
#
# Usage: scripts/install-toolchain.sh [target directory]
#        default: /opt/trap-toolchain

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${HERE}/../crates/cefpack/manifest/cef-android.toml"
TOOLCHAIN="${1:-${TRAP_TOOLCHAIN:-/opt/trap-toolchain}}"

read_manifest() {
  # The manifest is TOML; the values this script needs are plain strings.
  sed -n "s/^$1 = \"\(.*\)\"$/\1/p" "${MANIFEST}" | head -1
}

NDK_VERSION="$(read_manifest ndk_version)"
NDK_TAG="$(read_manifest ndk_tag)"
ANDROID_API="$(sed -n 's/^min_sdk = \([0-9]*\)$/\1/p' "${MANIFEST}" | head -1)"

if [ -z "${NDK_VERSION}" ]; then
  echo "the manifest names no NDK version" >&2
  exit 1
fi
if [ -z "${NDK_TAG}" ]; then
  echo "the manifest names no NDK tag" >&2
  exit 1
fi

echo "the toolchain goes to ${TOOLCHAIN}"
mkdir -p "${TOOLCHAIN}"

# --- the NDK ---------------------------------------------------------------
# The archive is named after the tag of the release — `android-ndk-r27c-linux.zip`
# — and not after the version, which is why the tag is in the manifest.
if [ ! -d "${TOOLCHAIN}/ndk-${NDK_VERSION}" ]; then
  echo "the NDK ${NDK_VERSION} (${NDK_TAG})"
  curl -fsSL -o "${TOOLCHAIN}/ndk.zip" \
    "https://dl.google.com/android/repository/android-ndk-${NDK_TAG}-linux.zip"
  unzip -q "${TOOLCHAIN}/ndk.zip" -d "${TOOLCHAIN}"
  rm "${TOOLCHAIN}/ndk.zip"
  # The archive carries the directory of the tag; the version is the name
  # that the rest of the service uses.
  mv "${TOOLCHAIN}/android-ndk-${NDK_TAG}" "${TOOLCHAIN}/ndk-${NDK_VERSION}"
fi
NDK="${TOOLCHAIN}/ndk-${NDK_VERSION}"

# --- the SDK ---------------------------------------------------------------
SDK="${TOOLCHAIN}/android-sdk"
if [ ! -x "${SDK}/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "the command line tools of the SDK"
  mkdir -p "${SDK}/cmdline-tools"
  curl -fsSL -o "${SDK}/cmdline-tools.zip" \
    "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
  unzip -q "${SDK}/cmdline-tools.zip" -d "${SDK}/cmdline-tools"
  rm "${SDK}/cmdline-tools.zip"
  mv "${SDK}/cmdline-tools/cmdline-tools" "${SDK}/cmdline-tools/latest"
fi

if [ ! -d "${SDK}/platforms/android-${ANDROID_API}" ]; then
  echo "the platform android-${ANDROID_API}"
  yes | "${SDK}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="${SDK}" --licenses >/dev/null || true
  "${SDK}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="${SDK}" \
    "platform-tools" "platforms;android-${ANDROID_API}" "platforms;android-35" >/dev/null
fi

# --- depot_tools -----------------------------------------------------------
DEPOT="${TOOLCHAIN}/depot_tools"
if [ ! -x "${DEPOT}/gclient" ]; then
  echo "depot_tools"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT}"
fi

# --- the environment -------------------------------------------------------
cat > "${TOOLCHAIN}/env.sh" <<EOF
export JAVA_HOME=\${JAVA_HOME:-${TOOLCHAIN}/jdk25}
export ANDROID_HOME=${SDK}
export ANDROID_SDK_ROOT=${SDK}
export ANDROID_NDK_HOME=${NDK}
export ANDROID_NDK_ROOT=${NDK}
export CEF_ANDROID_NDK=${NDK}
export CEF_DEPOT_TOOLS=${DEPOT}
export PATH=\${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:\${CEF_DEPOT_TOOLS}:\${PATH}
EOF

echo
echo "done.  Run: source ${TOOLCHAIN}/env.sh"
