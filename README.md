# cefpack — CEF for Android, built from source

This repository builds the **Chromium Embedded Framework for Android** out of
the sources of CEF and the Android NDK, and hands the result over as a
bundle: the engine, the public headers, the resources, the licences, the
Rust FFI of that engine and a manifest of what it all is.

**Nothing is downloaded that is an engine.** The only inputs are a git commit
of CEF and the headers of Chromium that the public headers of CEF include,
and every one of those headers is checked against a checksum that this
repository pins. There is no package to install, no archive of a browser to
fetch, and no binary that anybody else built and that this project has to
trust.

```text
cefpack plan      resolve the pinned build and check the host
cefpack fetch     check out the pinned CEF sources and their dependencies
cefpack headers   generate the C API headers and assemble them into a bundle
cefpack build     configure and compile CEF for Android
cefpack audit     the verdict on a bundle
cefpack pack      stage the bundle for a Gradle build
cefpack bindgen   generate the Rust FFI of the bundled engine
cefpack apk       the verdict on a built APK
```

## The state of this work, honestly

| | |
|---|---|
| the service | **done** — 54 tests, clippy clean, coverage tracked in CI |
| the pin | **done** — CEF `6028375a4532fb89d23b58635f5c0d3a82c93959` (CEF 156.0.30, Chromium 156.0.8078.96), API version `15600` |
| the headers | **done and run** — 393 headers, of which 161 are the generated C API headers |
| the Rust FFI | **done and run** — generated for the bundled version, and the version is checked against the engine |
| the engine | **not built yet** — no machine with the disk and the hours has run `cefpack build` yet |
| the Android embedding | **not written yet** — see [`docs/the-embedding.md`](docs/the-embedding.md) |

The build step is written, wired into CI and waiting for a machine. It has
not produced an engine, and this document does not pretend otherwise.

## Why a service at all

`cef-rs` bundles CEF for Windows, macOS and Linux: it fetches a binary
distribution, links against it and generates the declarations of the C API
for it. There is no such distribution for Android. Upstream CEF has no
`android/` directory, and the index of the published distributions has no
`android` key:

```text
linux32  linux64  linuxarm  linuxarm64  macosarm64  macosx64  windows32  windows64  windowsarm64
```

So the Android side has to be built rather than fetched. This repository is
that build, shaped like the parts of `cef-rs` that do the same thing for the
desktop: a bundle that carries the engine and its headers, and a generator
that turns those headers into the declarations of the C API.

**The declarations are the part that has to be right.** A C API is not a
stable interface: a field of a struct moves, a function changes its
signature, and the result is not a compile error but a program that writes
into the wrong place. The bindings here are generated from the headers of
the engine that is actually shipped, and the build refuses to link against
an engine whose API version differs from the one the declarations were made
for.

## The bundle

```text
cef-bundle/
├── include/            the public headers of CEF, the C API headers
│   ├── capi/           161 generated C API headers
│   └── cef_*.h         the public headers
├── lib/
│   ├── libcef.so              the engine
│   └── libcef_dll_wrapper.a   the C API shim
├── Resources/          the resources the engine reads at run time
├── bindings/           the Rust FFI of this engine
├── LICENSE.txt         the licence of CEF (LGPL-3.0-or-later)
├── NOTICE
└── bundle.json         the provenance: versions, checksums, the commit
```

The shape is the shape of a CEF binary distribution, so a consumer needs no
Android special case to read it.

## Building it

The build needs a machine with roughly **150 GB of free disk**, 32 GB of
memory, the NDK, the SDK and `depot_tools`. A GitHub hosted runner has
neither the disk nor the memory; the job in
[`.github/workflows/build.yml`](.github/workflows/build.yml) therefore runs on
a **Limrun sandbox** — a machine of the account of this repository, with a
terabyte of disk and dozens of cores. The runner only orchestrates the run.

```bash
git clone https://github.com/maceip/cefpack
cd cefpack

# the toolchain: the NDK, the SDK and depot_tools, in one directory
sudo ./scripts/install-toolchain.sh /opt/trap-toolchain
source /opt/trap-toolchain/env.sh

# the build
./scripts/build-android.sh
```

The same build, on a sandbox, without a machine of your own:

```bash
export LIM_API_KEY=...            # the key of the account
./scripts/limrun-build.sh         # checks the credit, builds, pulls the bundle back
```

The account is billed by the minute. `scripts/limrun-build.sh` reads the
credit before it starts and refuses to run when there is not enough of it, so
that a build is never cut in half; the sandbox is deleted when the run ends,
whatever its outcome.

The build is four steps that take hours, not minutes:

| step | what it does | how long |
|---|---|---|
| `fetch` | the checkout of CEF and, through `gclient`, of Chromium | 1–3 h |
| `headers` | the 161 C API headers and the four that the build generates | seconds |
| `build` | GN and Ninja compile the engine for `aarch64-linux-android` | 2–8 h |
| `audit` | the verdict on the bundle | seconds |

The sources and the output of the build are cached between the runs, so only
the first build pays for the checkout.

## The pin

`crates/cefpack/manifest/cef-android.toml` is the single source of truth:
the CEF commit, the target, the NDK version, the arguments of GN and the
checksums of the headers of Chromium. A bundle is reproducible from that
file alone.

## Reading further

- [`docs/the-build.md`](docs/the-build.md) — what each step of the build does
- [`docs/the-embedding.md`](docs/the-embedding.md) — **the part that is still missing**: the Android embedding of CEF
- [`docs/header-recipes.md`](docs/header-recipes.md) — the facts that were expensive to learn
- [`docs/consume.md`](docs/consume.md) — how an application consumes the bundle

## Licences

This service is Apache-2.0-or-MIT. The engine it builds is CEF, which is
LGPL-3.0-or-later; the bundle carries `LICENSE.txt` and `NOTICE` of CEF, and
they travel with every artefact that is published. See
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
