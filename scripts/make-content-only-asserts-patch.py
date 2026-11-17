#!/usr/bin/env python3
"""Make the patch that lets the content alone be configured.

Chromium says in many files of the desktop that the file is a file of
the desktop:

    assert(is_win || is_mac || is_linux || is_chromeos)
    assert(!is_android)

The first says that the file is not read for Android, the second says
the same thing the other way round.  Both are right — the files *are*
the files of the desktop — and both stop the configuration of a build of
the content alone, because GN reads a file when a target in it is named
and it does not care whether the target is built.

The build of the content alone does not build those targets.  It only
reads the files, because the name of a target is in a list of
dependencies or in a list of the names that may depend on it.  So the
assertions are relaxed for that build, and only for it:

    assert(is_win || is_mac || is_linux || is_chromeos || cef_content_only)
    assert(!is_android || cef_content_only)

The patch is made from the files of the pinned revision — the ones that
git holds — and never by hand: a header that counts its body wrongly
makes git apply the patch in part and in silence.

Run it in the root of the checkout of Chromium:

    python3 scripts/make-content-only-asserts-patch.py

It writes `content-only-asserts.patch` next to the script, and it says
how many files it touches.
"""

import difflib
import os
import pathlib
import sys

# The assertions that say that the file is a file of the desktop, and
# what they say when the build is the build of the content alone.
THE_DESKTOP = "assert(is_win || is_mac || is_linux || is_chromeos)"
NOT_ANDROID = "assert(!is_android)"

# The files that the other patches of the service touch.  Two patches
# that touch one file cannot both be applied: when a patch does not fit,
# the service gives the file back to git, and the changes of the other
# patch are gone with it.
ALREADY_PATCHED = {
    "BUILD.gn",
    "base/test/BUILD.gn",
    "build/config/BUILDCONFIG.gn",
    "build/toolchain/get_lld_read_workers.py",
    "chrome/BUILD.gn",
    "chrome/browser/media/webrtc/BUILD.gn",
    "chrome/browser/ui/BUILD.gn",
    "extensions/browser/BUILD.gn",
    "extensions/renderer/BUILD.gn",
    "tools/grit/grit_args.gni",
    "ui/base/BUILD.gn",
}

# The directories that are not part of the tree of Chromium that the
# service patches.
# The tree of CEF is a checkout of its own, with its own patches — the
# patch of the service that goes to the tree of CEF is the one that
# relaxes the assertions of the root of it.
SKIP = {
    ".git",
    "out",
    "cef",
    "third_party/llvm-build",
    "third_party/rust-toolchain",
}


def the_files(root: pathlib.Path):
    for base, directories, names in os.walk(root):
        relative = os.path.relpath(base, root)
        directories[:] = [
            name
            for name in directories
            if os.path.normpath(os.path.join(relative, name)) not in SKIP
        ]
        if "BUILD.gn" in names:
            yield pathlib.Path(base) / "BUILD.gn"


def the_source(root: pathlib.Path, path: pathlib.Path) -> str:
    import subprocess

    name = str(path.relative_to(root))
    done = subprocess.run(
        ["git", "show", "HEAD:" + name],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    return done.stdout


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    out = []
    touched = 0
    skipped = 0
    for path in the_files(root):
        try:
            source = the_source(root, path)
        except Exception:  # noqa: BLE001
            # Some directories of the tree are checkouts of their own
            # (the data of the tests, for one).  The service does not
            # patch them, and neither does this script.
            skipped += 1
            continue
        if THE_DESKTOP not in source and NOT_ANDROID not in source:
            continue
        name = str(path.relative_to(root))
        if name in ALREADY_PATCHED:
            continue
        lines = source.split("\n")
        changed = []
        for line in lines:
            if THE_DESKTOP in line:
                line = line.replace(
                    THE_DESKTOP,
                    "assert(is_win || is_mac || is_linux || is_chromeos || "
                    "cef_content_only)",
                )
            elif NOT_ANDROID in line:
                line = line.replace(
                    NOT_ANDROID, "assert(!is_android || cef_content_only)"
                )
            changed.append(line)
        if changed == lines:
            continue
        name = str(path.relative_to(root))
        diff = list(
            difflib.unified_diff(
                source.split("\n"), changed, lineterm="", n=3
            )
        )
        if not diff:
            continue
        out.append(f"diff --git a/{name} b/{name}")
        out.append(f"--- a/{name}")
        out.append(f"+++ b/{name}")
        out.extend(diff[2:])
        touched += 1

    if not out:
        print("there is no assertion to relax")
        return 1
    out.append("")
    patch = "\n".join(out)
    if not patch.endswith("\n"):
        patch += "\n"

    here = pathlib.Path(__file__).resolve().parent
    target = here / "content-only-asserts.patch"
    target.write_text(patch)
    print(f"the patch is written: {target} ({len(patch)} bytes)")
    print(f"it touches {touched} files")
    if skipped:
        print(f"it leaves {skipped} files alone: they are checkouts of their own")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
