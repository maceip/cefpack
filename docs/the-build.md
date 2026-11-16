# The build, step by step

What the service does between the pinned commit and the bundle.  Every step
is a command of the service, and every step stops the build when it cannot
finish what it says.

## 1. `plan` — is this machine able to build?

The plan resolves four tools and checks them against the pin:

| tool | found by | checked |
|---|---|---|
| the NDK | `CEF_ANDROID_NDK`, `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`, then `/opt/android-ndk-r27c` | the version in `source.properties` must be the version the manifest pins |
| the SDK | `ANDROID_SDK_ROOT`, `ANDROID_HOME`, then `/opt/android-sdk` | it has a `platforms` directory |
| `depot_tools` | `CEF_DEPOT_TOOLS` | it carries `gclient` |
| `git` | `CEF_GIT`, then the path | — |

A tool that is missing is an error that names the variable that would fix
it.  The plan never guesses and never continues with the wrong NDK: a build
with the wrong NDK fails hours later, in the middle of the compile, with a
message that says nothing about the cause.

`gn` and `ninja` are not in that table on purpose.  A current `depot_tools`
carries only wrappers for them; the programs themselves are fetched with the
checkout, into `src/buildtools/linux64`, and the service looks in both
places.  The checkout comes first, because the wrapper refuses to run
without the program it wraps.

## The machine

The build needs roughly 150 GB of disk and hours of CPU.  The machine that
runs it is a **Limrun sandbox** of the account of this repository — measured
at 1.3 TB of disk, 96 cores and 249 GB of memory — driven by
`scripts/limrun-build.sh`.  That script

1. reads the credit of the account and refuses to start a build that cannot
   finish (the account is billed by the minute);
2. creates the sandbox and syncs this repository into it;
3. runs the build in it;
4. pulls the bundle back;
5. deletes the sandbox, whatever happened.

The toolchain is installed *in* the sandbox by
`scripts/install-toolchain.sh`: the NDK, the Android SDK, `depot_tools` and,
when the machine has no Rust of its own, a Rust of its own.  A sandbox has
no `sudo`, so the installer never needs it.

## 2. `fetch` — the sources

CEF is a layer **inside** the tree of Chromium, at `src/cef`.  That is not a
choice of this service: the hook of CEF takes the directory of its own
script as the directory of CEF and the parent of it as the directory of
Chromium, and CEF's own tooling writes the solution in exactly that shape.

The service therefore checks out both trees, at the commits that the
manifest pins, and lets `gclient` fetch the dependencies that their `DEPS`
files name:

```bash
# the tree of Chromium
git clone --filter=blob:none --no-checkout https://chromium.googlesource.com/chromium/src.git src
git fetch --depth 1 origin 2ad9b7f5a86846e0b264090723a6a78964bb84c4
git checkout --detach 2ad9b7f5a86846e0b264090723a6a78964bb84c4

# the layer of CEF, inside it
git clone --filter=blob:none --no-checkout https://github.com/chromiumembedded/cef.git src/cef
git fetch --depth 1 origin 6028375a4532fb89d23b58635f5c0d3a82c93959
git checkout --detach 6028375a4532fb89d23b58635f5c0d3a82c93959

# the dependencies, and the hook of CEF that patches the tree
gclient sync --no-history --shallow --with_branch_heads --force --reset
```

The `.gclient` file that the last command reads names two solutions — `src`
and `src/cef` — and says that neither is *managed* by `gclient`: the commits
are pinned by this service, and `gclient` is there for the dependencies.

The Chromium revision **is** written in the manifest.  CEF's own `DEPS` file
carries only its hook and names no revision of Chromium, so the pin of the
Chromium side belongs to the manifest, next to the pin of CEF.

The checkout is large — tens of gigabytes — and it takes hours.  This is the
reason the build needs its own machine and its own cache.

## 3. `headers` — the C API

The public headers of CEF are **not** all in the source tree.  Only
`include/capi/cef_base_capi.h` is checked in; the others are written by the
build, which knows the headers of the tree it builds.  The service therefore
collects the headers **after** the build, and it checks their number where
they are written:

```bash
python3 tools/version_manager.py                     # the translated files
python3 tools/make_config_header.py <out.h> <args.gn>
python3 tools/make_version_header.py <out.h>
python3 tools/make_api_versions_header.py <out.h> <out.inc> cef_api_versions.json cef_api_untracked.json
```

`version_manager.py` needs `<chromium>/chrome/VERSION` to know the version
of Chromium that the headers describe.  For the pinned commit it is
`MAJOR=156 / MINOR=0 / BUILD=8078 / PATCH=96`.

Two more headers are derived from the headers of Chromium:
`cef_color_ids.h` and `cef_command_ids.h`.  The service fetches the headers
they are derived from — `ui/color/color_id.h`, `components/color/color_id.h`,
`chrome/browser/ui/color/chrome_color_id.h` and
`chrome/app/chrome_command_ids.h` — at the pinned Chromium ref and verifies
every one of them against the checksum in the manifest.

The result is a bundle that carries 393 headers, of which 161 are the C API.

## 4. `build` — the engine

The service configures the build with GN and compiles it with Ninja:

```bash
gn gen out/Release --args='target_os="android" target_cpu="arm64" is_android=true use_cef=true ...'
ninja -C out/Release libcef libcef_dll_wrapper
```

The arguments come from the manifest and are printed before the build runs,
so a wrong argument shows up in the log of the build rather than in a
mysterious failure two hours later.

After the compile the service collects the output into the bundle:

- `lib/libcef.so` — the engine
- `lib/libcef_dll_wrapper.a` — the C API shim
- `Resources/` — the pak files, the locales and `icudtl.dat`
- the headers of the previous step
- `LICENSE.txt` and `NOTICE` of CEF
- `bundle.json` — the provenance: the versions, the commit, the checksums

## 5. `audit` — the verdict

The audit is the last word on a bundle.  It checks:

- the machine of the engine (AArch64 — 183 in the ELF header);
- the C API it exports (the symbols the application calls);
- the headers, the resources and the locales;
- the licences — they travel with the binary;
- the checksums of everything that is in the bundle.

A bundle that fails the audit is not published.  The audit is also what the
consumer runs, so that a bundle is never taken on trust.

## 6. `pack` and `bindgen` — for the consumer

`pack` stages the bundle for a Gradle build:

```text
jniLibs/<abi>/libcef.so
assets/cef/**
assets/licenses/**
lib/libcef_dll_wrapper.a
```

`bindgen` writes the Rust declarations of the C API of **this** engine into
`bindings/` of the bundle, so that the bundle carries the engine, its
headers and the declarations of that engine — one thing to fetch, one thing
to verify.

The declarations need the headers of Chromium that only a Chromium build
produces (`cef_pack_resources.h` and `cef_pack_strings.h` are generated by
grit).  When they are not at hand, the service can take the declarations of
another target of the **same API version** — the layout of the C API is
identical on every platform for a given version, and both aarch64 Linux and
aarch64 Android are LP64.  The version is checked in both directions: a
mismatch is refused, never silently accepted.
