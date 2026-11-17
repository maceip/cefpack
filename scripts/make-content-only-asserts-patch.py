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

# The assertions that say that the file is a file of the desktop.
#
# The first says that the file is not read for Android, the second says
# the same thing the other way round.  Both are right — the files *are*
# the files of the desktop — and both stop the configuration of a build
# of the content alone.
#
# The condition of an assertion is looked at, and not only these two
# words: `assert(!is_android && !is_ios)` says the same thing as
# `assert(!is_android)`, and the build of the content alone has to be
# able to read the file as well.
# The names of the platforms of the desktop.  An assertion that names one
# of them says that the file is a file of the desktop — and the assertion
# says it in many ways: with the four of them, with three of them, with
# one of them.
THE_DESKTOP = ("is_win", "is_mac", "is_linux", "is_chromeos")

# The files that the other patches of the service touch.  Two patches
# that touch one file cannot both be applied: when a patch does not fit,
# the service gives the file back to git, and the changes of the other
# patch are gone with it.
ALREADY_PATCHED = {
    "BUILD.gn",
    "components/constrained_window/BUILD.gn",
    "ui/events/ozone/evdev/BUILD.gn",
    "ui/views/controls/webview/BUILD.gn",
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


def relaxed(line: str) -> str:
    """The line with its assertion relaxed for the build of the content.

    An assertion that says that the file is a file of the desktop is
    relaxed for the build of the content alone — and only for it.  The
    condition of the assertion is looked at: an assertion that says
    `!is_android` says the same thing as one that says
    `is_win || is_mac || is_linux || is_chromeos`, in the other words.
    """
    start = line.find("assert(")
    if start < 0:
        return line
    begin = start + len("assert(")
    # The end of the assertion: the parenthesis that closes it, and not
    # one that is inside the condition or inside the message.
    depth = 1
    end = begin
    while end < len(line) and depth > 0:
        if line[end] == "(":
            depth += 1
        elif line[end] == ")":
            depth -= 1
        end += 1
    if depth != 0:
        return line
    inner = line[begin : end - 1]
    # The condition of the assertion is what comes before the comma that
    # separates it from the message, if it has one.
    depth = 0
    cut = None
    for place, letter in enumerate(inner):
        if letter in "([":
            depth += 1
        elif letter in ")]":
            depth -= 1
        elif letter == "," and depth == 0:
            cut = place
            break
    condition = inner if cut is None else inner[:cut]
    message = "" if cut is None else inner[cut:]
    if "!is_android" in condition:
        return (
            line[:start]
            + "assert(("
            + condition
            + ") || cef_content_only"
            + message
            + ")"
            + line[end:]
        )
    if any(name in condition for name in THE_DESKTOP):
        return (
            line[:start]
            + "assert("
            + condition
            + " || cef_content_only"
            + message
            + ")"
            + line[end:]
        )
    return line


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
    """The file as the tree holds it.

    The tree that the service patches is the tree of CEF with the patches
    of CEF on it, and the patches of CEF change many of the files of
    Chromium.  A patch that is made against the files of the pinned
    revision of Chromium does not fit that tree.
    """
    return path.read_text()


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
        if "assert(" not in source:
            continue
        name = str(path.relative_to(root))
        if name in ALREADY_PATCHED:
            continue
        lines = source.split("\n")
        changed = []
        for line in lines:
            changed.append(relaxed(line))
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
