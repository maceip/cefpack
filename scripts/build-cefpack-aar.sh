#!/usr/bin/env bash
# Build the standalone multi-ABI Android content engine AAR (cefpack-android.aar)
# and bundle (cef-bundle.tar.gz) from pinned Chromium 156 sources inside a
# 16 GiB Limrun build sandbox.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

TOOLCHAIN="${CEF_TOOLCHAIN_DIR:-${HOME}/trap-toolchain}"
export CEF_SOURCE_ROOT="${CEF_SOURCE_ROOT:-${ROOT}/cef-source}"
export CEF_BUNDLE_DIR="${CEF_BUNDLE_DIR:-${ROOT}/cef-bundle}"
export CARGO_INCREMENTAL=0
export DEPOT_TOOLS_UPDATE=0

SRC="${CEF_SOURCE_ROOT}/src"
OUT_ARM64="${SRC}/out/arm64"
OUT_X64="${SRC}/out/x64"

echo "== [1/8] Bootstrapping minimal host tools (Rust + depot_tools + pkgconf) =="
mkdir -p "${TOOLCHAIN}"

# 1a. Rust (skip downloading NDK/SDK zips because Chromium's DEPS ships pinned NDK r30 + SDK 37).
RUST_DIR="${TOOLCHAIN}/rust"
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "${RUST_DIR}/bin/cargo" ]; then
  curl -fsSL -o "${TOOLCHAIN}/rustup-init" \
    https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
  chmod +x "${TOOLCHAIN}/rustup-init"
  RUSTUP_HOME="${RUST_DIR}" CARGO_HOME="${RUST_DIR}" "${TOOLCHAIN}/rustup-init" \
    -y --profile minimal --default-toolchain stable --no-modify-path
  rm -f "${TOOLCHAIN}/rustup-init"
fi
if [ -x "${RUST_DIR}/bin/cargo" ]; then
  export CARGO_HOME="${RUST_DIR}"
  export RUSTUP_HOME="${RUST_DIR}"
  export PATH="${RUST_DIR}/bin:${PATH}"
fi

# 1b. depot_tools
DEPOT="${TOOLCHAIN}/depot_tools"
if [ ! -x "${DEPOT}/gclient" ]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT}"
fi
if [ ! -f "${DEPOT}/python3_bin_reldir.txt" ]; then
  ( unset DEPOT_TOOLS_UPDATE; "${DEPOT}/ensure_bootstrap" )
fi
export CEF_DEPOT_TOOLS="${DEPOT}"

# 1c. Pinned Debian pkgconf (required by Chromium host toolchain GN pkg-config lookups)
HOST_TOOLS="${TOOLCHAIN}/host-tools"
if [ ! -x "${HOST_TOOLS}/usr/bin/pkg-config" ]; then
  mkdir -p "${HOST_TOOLS}"
  DEB_BASE="https://deb.debian.org/debian/pool/main/p/pkgconf"
  for PKG_SPEC in \
    "pkgconf_1.8.1-1_amd64.deb 4e3ce982b5fedc6c6119268435504a64f5ffcc6d93aaecaea902d816eba1215f" \
    "pkgconf-bin_1.8.1-1_amd64.deb 8fb5a8f83e46ad04b4cf02651ceec56c0611a335cf0d30780d859a95d0400174" \
    "libpkgconf3_1.8.1-1_amd64.deb da01fb901123ae498c36387a32240e09e1f2866810146c5a574273f7eaf31093"; do
    set -- ${PKG_SPEC}
    DEB_FILE="$1"
    DEB_SHA="$2"
    DEB_PATH="${HOST_TOOLS}/${DEB_FILE}"
    if [ ! -f "${DEB_PATH}" ]; then
      curl -fsSL --retry 3 -o "${DEB_PATH}" "${DEB_BASE}/${DEB_FILE}"
    fi
    GOT_SHA="$(sha256sum "${DEB_PATH}" | cut -d' ' -f1)"
    if [ "${GOT_SHA}" != "${DEB_SHA}" ]; then
      echo "Checksum mismatch for ${DEB_FILE}: expected ${DEB_SHA}, got ${GOT_SHA}" >&2
      exit 1
    fi
    dpkg-deb -x "${DEB_PATH}" "${HOST_TOOLS}"
  done
  ln -sf pkgconf "${HOST_TOOLS}/usr/bin/pkg-config"
fi
export LD_LIBRARY_PATH="${HOST_TOOLS}/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export PATH="${DEPOT}:${HOST_TOOLS}/usr/bin:${PATH}"

if [ -d "${SRC}/.git" ] && [ -d "${SRC}/third_party/jdk/current" ] && [ -d "${SRC}/build/linux/debian_bullseye_amd64-sysroot" ]; then
  echo "== [2/8] Warm Chromium 156 checkout + sysroot detected; resetting modified files =="
  git -C "${SRC}" checkout -- .
else
  cargo build --release -j 4
  CEFPACK="${ROOT}/target/release/cefpack"
  if [ -d "${SRC}/.git" ]; then
    git -C "${SRC}" checkout -- . || true
  fi
  echo "== [2/8] Fetching & syncing pinned Chromium 156 sources + sysroot =="
  "${CEFPACK}" fetch
fi

# Prefer Chromium's hermetic JDK 25 once synced.
if [ -x "${SRC}/third_party/jdk/current/bin/javac" ]; then
  export JAVA_HOME="${SRC}/third_party/jdk/current"
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

echo "== [3/8] Starting continuous cgroup page-cache keeper & telemetry =="
python3 - "${CEF_SOURCE_ROOT}" <<'PY' &
import ctypes
import os
import sys
import time

root = sys.argv[1]
out_root = os.path.join(root, "src", "out")
libc = ctypes.CDLL("libc.so.6")
POSIX_FADV_DONTNEED = 4
SYNC_FILE_RANGE_WRITE = 2

def evict_dir(target: str, writeback: bool) -> None:
    if not os.path.isdir(target):
        return
    for dirpath, dirnames, filenames in os.walk(target):
        # Skip .git pack directories after initial eviction to avoid extra metadata churn
        if ".git" in dirnames:
            dirnames.remove(".git")
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            try:
                fd = os.open(p, os.O_RDONLY)
            except OSError:
                continue
            try:
                st = os.fstat(fd)
                if st.st_size > 0:
                    if writeback:
                        libc.sync_file_range(
                            ctypes.c_int(fd),
                            ctypes.c_int64(0),
                            ctypes.c_int64(st.st_size),
                            ctypes.c_uint(SYNC_FILE_RANGE_WRITE),
                        )
                    libc.posix_fadvise(
                        ctypes.c_int(fd),
                        ctypes.c_int64(0),
                        ctypes.c_int64(st.st_size),
                        ctypes.c_int(POSIX_FADV_DONTNEED),
                    )
            except OSError:
                pass
            finally:
                os.close(fd)

tick = 0
evict_dir(root, True)
while True:
    time.sleep(15)
    tick += 1
    evict_dir(out_root, True)
    if tick % 4 == 0:
        evict_dir(os.path.join(root, "src"), False)
PY
KEEPER_PID=$!
trap 'kill "${KEEPER_PID}" 2>/dev/null || true' EXIT

echo "== [4/8] Preparing clean Chromium tree + cefpack_webview embedder =="
git -C "${SRC}" checkout -- .
git -C "${SRC}" apply "${ROOT}/crates/cefpack/patches/chromium-android-lld-workers.patch"

rm -rf "${SRC}/cefpack_webview"
cp -R "${ROOT}/embedder/cefpack_webview" "${SRC}/cefpack_webview"

python3 - "${SRC}/BUILD.gn" <<'PY'
import sys
from pathlib import Path

build_gn = Path(sys.argv[1])
orig = build_gn.read_text(encoding="utf-8")
wrapped = """declare_args() {
  cefpack_standalone_aar = false
}

if (cefpack_standalone_aar) {
  import("//build/gn_logs.gni")

  group("gn_all") {
    deps = [ "//cefpack_webview:cefpack_webview_all" ]
  }

  assert(current_toolchain == default_toolchain)
  _cefpack_lines = [
                     "Generated during 'gn gen' by //BUILD.gn (cefpack_standalone_aar).",
                     "",
                   ] + build_gn_logs
  write_file("$root_build_dir/gn_logs.txt", _cefpack_lines)
} else {
""" + orig + "\n}\n"
build_gn.write_text(wrapped, encoding="utf-8")
PY

echo "== [5/8] Running Chromium lastchange & GPU/Skia/Dawn version hooks =="
(
  cd "${CEF_SOURCE_ROOT}"
  python3 src/build/util/lastchange.py -o src/build/util/LASTCHANGE
  python3 src/build/util/lastchange.py -m GPU_LISTS_VERSION --revision-id-only \
    --header src/gpu/config/gpu_lists_version.h
  python3 src/build/util/lastchange.py -m SKIA_COMMIT_HASH -s src/third_party/skia \
    --header src/skia/ext/skia_commit_hash.h
  python3 src/build/util/lastchange.py -m DAWN_COMMIT_HASH -s src/third_party/dawn \
    --revision src/gpu/webgpu/DAWN_VERSION \
    --header src/gpu/webgpu/dawn_commit_hash.h
)

GN_BIN="${SRC}/buildtools/linux64/gn"
[ -x "${GN_BIN}" ] || GN_BIN="$(command -v gn)"
NINJA_BIN="${SRC}/third_party/ninja/ninja"
[ -x "${NINJA_BIN}" ] || NINJA_BIN="$(command -v ninja)"

export CHROMIUM_LLD_WORKERS="${CHROMIUM_LLD_WORKERS:-2}"
COMPILE_JOBS="${CEF_AAR_JOBS:-6}"

write_args_gn() {
  local out_dir="$1"
  local cpu="$2"
  mkdir -p "${out_dir}"
  cat > "${out_dir}/args.gn" <<EOF
target_os = "android"
target_cpu = "${cpu}"
cefpack_standalone_aar = true

is_debug = false
is_official_build = false
is_component_build = false
dcheck_always_on = false
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
use_thin_lto = false

is_clang = true
use_lld = true
use_sysroot = true
use_remoteexec = false
clang_use_chrome_plugins = false
treat_warnings_as_errors = false

v8_use_external_startup_data = false
icu_use_data_file = true
enable_jni_multiplexing = false
use_hashed_jni_names = false
proprietary_codecs = false
ffmpeg_branding = "Chromium"
EOF
}

run_ninja_resilient() {
  local out_dir="$1"
  shift
  if ! "${NINJA_BIN}" -C "${out_dir}" -j "${COMPILE_JOBS}" "$@"; then
    echo "ninja -j${COMPILE_JOBS} interrupted/spiked; retrying cleanly at -j2..."
    "${NINJA_BIN}" -C "${out_dir}" -j 2 "$@"
  fi
}

echo "== [6/8] Configuring & compiling arm64-v8a cefpack_webview_all (jobs=${COMPILE_JOBS}, lld_workers=${CHROMIUM_LLD_WORKERS}) =="
write_args_gn "${OUT_ARM64}" "arm64"
(
  cd "${SRC}"
  "${GN_BIN}" gen "out/arm64" --root-target=//cefpack_webview:cefpack_webview_all
)
run_ninja_resilient "${OUT_ARM64}" cefpack_webview:cefpack_webview_all

echo "== [7/8] Configuring & compiling x86_64 libcefpack_content.so =="
write_args_gn "${OUT_X64}" "x64"
(
  cd "${SRC}"
  "${GN_BIN}" gen "out/x64" --root-target=//cefpack_webview:libcefpack_content
)
run_ninja_resilient "${OUT_X64}" cefpack_webview:libcefpack_content

echo "== [8/8] Packaging & auditing multi-ABI cefpack-android.aar + cef-bundle.tar.gz =="
JAVAC_BIN="${SRC}/third_party/jdk/current/bin/javac"
[ -x "${JAVAC_BIN}" ] || JAVAC_BIN="$(command -v javac)"

python3 "${ROOT}/embedder/assemble_aar.py" \
  --base-aar "${OUT_ARM64}/cefpack_base.aar" \
  --arm64-so "${OUT_ARM64}/libcefpack_content.so" \
  --x64-so "${OUT_X64}/libcefpack_content.so" \
  --pak "${OUT_ARM64}/cefpack_resources.pak" \
  --icudtl "${OUT_ARM64}/icudtl.dat" \
  --native-libs-srcjar "${OUT_ARM64}/gen/cefpack_webview/cefpack_native_libraries_srcjar.srcjar" \
  --javac "${JAVAC_BIN}" \
  --output "${ROOT}/cefpack-android.aar" \
  --bundle-dir "${CEF_BUNDLE_DIR}"

sha256sum "${ROOT}/cefpack-android.aar" > "${ROOT}/cefpack-android.aar.sha256"
tar -czf "${ROOT}/cef-bundle.tar.gz" -C "${CEF_BUNDLE_DIR}" .
sha256sum "${ROOT}/cef-bundle.tar.gz" > "${ROOT}/cef-bundle.tar.gz.sha256"

ls -lh "${ROOT}/cefpack-android.aar" "${ROOT}/cef-bundle.tar.gz"
cat "${ROOT}/cefpack-android.aar.sha256" "${ROOT}/cef-bundle.tar.gz.sha256"
echo "the cefpack-android.aar and cef-bundle.tar.gz artifacts are ready"
