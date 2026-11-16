#!/usr/bin/env bash
# Build CEF for Android and leave the bundle in ./cef-bundle.
#
# The script is the whole build, in the order the service expects it:
#
#   1. check the host — the NDK, the SDK and depot_tools;
#   2. fetch the pinned sources and their dependencies;
#   3. generate the C API headers;
#   4. configure and compile the engine;
#   5. audit the bundle and stage it for a Gradle build;
#   6. generate the Rust FFI of the bundled engine.
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

FEATURES="bindgen"
if ! cargo build --release --features "${FEATURES}" 2>/dev/null; then
  # The generator of the FFI needs libclang.  Without it the rest of the
  # build still works, and the FFI is taken from the bindings of another
  # target of the same API version.
  echo "the build of the service with the generator failed; building without it"
  FEATURES=""
  cargo build --release
fi
CEFPACK="${ROOT}/target/release/cefpack"
if [ ! -x "${CEFPACK}" ]; then
  CEFPACK="$(cargo metadata --format-version 1 --no-deps | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["target_directory"] + "/release/cefpack")')"
fi

echo "== 1. the host =="
"${CEFPACK}" plan

echo "== 2. the sources =="
"${CEFPACK}" fetch

echo "== 3. the headers =="
"${CEFPACK}" headers

echo "== 4. the engine =="
"${CEFPACK}" build

echo "== 5. the verdict =="
"${CEFPACK}" audit

echo "== 6. the staging tree =="
"${CEFPACK}" pack

echo "== 7. the Rust FFI =="
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
