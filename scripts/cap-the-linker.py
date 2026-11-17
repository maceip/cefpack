#!/usr/bin/env python3
"""Cap the number of threads that the linker uses.

`ld.lld` reads the input of a link in parallel, and every thread that
reads a part of a library of a hundred megabytes is memory that the
container does not have: the limit of the container of the build is
sixteen gigabytes, and the page cache of the tree of the sources takes
most of them.

The flag is `--threads=N`, and it is given to the linker through the
`ldflags` of the toolchain of Android.  The toolchain of Chromium names
the flags in more than one place, so the script looks for every list of
linker flags of the tree and adds the flag to the ones that belong to a
toolchain of Android.

The script says what it did, and it says so when it did nothing: a
measurement of a link that was not capped is still a measurement, and it
has to be reported as what it is.
"""
import os
import re
import sys

FLAG = '"-Wl,--threads=2",'
MARKER = "--threads=2"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    candidates = []
    for directory in ("build/toolchain", "build/config"):
        base = os.path.join(root, directory)
        for path, _, files in os.walk(base):
            for name in files:
                if name.endswith(".gni") or name.endswith(".gn"):
                    candidates.append(os.path.join(path, name))

    changed = []
    for path in sorted(candidates):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        if MARKER in text:
            continue
        # The list of the flags of the linker of a toolchain of Android.
        if "ldflags" not in text:
            continue
        updated = re.sub(
            r"(\n(\s*)ldflags = \[\n)",
            r"\1\2  " + FLAG + "\n",
            text,
            count=1,
        )
        if updated == text:
            continue
        try:
            with open(path, "w", encoding="utf-8", errors="replace") as handle:
                handle.write(updated)
        except OSError:
            continue
        changed.append(os.path.relpath(path, root))

    if changed:
        print("the linker of the following files is capped at two threads:")
        for path in changed:
            print(f"  {path}")
    else:
        print("the linker was not capped: no list of linker flags was found")
        print("the measurement is of a link that ran with every thread it wanted")


if __name__ == "__main__":
    main()
