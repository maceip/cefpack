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
# Usage: scripts/install-toolchain.sh [target directory] [--rust-only]
#        default: /opt/trap-toolchain
#
# With --rust-only the installer brings nothing but the compiler of the
# service.  The checkout of the sources needs nothing else, and a container
# that holds nothing but the compiler has the memory to carry it.

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
TOOLCHAIN="${TRAP_TOOLCHAIN:-/opt/trap-toolchain}"
RUST_ONLY=0
for argument in "$@"; do
  case "${argument}" in
    --rust-only) RUST_ONLY=1 ;;
    *) TOOLCHAIN="${argument}" ;;
  esac
done

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
  # The bootstrap is its own tool: `update_depot_tools` skips it when
  # `DEPOT_TOOLS_UPDATE` is set, and the wrapper of `gn` and of `ninja`
  # refuses to run without the python that the bootstrap builds.
  ( unset DEPOT_TOOLS_UPDATE; "${DEPOT}/ensure_bootstrap" )
fi

# --- Rust ------------------------------------------------------------------
# The service itself is written in Rust, so the machine needs a compiler for
# it.  A machine that has one keeps it; a machine that has none gets one from
# rustup, into the toolchain, so that the whole toolchain stays in one place.
install_rust() {
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
}

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

# --- pkg-config -------------------------------------------------------------
# The build of Chromium looks the packages of the *host* up — the NSS, the
# D-Bus and the Udev among them — and it does that with `pkg-config`.  A
# container that has no desktop has no `pkg-config`, and the build stops with
# a message about a file that is not there:
#
#     FileNotFoundError: [Errno 2] No such file or directory: 'pkg-config'
#
# `pkgconf` is the `pkg-config` of the distribution, written without the
# library of the desktop, and the three packages that carry it are unpacked
# into the toolchain — without a root, which is what a container has.
#
# The pins are the checksums of the Debian archive, and every file is
# checked against its pin before it is unpacked.
install_pkg_config() {
  local ROOT="${TOOLCHAIN}/host-tools"
  local BASE="https://deb.debian.org/debian/pool/main/p/pkgconf"
  if [ -x "${ROOT}/bin/pkg-config" ]; then
    return 0
  fi
  mkdir -p "${ROOT}"
  local PACKAGE
  for PACKAGE in \
    "pkgconf_1.8.1-1_amd64.deb 4e3ce982b5fedc6c6119268435504a64f5ffcc6d93aaecaea902d816eba1215f" \
    "pkgconf-bin_1.8.1-1_amd64.deb 8fb5a8f83e46ad04b4cf02651ceec56c0611a335cf0d30780d859a95d0400174" \
    "libpkgconf3_1.8.1-1_amd64.deb da01fb901123ae498c36387a32240e09e1f2866810146c5a574273f7eaf31093"; do
    set -- ${PACKAGE}
    local FILE="$1"
    local SHA="$2"
    local ARCHIVE="${ROOT}/${FILE}"
    if [ ! -f "${ARCHIVE}" ]; then
      echo "pkg-config: ${FILE}"
      curl -fsSL --retry 3 -o "${ARCHIVE}" "${BASE}/${FILE}" || return 1
    fi
    local GOT
    GOT="$(sha256sum "${ARCHIVE}" | cut -d' ' -f1)"
    if [ "${GOT}" != "${SHA}" ]; then
      echo "pkg-config: the checksum of ${FILE} is ${GOT} and the pin says ${SHA}" >&2
      return 1
    fi
    dpkg-deb -x "${ARCHIVE}" "${ROOT}" || return 1
  done
  # The program is `pkgconf`; the name that the build calls is `pkg-config`.
  # The archive unpacks into `usr/bin`, and that is where the link goes.
  ln -sf pkgconf "${ROOT}/usr/bin/pkg-config"
  [ -x "${ROOT}/usr/bin/pkg-config" ] || return 1
}

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

write_environment() {
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
# The pkg-config of the toolchain, and the library it needs.  The build of
# Chromium looks the packages of the host up with it.
export CEF_HOST_TOOLS=${TOOLCHAIN}/host-tools
export LD_LIBRARY_PATH=\${CEF_HOST_TOOLS}/usr/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH:-}
export PATH=\${CARGO_HOME}/bin:\${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:\${CEF_DEPOT_TOOLS}:\${CEF_HOST_TOOLS}/usr/bin:\${PATH}
EOF
}

# The Rust is installed before anything else, because the service is
# written in Rust; the rest of the toolchain is installed after the checkout
# of the sources, because the container has to be empty for it.
install_rust

# The environment is written in both cases: the compiler of the service is
# the first thing that is installed, and the file that points at it is what
# the rest of the build reads.
write_environment

if [ "${RUST_ONLY}" = "1" ]; then
  echo
  echo "done.  Run: source ${TOOLCHAIN}/env.sh"
  exit 0
fi

# The `pkg-config` of the host.  It is installed with the rest of the
# toolchain, and not with the Rust: the checkout of the sources does not
# need it, and the container has to be empty for the checkout.
install_pkg_config || {
  echo "no pkg-config: the build of Chromium cannot look the packages of the host up" >&2
  exit 1
}

# The environment is written again, because the `pkg-config` and the library
# it needs are only on the path now.
write_environment

echo
echo "done.  Run: source ${TOOLCHAIN}/env.sh"
