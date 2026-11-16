# Consuming the bundle

The bundle is the contract between this repository and the application that
uses the engine.  It is shaped like a CEF binary distribution, so a consumer
needs no Android special case to read it.

## What is in it

```text
cef-bundle/
├── include/            the public headers of CEF and the C API headers
├── lib/
│   ├── libcef.so              the engine
│   └── libcef_dll_wrapper.a   the C API shim
├── Resources/          the resources the engine reads at run time
├── bindings/           the Rust declarations of the C API of this engine
├── LICENSE.txt         the licence of CEF (LGPL-3.0-or-later)
├── NOTICE
└── bundle.json         the provenance and the checksums
```

`bundle.json` names the version of CEF, the version of Chromium, the commit
that was built, the target, the API version of the C API and the checksum of
every file.  It is written by the service, not by hand.

## Taking it into a build

The service stages the bundle for a Gradle build:

```bash
cefpack pack cef-bundle cef-staging
```

which produces

```text
cef-staging/
├── jniLibs/arm64-v8a/libcef.so
├── assets/cef/**
├── assets/licenses/**
└── lib/libcef_dll_wrapper.a
```

The application then copies that tree into its own package:

```groovy
// the staged bundle
copy {
    from("${cefBundle}/jniLibs") { into "src/main/jniLibs" }
    from("${cefBundle}/assets")    { into "src/main/assets" }
}
```

Two rules about the package:

- the resources of the engine are **stored, not compressed** — Chromium
  reads them through a memory map, and a compressed pak cannot be mapped;
- the licences travel with the binary, both in the assets and in the
  release that carries the APK.

## The declarations of the C API

The declarations are in `bindings/aarch64_linux_android.rs`.  They are
generated from the headers of **this** engine, and the API version of the
declarations is the API version of the engine — the service refuses a
mismatch in both directions.

A consumer that vendors the declarations of CEF (the `cef-dll-sys` and
`cef` crates of `cef-rs`) points its build script at the bundle and lets it
check the version:

```rust
// the engine has to be there
let libcef = bundle.join("lib/libcef.so");
// the declarations and the engine have to agree
if bindings_api_version != bundle_api_version {
    bail!("the declarations are for {bindings_api_version}, the engine is {bundle_api_version}");
}
```

That check is not decoration.  The application that started this project
crashed on launch because the declarations of a desktop distribution were
used for Android with no check at all.

## The verdict on an APK

The service audits a built APK as well:

```bash
cefpack apk app-debug.apk --app-lib libonion_vault.so
```

It checks that the engine is in the package, that the resources are stored
and not compressed, that the licences are there, and that the native
library of the application really depends on the engine:

```text
readelf -d lib/arm64-v8a/libonion_vault.so | grep NEEDED
  → NEEDED Shared library: [libcef.so]
```

A library that does not need the engine, or an engine that is not in the
package, is a crash on the first frame.

## The gate

A bundle is not enough: the application has to start with it.  The consumer
is expected to launch the APK on an emulator before anything is published,
and to fail the build when it does not stay up.  This repository does not
run that gate — it builds the engine — but it does not claim anything about
the engine that the audit of the bundle does not prove.
