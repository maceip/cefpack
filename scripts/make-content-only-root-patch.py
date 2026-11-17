#!/usr/bin/env python3
"""Make the patch that makes the root of the tree small.

The root `BUILD.gn` of Chromium is a group — `gn_all` — that reaches
every target of the tree, and GN resolves the dependencies of every
target that it loads.  A build that configures the content alone
therefore loads the whole tree: the browser of the desktop, the tests,
the packages of Android, and with them every assertion that says that
the desktop is not built for Android.  The build stops there, long
before the compiler runs.

For a build of the content alone, the root of the tree is a group with
nothing in it.  The patch is made from the file of the pinned revision —
the one that git holds — and never by hand: a header that counts its
body wrongly makes git apply the patch in part and in silence.

Run it in the root of the checkout of Chromium:

    python3 scripts/make-content-only-root-patch.py

or, with the file of the pinned revision in your hand:

    python3 scripts/make-content-only-root-patch.py path/to/BUILD.gn

It writes `content-only-root.patch` next to the script, and it says
whether the patch applies to the file it was made from.
"""

import difflib
import pathlib
import subprocess
import sys

# The group of the build of the content alone.  It has nothing in it:
# the build that asks for it names its own target.
GROUP = "cef_content_only"

OPENING = f"""# The root of the tree of Chromium is a group that reaches every target of
# the tree, and GN resolves the dependencies of every target that it
# loads.  A build of the content alone therefore loads the whole tree:
# the browser of the desktop, the tests, the packages of Android, and
# with them every assertion that says that the desktop is not built for
# Android.  The build stops there, long before the compiler runs.
#
# For the build of the content alone the root of the tree is a group
# with nothing in it: the build that asks for it names its own target.
if (cef_content_only) {{
  group("{GROUP}") {{
  }}
}} else {{"""

CLOSING = "}"


def the_source(where: pathlib.Path) -> str:
    """The file of the pinned revision.

    Either a directory with a checkout of Chromium in it — the file is
    read from git, so that it is the file of the pinned revision and not
    the file that the patches of the service have changed — or the file
    itself.
    """
    if where.is_dir():
        done = subprocess.run(
            ["git", "show", "HEAD:BUILD.gn"],
            cwd=where,
            capture_output=True,
            text=True,
            check=True,
        )
        return done.stdout
    return where.read_text()


def main() -> int:
    argument = sys.argv[1] if len(sys.argv) > 1 else "."
    where = pathlib.Path(argument).resolve()
    try:
        source = the_source(where)
    except subprocess.CalledProcessError as error:
        print(f"cannot read BUILD.gn: {error.stderr.strip()}")
        return 1

    # The lines of the file, without the empty line that the last
    # newline of a file leaves behind: a patch that is made against that
    # empty line does not apply to the file.
    lines = source.splitlines()

    # The licence of the file stays at the top of the file.
    head = 0
    while head < len(lines) and lines[head].startswith("#"):
        head += 1
    while head < len(lines) and not lines[head].strip():
        head += 1

    body = lines[:head] + [OPENING] + lines[head:] + [CLOSING]
    changed = "\n".join(body) + "\n"

    diff = list(
        difflib.unified_diff(
            lines, changed.splitlines(), lineterm="", n=3
        )
    )
    if not diff:
        print("nothing changed")
        return 1
    out = ["diff --git a/BUILD.gn b/BUILD.gn", "--- a/BUILD.gn", "+++ b/BUILD.gn"]
    out.extend(diff[2:])
    patch = "\n".join(out)
    # Every line of a patch ends with a newline, and the last one too: a
    # patch whose last line has none is corrupt, and git says so with the
    # number of the line and not with the name of the patch.
    if not patch.endswith("\n"):
        patch += "\n"

    here = pathlib.Path(__file__).resolve().parent
    target = here / "content-only-root.patch"
    target.write_text(patch)
    print(f"the patch is written: {target} ({len(patch)} bytes)")

    # The patch is checked against the file it was made from, in a
    # directory of its own, so that the check says something about the
    # patch and not about the tree that the service has patched.
    import tempfile

    with tempfile.TemporaryDirectory() as scratch:
        scratch_path = pathlib.Path(scratch)
        (scratch_path / "BUILD.gn").write_text(source)
        subprocess.run(
            ["git", "init", "--quiet", "--initial-branch=main"],
            cwd=scratch_path,
            check=True,
        )
        subprocess.run(["git", "add", "BUILD.gn"], cwd=scratch_path, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "user.email=make@patch",
                "-c",
                "user.name=make",
                "commit",
                "--quiet",
                "-m",
                "the file of the pinned revision",
            ],
            cwd=scratch_path,
            check=True,
        )
        check = subprocess.run(
            ["git", "apply", "--check", str(target)],
            cwd=scratch_path,
            capture_output=True,
            text=True,
        )
    if check.returncode == 0:
        print("the patch applies to the file it was made from")
        return 0
    print("the patch does not apply to the file it was made from:")
    print(check.stderr.strip())
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
