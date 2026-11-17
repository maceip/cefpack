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
3. starts the build **detached** in it;
4. reads the log of the build until it says that it is done;
5. pulls the bundle back;
6. deletes the sandbox, whatever happened.

The build is detached because the platform ends a command that runs for a
long time without saying anything, and a build that is killed with it is a
build that is lost.  A detached build keeps running; its log is read from
the outside.

The toolchain is installed *in* the sandbox by
`scripts/install-toolchain.sh`: the NDK, the Android SDK, `depot_tools` and,
when the machine has no Rust of its own, a Rust of its own.  A sandbox has
no `sudo`, so the installer never needs it.

Two things about `depot_tools` were measured on the machine:

* its wrappers for `gn` and `ninja` refuse to run until the bootstrap has
  built the python they use.  The bootstrap is its own tool,
  `ensure_bootstrap`; `update_depot_tools` **skips it** when
  `DEPOT_TOOLS_UPDATE` is set, which is what the first version of the
  installer did.  The error it caused is exact:

  ```
  python3_bin_reldir.txt not found.  need to initialize depot_tools by
  running gclient, update_depot_tools or ensure_bootstrap.
  ```

* `gn` and `ninja` themselves are not in `depot_tools` any more: they come
  with the checkout, into `src/buildtools/linux64`, and the service looks
  in both places.


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

# the dependencies of both trees
gclient sync --no-history --shallow --force --nohooks
```

The flags of that command are not the defaults, and each of them was
measured on a real sandbox:

| flag | why |
|---|---|
| `--nohooks` | the hook of CEF configures and builds the **host** tree of Chromium, with the system libraries of a desktop Linux — cups among them.  The engine for Android needs none of that, and the hook fails on a machine that does not carry the packages of a desktop.  The work of the hook — the patches and the headers of the C API — is done by this service, with the tools that CEF ships. |
| no `--reset` | a reset rewrites the index of a tree of twenty-nine gigabytes.  The measured cost of that rewrite was **17 GB of memory** in a container that allows 16 GB, and the process that fills it is killed.  The tree is already at the commit that the manifest pins. |
| no `--with_branch_heads` | the branches of Chromium move; the build wants the commit. |
| `--shallow --no-history` | the history of a tree that is pinned by a commit is not needed for anything. |

The `.gclient` file that the last command reads names two solutions — `src`
and `src/cef` — and says that neither is *managed* by `gclient`: the commits
are pinned by this service, and `gclient` is there for the dependencies.

The Chromium revision **is** written in the manifest.  CEF's own `DEPS` file
carries only its hook and names no revision of Chromium, so the pin of the
Chromium side belongs to the manifest, next to the pin of CEF.

The checkout is large — tens of gigabytes — and it takes hours.  This is the
reason the build needs its own machine and its own cache.

### The order of the build

The order of the steps is a memory decision, and it is measured:

```
1. the compiler of the service      ~1 GB
2. the checkout of the sources      the page cache of a 29 GB tree
3. the toolchain                    the NDK, the SDK, depot_tools
4. the engine                       gn gen, then ninja
5. the headers, the bundle, the verdict, the FFI
```

The checkout comes second, while the container holds nothing but the
compiler, because the page cache of the tree is what reaches the ceiling:
the measured peak was 15.9 GB against a limit of 16 GB, with the processes
themselves at 69 MB each.  The toolchain comes third, because the NDK and
the SDK are three gigabytes of files that the checkout does not need.

The page cache of the tree is **given back** at the end of the checkout, file
by file, with `posix_fadvise(POSIX_FADV_DONTNEED)`.  The pages are not needed
again — the tree is on the disk, and the kernel reads it back when it has to —
and the kernel has no way of doing it for a whole tree: `/proc/sys/vm/drop_caches`
needs the privilege of the superuser, and the service has no right to it.

An earlier run died in the step that follows the checkout, with the agent of
the sandbox unreachable: the ceiling of the container had been reached by the
page cache of the tree, and the process that was killed was not the one that
used the memory, but the largest one at that moment — the agent of the
sandbox, which is what the service talks to.


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

The translation itself happens **before** the build, because the build reads
`cef_paths.gypi` — the file that says which files belong to the engine — and
that file is generated, not checked in:

```bash
python3 tools/translator.py --root-dir <cef>             # the translated files
```

The tool of the hashes (`version_manager.py`) does the same translation and
then computes the hashes of the API of every version of CEF, and for that it
runs the compiler of Chromium over every header of the API, once per version.
The build does not need that: the hashes of a pinned release are already in
the tree, and the service reads them in this step, where the verdict is the
C API and not the exit code of a tool.

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
gn gen out/Release --root-target=//cef:cef_android \
    --args='target_os="android" target_cpu="arm64" is_android=true use_cef=true ...'
ninja -C out/Release cef:libcef cef:libcef_dll_wrapper
```

### The root of the build

The root is **not** the root of Chromium.  The root of Chromium is
`//:gn_all`, which configures every test of the tree.

The root is `//cef:cef_android`, a group that the patch of the service
adds to the tree of CEF: the engine and the shim of the C API, and
nothing else.  The group of CEF that is in the tree (`//cef:cef`) is the
sample applications, not the engine.

The label goes into `--root-target=`, and the two are not
interchangeable: `--root=` names the **directory** that `gn` reads its
`.gn` file from, and a label in it is read as a path.  The build then
stops with a message about a path that does not exist:

```text
ERROR Root source path not found.
The path "//cef:cef_android" doesn't exist.
```

The targets of Ninja are named by their **label** too — `cef:libcef`
rather than `libcef` — because Ninja writes a phony for every GN target
under its label, and the file name of a target is not unique in a tree
this size.

### The patches of the service

CEF has no Android target, and the build says so in the only way it can.
Its own `BUILD.gn` asserts three flags that Chromium turns off for
Android:

```text
ERROR at //cef/BUILD.gn:255:1: Assertion failed.
    assert(enable_print_preview)
```

The flags cannot simply be turned on: Chromium's own `grit` asserts the
opposite, in the same build, so the two assertions cannot both hold.  The
patch that the service carries relaxes the assertions of CEF for Android
instead of turning on flags that Chromium refuses, and it adds the group
that is the root of the build.  It is a diff against the pinned commit of
CEF, it is applied to the tree after the checkout, and it is idempotent.

The group is test-only, because `libcef` is: CEF marks the engine as
test-only so that it may depend on `libcef_test_support`, which is
test-only.  GN refuses a dependency of a normal target on a test-only
one:

```text
ERROR at //cef/BUILD.gn:1:1: Test-only dependency not allowed.
```

There is a second patch, and it goes to the tree of **Chromium**.  CEF's
own patcher applies a patch of CEF to `base/test/BUILD.gn` that changes
the type of the target of the trace processor from a `shared_library` to
a `component`.  On Android a `component` is a `static_library` —
Chromium asserts that Android is never a component build — and the
default configurations of a `static_library` do not carry
`//build/config/android:hide_all_but_jni_onload`, which only shared
libraries get.  The target then tries to remove a config that was never
there:

```text
ERROR at //base/test/BUILD.gn:742:18: Item not found
    configs -= [ "//build/config/android:hide_all_but_jni_onload" ]
```

The patch of the service changes the condition of that removal so that it
happens only for the target type that carries the config.  It is applied
**after** the patches of CEF, because CEF's patcher rewrites that file,
and it is a diff against the pinned commit of Chromium, so a Chromium
that changes the line stops the build with a message that says so.

Both patches are applied in exactly three states — already there, fits,
or does not fit — and the result is read back, because a patch that git
accepted and that did not change the file is not a patch.

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
