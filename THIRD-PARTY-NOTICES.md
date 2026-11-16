# Third party notices

This repository contains the tooling that **builds** the Chromium Embedded
Framework for Android.  It contains no code of CEF and no code of Chromium;
it builds them from their own sources and it hands the result over.

## What a consumer receives

The bundle that this repository produces contains:

| component | licence | where the licence is |
|---|---|---|
| Chromium Embedded Framework (`libcef.so`, `libcef_dll_wrapper.a`, the headers, the resources) | **LGPL-3.0-or-later** | `LICENSE.txt` inside the bundle, and `NOTICE` |
| Chromium (inside the engine) | BSD-style, and the other licences of Chromium | `NOTICE` inside the bundle, and the licences of Chromium that the engine carries |
| the tooling of this repository (`crates/cefpack`, the scripts, the workflows) | Apache-2.0-or-MIT | `LICENSE-APACHE`, `LICENSE-MIT` in this repository |

The licences of the engine travel with the binary.  Every bundle carries
`LICENSE.txt` and `NOTICE` of CEF, and the audit of a bundle fails when
they are missing.  A release that carries an APK carries the licences as
well.

## The build

The pinned revision is CEF `6028375a4532fb89d23b58635f5c0d3a82c93959`
(CEF 156.0.30), which tracks Chromium 156.0.8078.96.  Both are built from
source; neither is downloaded as a package.

The licence of CEF is LGPL-3.0-or-later and is reproduced in the bundle of
every build.  The licence of Chromium is the set of licences that Chromium
itself carries, and it is reproduced by the `NOTICE` of the engine.

## The headers of Chromium

The bindings are generated against a handful of headers of Chromium
(`net/base/net_error_list.h`, the colour identifiers and the command
identifiers).  They are fetched at the pinned revision and their SHA-256
checksums are pinned in `crates/cefpack/manifest/cef-android.toml`.  These
headers are part of Chromium and are under the licences of Chromium.
