# What stands between CEF and Android

This is the account of a build that was carried out on a Limrun sandbox, with
the service of this repository, against the pinned sources: CEF `156.0.30`
(commit `6028375a4532fb89d23b58635f5c0d3a82c93959`) and Chromium
`156.0.8078.96` (commit `2ad9b7f5a86846e0b264090723a6a78964bb84c4`).

The build was not finished.  This document says how far it went, what stopped
it, and what the stopping point means — measured, not guessed.

## How far it went

The service did everything it was built to do:

| step | result |
|---|---|
| the plan | the machine has everything the build needs |
| the checkout of the sources | **done** — 40 GB, 118 patches of CEF applied |
| the translation of CEF | **done** — `cef_paths.gypi` and the wrappers written |
| the configuration of the build | **reached** the user interface of Chrome |
| the compilation of the engine | **not reached** |

The checkout was the step that had killed the three earlier runs, and it is
done now because the service gives the page cache of the machine back while
the tree is written (`the-build.md`, "the order of the build").

## The guards, one by one

Chromium and CEF are written for the desktop.  The configuration of the build
for Android stops at every place where one of them says so.  These are the
guards, in the order the build met them.

### 1. The core of the extensions — **solved**

```text
ERROR at //extensions/common/BUILD.gn:15:1: Assertion failed.
assert(enable_extensions_core)
```

The browser of CEF needs the core of the extensions, and Chromium builds it
for the desktop and for the desktop build of Android:

```gn
enable_extensions_core = enable_extensions || enable_desktop_android_extensions
enable_desktop_android_extensions = is_desktop_android
```

The build therefore uses `is_desktop_android=true`, which is Chromium's own
configuration for "the desktop browser on Android".  The guard is gone.

### 2. The framework of the views — **the wall**

```text
ERROR at //ui/views/controls/webview/BUILD.gn:8:1: Assertion failed.
assert(toolkit_views)
```

The browser of CEF — the Alloy browser — is built with the framework of the
views, and Chromium builds that framework for the desktop platforms only:

```gn
toolkit_views = is_mac || is_win || is_linux || is_chromeos || is_fuchsia
```

The flag is tied to the desktop in one more place, the build of the
resources, and that is the guard that meets the build next:

```text
ERROR at //tools/grit/grit_args.gni:18:1: Assertion failed.
assert(toolkit_views ==
       (is_chromeos || is_fuchsia || is_linux || is_mac || is_win))
```

The service relaxes that one (`chromium-android-toolkit-views.patch`), and
the build goes on — **into the user interface of Chrome**:

```text
ERROR at //chrome/browser/ui/BUILD.gn:3544:5: Undefined identifier.
    sources += [
    ^------
See //chrome/BUILD.gn:1823:7: which caused the file to be included.
```

`//chrome/browser/ui` has **an Android branch of its own, and that branch
does not use the views**: the sources of the tab strip and of the browser
view are added only under `if (toolkit_views)`, and in the branch of Android
the variable `sources` is never defined.  Forcing the flag on therefore
takes the target into the desktop branch, which needs Aura and the windowing
of the desktop:

```gn
if (toolkit_views) {
  sources += [
    "views/frame/base_tab_strip_region_view.cc",
    "views/frame/browser_view.cc",
    ...
```

There is no third way: with `toolkit_views` off, the browser of CEF cannot
be built at all; with it on, the user interface of Chrome has to be built
for Android, and Chromium has never built it for Android.

### 3. The guards that are before the wall

These are the ones that stand between the build and the wall.  Each of them
is a flag of Chromium that it sets for the desktop, and each of them is
turned on for this build:

| guard | flag |
|---|---|
| `assert(!is_android)` in `//content/browser/tracing/BUILD.gn` | the resources of the tracing |
| `assert(false, "unsupported_platform")` in `//media/cdm/library_cdm/cdm_paths.gni` | `enable_library_cdms=false` |
| `assert(enable_pdf)` in `//components/pdf/renderer/BUILD.gn` | `enable_pdf=true` |
| `assert(enable_plugins, ...)` in `//pdf/BUILD.gn` | `enable_plugins=true` |

A sweep that relaxes every `assert` of the tree of Chromium one at a time
relaxed **two** of them and then met an error that is not an assertion at
all: the undefined variable of the user interface of Chrome, above.  So the
count of the assertions is small.  The count of the *work* is not.

## What the wall means

To build the engine of CEF for Android, the framework of the views and the
windowing of Aura have to exist on Android.  That is a port of Chromium, not
a patch of it:

* the views build their windows through Aura, and `use_aura` is off for
  Android as well (`use_aura = is_win || is_linux || is_chromeos || is_fuchsia`);
* the user interface of Chrome that CEF's browser is built on has an
  Android branch of its own, and that branch is not the views;
* the resources of the desktop are built by the `grit` tool, which ties the
  flag of the views to the desktop.

None of this is a matter of a few flags or a few patches.  It is the reason
that there is no build of CEF for Android in the world, and the reason that
the engine that the browser used before it was built the way it was: on the
Chromium that Google builds for Android, not on the sources of CEF.

## The three ways forward

1. **Port the views to Android.**  Chromium-level work: the windowing of
   Aura on Android, the native widget of Android, the resources of the
   desktop.  Weeks to months, and no guarantee.

2. **Build Chromium's Android browser from the sources, and put the C API of
   CEF over it.**  The shape that the engine of the browser had before it,
   but with nothing prebuilt: the service builds Chromium for Android — a
   target that Chromium supports — and the C API of CEF is written over it.
   The engine is not the engine of CEF; it is the Chromium of Android with
   the shape of CEF.

3. **Stop at the bundler.**  The service stays what it is: a tool that
   checks out the sources, patches them, configures the build and collects
   the bundle.  It is finished and it is tested.  The browser of the Trap
   repository embeds something else.

The first is the honest reading of "build CEF for Android from the sources".
The second is what a browser for Android can actually be.  The third is
what the repository holds today.
