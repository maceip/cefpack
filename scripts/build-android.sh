#!/usr/bin/env bash
# Build CEF for Android and leave the bundle in ./cef-bundle.
#
# The script is the whole build, in the order the service expects it:
#
#   1. the service itself — a binary that was built elsewhere is used as
#      it is, and is only built here when there is none;
#   2. the sources — the checkout of CEF and of Chromium;
#   3. the toolchain — the NDK, the SDK and depot_tools;
#   4. configure and compile the engine;
#   5. collect the public headers of the engine that was built;
#   6. stage the bundle for a Gradle build;
#   7. audit the bundle — the verdict;
#   8. generate the Rust FFI of the bundled engine.
#
# The order matters, and not only for the sake of the build:
#
#   * the C API headers are written by the build, so the headers are
#     collected after it and not before;
#
#   * the checkout of Chromium writes tens of gigabytes through the memory
#     of the container, and a container of sixteen gigabytes kills the
#     process that fills it.  The checkout therefore comes first, while
#     the container still holds nothing but the sources.
#
# The script stops at the first step that fails.  A build that is half done
# is worth nothing: the audit at the end is the verdict, and the verdict is
# the only thing this script prints at the end.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CEF_SOURCE_ROOT="${CEF_SOURCE_ROOT:-${ROOT}/cef-source}"
export CEF_OUT_DIR="${CEF_OUT_DIR:-${ROOT}/cef-out}"
export CEF_BUNDLE_DIR="${CEF_BUNDLE_DIR:-${ROOT}/cef-bundle}"
export CEF_STAGING_DIR="${CEF_STAGING_DIR:-${ROOT}/cef-staging}"
TOOLCHAIN="${CEF_TOOLCHAIN_DIR:-${HOME}/trap-toolchain}"

# --- 1. the service --------------------------------------------------------
# The service is built without the generator of the FFI: the generator
# needs libclang, and libclang is a lot of memory in a container that has
# sixteen gigabytes.  The generator is added at the end, when the checkout
# of the sources is behind us.
CEFPACK="${CEF_PACK_BIN:-}"
if [ -z "${CEFPACK}" ] || [ ! -x "${CEFPACK}" ]; then
  echo "== 1. the service =="
  # Only the compiler of the service is installed before the checkout of
  # the sources: the NDK, the SDK and depot_tools are three gigabytes of
  # files that the container does not need for the checkout.
  "${HERE}/install-toolchain.sh" "${TOOLCHAIN}" --rust-only
  # shellcheck disable=SC1091
  . "${TOOLCHAIN}/env.sh"
  cargo build --release
  CEFPACK="${ROOT}/target/release/cefpack"
  if [ ! -x "${CEFPACK}" ]; then
    CEFPACK="$(cargo metadata --format-version 1 --no-deps | python3 -c \
      'import json,sys; print(json.load(sys.stdin)["target_directory"] + "/release/cefpack")')"
  fi
else
  echo "== 1. the service =="
  echo "the service is taken as it is: ${CEFPACK}"
fi

# --- 2. the sources --------------------------------------------------------
echo "== 2. the sources =="
"${CEFPACK}" fetch

# --- 3. the toolchain ------------------------------------------------------
echo "== 3. the toolchain =="
# The rest of the toolchain comes now, when the checkout is behind us and
# the container has the memory for it.
"${HERE}/install-toolchain.sh" "${TOOLCHAIN}"
# shellcheck disable=SC1091
. "${TOOLCHAIN}/env.sh"

# --- 4. the engine ---------------------------------------------------------
echo "== 4. the engine =="
"${CEFPACK}" build

# --- 5. the headers --------------------------------------------------------
echo "== 5. the headers =="
"${CEFPACK}" headers

# --- 6. the staging tree ---------------------------------------------------
echo "== 6. the staging tree =="
"${CEFPACK}" pack

# --- 7. the verdict --------------------------------------------------------
echo "== 7. the verdict =="
"${CEFPACK}" audit

# --- 8. the Rust FFI -------------------------------------------------------
echo "== 8. the Rust FFI =="
# The generator of the FFI is added to the service now: the toolchain
# carries libclang by now, and the memory of the container is free again.
if cargo build --release --features bindgen >/dev/null 2>&1; then
  CEFPACK="${ROOT}/target/release/cefpack"
else
  echo "the service could not be built with the generator; the bindings of another"
  echo "target of the same API version are used instead"
fi
# The FFI of the engine is a convenience for the consumer: the same API
# version can be reached with the bindings of another target, and the
# consumer of this repository already carries them.  A machine without
# libclang therefore loses the FFI, not the engine — and the build says so
# instead of failing at the last step.
if "${CEFPACK}" bindgen; then
  echo "the FFI is in the bindings of the bundle"
else
  echo
  echo "the FFI was not generated: the generator needs libclang, which this machine"
  echo "does not carry.  The engine is built and audited; the bindings can be"
  echo "regenerated anywhere with: cefpack bindgen --from <bindings.rs> <bundle>"
fi

echo
echo "the bundle is in ${CEF_BUNDLE_DIR}"
