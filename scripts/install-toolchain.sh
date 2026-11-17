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
# The manifest names the versions that the toolchain must have.  It is found
# through the environment, in the repository, or next to the script.
MANIFEST="${CEF_MANIFEST:-}"
if [ -z "${MANIFEST}" ]; then
  for candidate in \
    "${HERE}/../crates/cefpack/manifest/cef-android.toml" \
    "${HERE}/manifest/cef-android.toml" \
    "${HERE}/../../crates/cefpack/manifest/cef-android.toml"; do
    if [ -f "${candidate}" ]; then
      MANIFEST="${candidate}"
      break
    fi
  done
fi
if [ -z "${MANIFEST}" ] || [ ! -f "${MANIFEST}" ]; then
  echo "cannot find the manifest of the build: set CEF_MANIFEST" >&2
  exit 1
fi
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
# depot_tools ships its gn and ninja as wrappers that need the python of the
# bootstrap; without it they refuse to run.
if [ ! -f "${DEPOT}/python3_bin_reldir.txt" ]; then
  echo "the bootstrap of depot_tools"
  DEPOT_TOOLS_UPDATE=0 "${DEPOT}/update_depot_tools" --no-check
fi

# --- Rust ------------------------------------------------------------------
# The service itself is written in Rust, so the machine needs a compiler for
# it.  A machine that has one keeps it; a machine that has none gets one from
# rustup, into the toolchain, so that the whole toolchain stays in one place.
RUST="${TOOLCHAIN}/rust"
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "${RUST}/bin/cargo" ]; then
  echo "Rust"
  curl -fsSL -o "${TOOLCHAIN}/rustup-init" https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
  chmod +x "${TOOLCHAIN}/rustup-init"
  RUSTUP_HOME="${RUST}" CARGO_HOME="${RUST}" "${TOOLCHAIN}/rustup-init" \
    -y --profile minimal --default-toolchain stable --no-modify-path
  rm "${TOOLCHAIN}/rustup-init"
fi
if [ -x "${RUST}/bin/cargo" ]; then
  CARGO_HOME="${RUST}"
  RUSTUP_HOME="${RUST}"
  PATH="${RUST}/bin:${PATH}"
elif command -v cargo >/dev/null 2>&1; then
  CARGO_HOME="${CARGO_HOME:-${HOME}/.cargo}"
else
  echo "no Rust on this machine: the service is written in Rust" >&2
  exit 1
fi

# --- libclang --------------------------------------------------------------
# The generator of the Rust FFI needs libclang.  A machine that has one
# keeps it; a machine that has none gets the wheel of the Python package,
# which carries the library itself.  When even that fails, the build goes on
# without the FFI.
if ! ldconfig -p 2>/dev/null | grep -q libclang; then
  if command -v pip3 >/dev/null 2>&1; then
    echo "libclang"
    pip3 install --quiet --disable-pip-version-check --target "${TOOLCHAIN}/libclang" libclang || true
  fi
  if [ -d "${TOOLCHAIN}/libclang" ]; then
    LIBCLANG_PATH="$(dirname "$(find "${TOOLCHAIN}/libclang" -name 'libclang.so*' -type f | head -1)")"
  else
    LIBCLANG_PATH=""
  fi
else
  LIBCLANG_PATH=""
fi

# --- the environment -------------------------------------------------------
# The JDK: one that the machine already has, unless the toolchain carries its
# own.  The build of Chromium needs a JDK, and the SDK manager needs one too.
if [ -x "${TOOLCHAIN}/jdk25/bin/java" ]; then
  JAVA_HOME="${TOOLCHAIN}/jdk25"
elif command -v java >/dev/null 2>&1; then
  JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
else
  echo "no JDK on this machine: the build of Chromium needs one" >&2
  exit 1
fi

cat > "${TOOLCHAIN}/env.sh" <<EOF
export JAVA_HOME=\${JAVA_HOME:-${JAVA_HOME}}
export ANDROID_HOME=${SDK}
export ANDROID_SDK_ROOT=${SDK}
export ANDROID_NDK_HOME=${NDK}
export ANDROID_NDK_ROOT=${NDK}
export CEF_ANDROID_NDK=${NDK}
export CEF_DEPOT_TOOLS=${DEPOT}
export CARGO_HOME=${CARGO_HOME}
export RUSTUP_HOME=\${RUSTUP_HOME:-${RUSTUP_HOME}}
export LIBCLANG_PATH=\${LIBCLANG_PATH:-${LIBCLANG_PATH}}
export PATH=\${CARGO_HOME}/bin:\${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:\${CEF_DEPOT_TOOLS}:\${PATH}
EOF

echo
echo "done.  Run: source ${TOOLCHAIN}/env.sh"
