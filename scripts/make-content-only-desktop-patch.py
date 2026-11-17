#!/usr/bin/env python3
"""Make the patch that takes the desktop out of the build of the content.

The patch is made from the files of the pinned revision — the ones that
git holds — and never by hand: a header that counts its body wrongly
makes git apply the patch in part and in silence.

Run it in the root of the checkout of Chromium:

    python3 scripts/make-content-only-desktop-patch.py

It writes `content-only-desktop.patch` next to the script, and it says
whether the patch applies to the tree as it is.
"""

import difflib
import pathlib
import subprocess
import sys

# The two places where the content layer reaches for the user interface of
# the desktop.  Each of them is a target that Chromium has never built
# for Android, and each of them asserts that it is not built for Android.
EDITS = [
    (
        "extensions/browser/BUILD.gn",
        'deps += [ "//components/web_modal" ]',
        [
            "# The window of the modal is the window of the desktop.  A build",
            "# of the content alone has no modal to show, and the component",
            "# that shows it brings the user interface of the desktop with it.",
        ],
    ),
    (
        "chrome/browser/media/webrtc/BUILD.gn",
        'deps += [ "//chrome/browser/ui/views/frame:browser_widget" ]',
        [
            "# The widget of the browser is the widget of the desktop.  A build",
            "# of the content alone has no browser widget, and the file that",
            "# holds it brings the user interface of the desktop with it.",
        ],
    ),
]


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    out = []
    for name, needle, comment in EDITS:
        try:
            source = subprocess.run(
                ["git", "show", "HEAD:" + name],
                cwd=root,
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        except subprocess.CalledProcessError as error:
            print(f"cannot read {name}: {error.stderr.strip()}")
            return 1
        lines = source.split("\n")
        hits = [i for i, line in enumerate(lines) if needle in line]
        if len(hits) != 1:
            print(f"{name}: the line {needle!r} is there {len(hits)} times, not once")
            return 1
        at = hits[0]
        indent = lines[at][: len(lines[at]) - len(lines[at].lstrip())]
        block = [indent + line for line in comment]
        block.append(indent + "if (!cef_content_only) {")
        block.append(indent + "  " + lines[at].strip())
        block.append(indent + "}")
        lines[at : at + 1] = block
        changed = "\n".join(lines)
        diff = list(
            difflib.unified_diff(source.split("\n"), changed.split("\n"), lineterm="", n=3)
        )
        if not diff:
            print(f"{name}: nothing changed")
            return 1
        out.append(f"diff --git a/{name} b/{name}")
        out.append(f"--- a/{name}")
        out.append(f"+++ b/{name}")
        out.extend(diff[2:])
    out.append("")
    patch = "\n".join(out)
    here = pathlib.Path(__file__).resolve().parent
    target = here / "content-only-desktop.patch"
    target.write_text(patch)
    print(f"the patch is written: {target} ({len(patch)} bytes)")

    check = subprocess.run(
        ["git", "apply", "--check", str(target)],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if check.returncode == 0:
        print("the patch applies to the tree as it is")
        return 0
    print("the patch does not apply to the tree as it is:")
    print(check.stderr.strip())
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
