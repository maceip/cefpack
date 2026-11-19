#!/usr/bin/env python3
"""Poll Chromium Dash Stable Android & chromiumembedded/cef to sync cefpack pins.

Updates:
  - crates/cefpack/manifest/cef-android.toml (engine, source, sysroot, chromium, headers)
  - scripts/build-cefpack-aar.sh (PINNED_CHROMIUM_VERSION, PINNED_CHROMIUM)
  - embedder/cefpack_webview/java/src/dev/cefpack/android/CefpackSession.java
  - embedder/assemble_aar.py (default --chromium-version / --chromium-commit)
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import tomllib
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

CHROMIUM_DASH_ANDROID_STABLE_URL = (
    "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Android&num=10"
)
CEF_GIT_URL = "https://github.com/chromiumembedded/cef.git"
CHROMIUM_GIT_URL = "https://chromium.googlesource.com/chromium/src.git"
GITHUB_API_BASE = "https://api.github.com"


def http_get_bytes(url: str, headers: dict[str, str] | None = None, timeout: int = 30) -> bytes:
    req_headers = {"User-Agent": "cefpack-upstream-sync/1.0"}
    if headers:
        req_headers.update(headers)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and ("api.github.com" in url or "raw.githubusercontent.com" in url):
        req_headers.setdefault("Authorization", f"Bearer {token}")
    req = urllib.request.Request(url, headers=req_headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def fetch_chromium_dash_stable_android() -> list[dict[str, Any]]:
    try:
        raw = http_get_bytes(CHROMIUM_DASH_ANDROID_STABLE_URL, timeout=20)
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, list) else []
    except Exception as exc:
        print(f"warning: Chromium Dash query failed ({exc}); falling back to CEF branch pins", file=sys.stderr)
        return []


def list_cef_numeric_branches(cef_git_url: str = CEF_GIT_URL) -> dict[int, str]:
    out = subprocess.check_output(
        ["git", "ls-remote", "--heads", cef_git_url],
        text=True,
        timeout=60,
    )
    branches: dict[int, str] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        sha, ref = parts
        if ref.startswith("refs/heads/"):
            name = ref[len("refs/heads/") :]
            if name.isdigit() and len(name) >= 4:
                branches[int(name)] = sha
    return branches


def select_target_cef_branch(
    current_branch: int,
    cef_branches: dict[int, str],
    dash_releases: list[dict[str, Any]],
    override_branch: int | None = None,
) -> int:
    if override_branch is not None:
        if override_branch not in cef_branches:
            raise RuntimeError(f"Requested CEF branch {override_branch} not found in upstream CEF")
        return override_branch

    candidate = current_branch
    for rel in dash_releases:
        ver = str(rel.get("version") or "")
        parts = ver.split(".")
        if len(parts) == 4 and parts[2].isdigit():
            build_num = int(parts[2])
            if build_num in cef_branches and build_num > candidate:
                candidate = build_num

    if candidate not in cef_branches:
        higher = [b for b in sorted(cef_branches) if b >= current_branch]
        if higher:
            return higher[0]
        raise RuntimeError(f"Current CEF branch {current_branch} not found in upstream CEF branches")
    return candidate


def parse_chromium_compatibility(text: str) -> str:
    match = re.search(r"['\"]chromium_checkout['\"]\s*:\s*['\"]([^'\"]+)['\"]", text)
    if not match:
        raise ValueError("Could not find chromium_checkout in CHROMIUM_BUILD_COMPATIBILITY.txt")
    val = match.group(1).strip()
    if val.startswith("refs/tags/"):
        return val[len("refs/tags/") :]
    return val


def parse_sysroot_from_deps(deps_text: str, sysroot_path: str) -> dict[str, Any]:
    escaped_path = re.escape(sysroot_path)
    pattern = re.compile(
        rf"['\"]{escaped_path}['\"]\s*:\s*\{{(.*?)\n  \}},",
        re.DOTALL,
    )
    block_match = pattern.search(deps_text)
    if not block_match:
        raise ValueError(f"Sysroot entry {sysroot_path!r} not found in Chromium DEPS")
    block = block_match.group(1)

    bucket_m = re.search(r"['\"]bucket['\"]\s*:\s*['\"]([^'\"]+)['\"]", block)
    object_m = re.search(r"['\"]object_name['\"]\s*:\s*['\"]([^'\"]+)['\"]", block)
    sha_m = re.search(r"['\"]sha256sum['\"]\s*:\s*['\"]([0-9a-fA-F]{64})['\"]", block)
    size_m = re.search(r"['\"]size_bytes['\"]\s*:\s*(\d+)", block)
    if not (bucket_m and object_m and sha_m and size_m):
        raise ValueError(f"Incomplete sysroot metadata in Chromium DEPS for {sysroot_path!r}")

    return {
        "bucket": bucket_m.group(1),
        "object": object_m.group(1),
        "sha256": sha_m.group(1).lower(),
        "size": int(size_m.group(1)),
    }


def compute_cef_version(cef_repo: Path, base_ref: str, head_ref: str, chromium_version: str) -> tuple[str, str]:
    cef_commit = subprocess.check_output(
        ["git", "-C", str(cef_repo), "rev-parse", head_ref],
        text=True,
    ).strip()
    revs = subprocess.check_output(
        ["git", "-C", str(cef_repo), "rev-list", "--reverse", f"{base_ref}..{head_ref}"],
        text=True,
    ).splitlines()

    minor = 0
    bugfix = 0
    for rev in revs:
        changed = subprocess.check_output(
            ["git", "-C", str(cef_repo), "diff-tree", "--no-commit-id", "--name-only", "-r", rev],
            text=True,
        ).splitlines()
        if any("cef_api_versions.json" in f for f in changed):
            minor += 1
            bugfix = 0
        else:
            bugfix += 1

    major = chromium_version.split(".")[0]
    cef_ver = f"{major}.{minor}.{bugfix}+g{cef_commit[:7]}+chromium-{chromium_version}"
    return cef_ver, cef_commit


def inspect_cef_branch(
    branch: int,
    patch_file: Path,
    cef_git_url: str = CEF_GIT_URL,
    cef_commit_override: str | None = None,
) -> tuple[str, str, str]:
    with tempfile.TemporaryDirectory(prefix="cefpack-cef-sync-") as tmp:
        repo = Path(tmp) / "cef"
        repo.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "-C", str(repo), "init", "--quiet"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "fetch",
                "--filter=blob:none",
                "--no-tags",
                cef_git_url,
                "refs/heads/master:refs/remotes/origin/master",
                f"refs/heads/{branch}:refs/remotes/origin/{branch}",
            ],
            check=True,
            timeout=180,
        )
        target_ref = cef_commit_override or f"refs/remotes/origin/{branch}"
        compat_text = subprocess.check_output(
            ["git", "-C", str(repo), "show", f"{target_ref}:CHROMIUM_BUILD_COMPATIBILITY.txt"],
            text=True,
        )
        chromium_version = parse_chromium_compatibility(compat_text)
        cef_version, cef_commit = compute_cef_version(
            repo,
            "refs/remotes/origin/master",
            target_ref,
            chromium_version,
        )

        if patch_file.is_file():
            subprocess.run(
                ["git", "-C", str(repo), "checkout", "--quiet", "--detach", cef_commit],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "apply", "--check", str(patch_file)],
                check=True,
            )
        return cef_version, cef_commit, chromium_version


def resolve_chromium_tag_commit(
    chromium_version: str,
    dash_releases: list[dict[str, Any]],
) -> str:
    if re.fullmatch(r"[0-9a-f]{40}", chromium_version):
        return chromium_version

    for rel in dash_releases:
        if str(rel.get("version") or "") == chromium_version:
            sha = str((rel.get("hashes") or {}).get("chromium") or "").strip().lower()
            if re.fullmatch(r"[0-9a-f]{40}", sha):
                return sha

    try:
        out = subprocess.check_output(
            [
                "git",
                "ls-remote",
                CHROMIUM_GIT_URL,
                f"refs/tags/{chromium_version}",
                f"refs/tags/{chromium_version}^{{}}",
            ],
            text=True,
            timeout=45,
        )
        peeled = ""
        direct = ""
        for line in out.splitlines():
            parts = line.split()
            if len(parts) != 2:
                continue
            sha, ref = parts
            if ref.endswith("^{}"):
                peeled = sha.strip().lower()
            else:
                direct = sha.strip().lower()
        chosen = peeled or direct
        if re.fullmatch(r"[0-9a-f]{40}", chosen):
            return chosen
    except Exception:
        pass

    try:
        ref_raw = subprocess.check_output(
            ["gh", "api", f"repos/chromium/chromium/git/ref/tags/{chromium_version}"],
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
        ref_data = json.loads(ref_raw.decode("utf-8"))
    except Exception:
        ref_data = json.loads(
            http_get_bytes(
                f"{GITHUB_API_BASE}/repos/chromium/chromium/git/ref/tags/{chromium_version}"
            ).decode("utf-8")
        )
    obj = ref_data.get("object") or {}
    sha = str(obj.get("sha") or "").strip().lower()
    if obj.get("type") == "tag":
        try:
            tag_raw = subprocess.check_output(
                ["gh", "api", str(obj["url"])],
                stderr=subprocess.DEVNULL,
                timeout=30,
            )
            tag_data = json.loads(tag_raw.decode("utf-8"))
        except Exception:
            tag_data = json.loads(http_get_bytes(str(obj["url"])).decode("utf-8"))
        sha = str((tag_data.get("object") or {}).get("sha") or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RuntimeError(f"Failed to resolve 40-char commit SHA for Chromium {chromium_version}")
    return sha


def fetch_chromium_file(base_url: str, chromium_ref: str, rel_path: str) -> bytes:
    clean_base = base_url.rstrip("/")
    try:
        return http_get_bytes(f"{clean_base}/{chromium_ref}/{rel_path}", timeout=45)
    except Exception:
        pass
    try:
        return http_get_bytes(
            f"{GITHUB_API_BASE}/repos/chromium/chromium/contents/{rel_path}?ref={chromium_ref}",
            headers={"Accept": "application/vnd.github.raw"},
            timeout=45,
        )
    except Exception:
        pass
    try:
        return subprocess.check_output(
            [
                "gh",
                "api",
                f"repos/chromium/chromium/contents/{rel_path}?ref={chromium_ref}",
                "-H",
                "Accept: application/vnd.github.raw",
            ],
            stderr=subprocess.DEVNULL,
            timeout=45,
        )
    except Exception:
        gs_url = f"https://chromium.googlesource.com/chromium/src/+/{chromium_ref}/{rel_path}?format=TEXT"
        b64 = http_get_bytes(gs_url, timeout=45)
        return base64.b64decode(b64)


def replace_exactly_once(text: str, pattern: str, replacement: str, label: str) -> str:
    new_text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError(f"Expected exactly 1 match for {label}, matched {count}")
    return new_text


def rewrite_manifest_toml(
    manifest_text: str,
    *,
    cef_version: str,
    chromium_version: str,
    branch: str,
    cef_commit: str,
    chromium_commit: str,
    sysroot: dict[str, Any],
    header_shas: dict[str, str],
) -> str:
    updated = manifest_text
    updated = replace_exactly_once(
        updated,
        r'^cef_version = "[^"]+"$',
        f'cef_version = "{cef_version}"',
        "engine.cef_version",
    )
    updated = replace_exactly_once(
        updated,
        r'^chromium_version = "[^"]+"$',
        f'chromium_version = "{chromium_version}"',
        "engine.chromium_version",
    )
    updated = re.sub(
        r'^branch = "\d+"$',
        f'branch = "{branch}"',
        updated,
        count=2,
        flags=re.MULTILINE,
    )
    updated = replace_exactly_once(
        updated,
        r'(\[source\][\s\S]*?^commit = ")[0-9a-f]{40}(")',
        rf"\g<1>{cef_commit}\2",
        "source.commit",
    )
    updated = replace_exactly_once(
        updated,
        r'(\[sysroot\][\s\S]*?^bucket = ")[^"]+(")',
        rf'\g<1>{sysroot["bucket"]}\2',
        "sysroot.bucket",
    )
    updated = replace_exactly_once(
        updated,
        r'(\[sysroot\][\s\S]*?^object = ")[^"]+(")',
        rf'\g<1>{sysroot["object"]}\2',
        "sysroot.object",
    )
    updated = replace_exactly_once(
        updated,
        r'(\[sysroot\][\s\S]*?^sha256 = ")[0-9a-f]{64}(")',
        rf'\g<1>{sysroot["sha256"]}\2',
        "sysroot.sha256",
    )
    updated = replace_exactly_once(
        updated,
        r'(\[sysroot\][\s\S]*?^size = )\d+',
        rf'\g<1>{sysroot["size"]}',
        "sysroot.size",
    )
    updated = replace_exactly_once(
        updated,
        r'(\[chromium\][\s\S]*?^ref = ")[^"]+(")',
        rf"\g<1>{chromium_version}\2",
        "chromium.ref",
    )
    updated = replace_exactly_once(
        updated,
        r'(\[chromium\][\s\S]*?^commit = ")[0-9a-f]{40}(")',
        rf"\g<1>{chromium_commit}\2",
        "chromium.commit",
    )

    for path, sha in header_shas.items():
        escaped = re.escape(path)
        updated = replace_exactly_once(
            updated,
            rf'(^\[\[chromium\.headers\]\]\npath = "{escaped}"\nsha256 = ")[0-9a-f]{{64}}(")',
            rf"\g<1>{sha}\2",
            f"chromium.headers[{path}]",
        )

    parsed = tomllib.loads(updated)
    assert parsed["engine"]["chromium_version"] == chromium_version
    assert parsed["source"]["commit"] == cef_commit
    assert parsed["chromium"]["commit"] == chromium_commit
    assert parsed["sysroot"]["sha256"] == sysroot["sha256"]
    return updated


def update_repo_files(
    root: Path,
    *,
    old_chromium_version: str,
    old_chromium_commit: str,
    cef_version: str,
    chromium_version: str,
    branch: str,
    cef_commit: str,
    chromium_commit: str,
    sysroot: dict[str, Any],
    header_shas: dict[str, str],
) -> None:
    manifest_path = root / "crates/cefpack/manifest/cef-android.toml"
    manifest_text = manifest_path.read_text(encoding="utf-8")
    manifest_path.write_text(
        rewrite_manifest_toml(
            manifest_text,
            cef_version=cef_version,
            chromium_version=chromium_version,
            branch=branch,
            cef_commit=cef_commit,
            chromium_commit=chromium_commit,
            sysroot=sysroot,
            header_shas=header_shas,
        ),
        encoding="utf-8",
    )

    aar_script = root / "scripts/build-cefpack-aar.sh"
    if aar_script.is_file():
        txt = aar_script.read_text(encoding="utf-8")
        if "PINNED_CHROMIUM_VERSION=" in txt:
            txt = replace_exactly_once(
                txt,
                r'^PINNED_CHROMIUM_VERSION="[^"]+"$',
                f'PINNED_CHROMIUM_VERSION="{chromium_version}"',
                "build-cefpack-aar.sh PINNED_CHROMIUM_VERSION",
            )
        txt = replace_exactly_once(
            txt,
            r'^PINNED_CHROMIUM="[0-9a-f]{40}"$',
            f'PINNED_CHROMIUM="{chromium_commit}"',
            "build-cefpack-aar.sh PINNED_CHROMIUM",
        )
        aar_script.write_text(txt, encoding="utf-8")

    session_java = root / "embedder/cefpack_webview/java/src/dev/cefpack/android/CefpackSession.java"
    if session_java.is_file():
        txt = session_java.read_text(encoding="utf-8")
        txt = txt.replace(f'"{old_chromium_version}"', f'"{chromium_version}"')
        session_java.write_text(txt, encoding="utf-8")

    assemble_py = root / "embedder/assemble_aar.py"
    if assemble_py.is_file():
        txt = assemble_py.read_text(encoding="utf-8")
        txt = txt.replace(f'"{old_chromium_version}"', f'"{chromium_version}"')
        txt = txt.replace(f'"{old_chromium_commit}"', f'"{chromium_commit}"')
        assemble_py.write_text(txt, encoding="utf-8")


def run_self_test() -> None:
    compat = "{\n  'chromium_checkout': 'refs/tags/156.0.8078.100',\n}\n"
    assert parse_chromium_compatibility(compat) == "156.0.8078.100"

    sample_deps = """
deps = {
  'src/build/linux/debian_bullseye_amd64-sysroot': {
    'bucket': 'chrome-linux-sysroot',
    'condition': 'checkout_linux and checkout_x64 and non_git_source',
    'dep_type': 'gcs',
    'objects': [
      {
        'generation': 1770327973518330,
        'object_name': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'sha256sum': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'size_bytes': 19999999,
      },
    ],
  },
}
"""
    sr = parse_sysroot_from_deps(sample_deps, "src/build/linux/debian_bullseye_amd64-sysroot")
    assert sr["bucket"] == "chrome-linux-sysroot"
    assert sr["sha256"] == "a" * 64
    assert sr["size"] == 19999999

    cef_branches = {8037: "1" * 40, 8078: "2" * 40, 8127: "3" * 40}
    dash = [{"version": "156.0.8078.100"}, {"version": "155.0.8037.50"}]
    assert select_target_cef_branch(8078, cef_branches, dash) == 8078
    dash_next = [{"version": "158.0.8127.20"}]
    assert select_target_cef_branch(8078, cef_branches, dash_next) == 8127
    # Never downgrade if current pin is ahead of Chromium Dash
    assert select_target_cef_branch(8127, cef_branches, dash) == 8127

    repo_root = Path(__file__).resolve().parent.parent
    real_manifest = (repo_root / "crates/cefpack/manifest/cef-android.toml").read_text(encoding="utf-8")
    parsed_real = tomllib.loads(real_manifest)

    with tempfile.TemporaryDirectory(prefix="cefpack-sync-selftest-") as tmp:
        w = Path(tmp)
        (w / "crates/cefpack/manifest").mkdir(parents=True)
        (w / "scripts").mkdir(parents=True)
        (w / "embedder/cefpack_webview/java/src/dev/cefpack/android").mkdir(parents=True)
        (w / "crates/cefpack/manifest/cef-android.toml").write_text(real_manifest, encoding="utf-8")
        (w / "scripts/build-cefpack-aar.sh").write_text(
            f'PINNED_CHROMIUM_VERSION="{parsed_real["engine"]["chromium_version"]}"\n'
            f'PINNED_CHROMIUM="{parsed_real["chromium"]["commit"]}"\n',
            encoding="utf-8",
        )
        (w / "embedder/cefpack_webview/java/src/dev/cefpack/android/CefpackSession.java").write_text(
            f'webContents.setDelegates("{parsed_real["engine"]["chromium_version"]}");\n',
            encoding="utf-8",
        )
        (w / "embedder/assemble_aar.py").write_text(
            f'parser.add_argument("--chromium-version", default="{parsed_real["engine"]["chromium_version"]}")\n'
            f'parser.add_argument("--chromium-commit", default="{parsed_real["chromium"]["commit"]}")\n',
            encoding="utf-8",
        )

        fake_headers = {h["path"]: "b" * 64 for h in parsed_real["chromium"]["headers"]}
        update_repo_files(
            w,
            old_chromium_version=parsed_real["engine"]["chromium_version"],
            old_chromium_commit=parsed_real["chromium"]["commit"],
            cef_version="156.0.32+ge603d97+chromium-156.0.8078.100",
            chromium_version="156.0.8078.100",
            branch="8078",
            cef_commit="e603d97dd5cb8b0e37d8f1daa2bc5c7eab1aa7a5",
            chromium_commit="c" * 40,
            sysroot=sr,
            header_shas=fake_headers,
        )
        reloaded = tomllib.loads((w / "crates/cefpack/manifest/cef-android.toml").read_text(encoding="utf-8"))
        assert reloaded["engine"]["chromium_version"] == "156.0.8078.100"
        assert reloaded["chromium"]["commit"] == "c" * 40
        assert 'PINNED_CHROMIUM_VERSION="156.0.8078.100"' in (
            w / "scripts/build-cefpack-aar.sh"
        ).read_text(encoding="utf-8")

        git_repo = w / "mock-cef"
        git_repo.mkdir()
        subprocess.run(["git", "-C", str(git_repo), "init", "--quiet", "-b", "master"], check=True)
        subprocess.run(["git", "-C", str(git_repo), "config", "user.name", "test"], check=True)
        subprocess.run(["git", "-C", str(git_repo), "config", "user.email", "test@example.com"], check=True)
        (git_repo / "README").write_text("root\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(git_repo), "add", "README"], check=True)
        subprocess.run(["git", "-C", str(git_repo), "commit", "--quiet", "-m", "init"], check=True)
        subprocess.run(["git", "-C", str(git_repo), "checkout", "--quiet", "-b", "8078"], check=True)
        (git_repo / "cef_api_versions.json").write_text("{}\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(git_repo), "add", "cef_api_versions.json"], check=True)
        subprocess.run(["git", "-C", str(git_repo), "commit", "--quiet", "-m", "api"], check=True)
        (git_repo / "fix.cc").write_text("// fix\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(git_repo), "add", "fix.cc"], check=True)
        subprocess.run(["git", "-C", str(git_repo), "commit", "--quiet", "-m", "bugfix"], check=True)
        ver, sha = compute_cef_version(git_repo, "master", "8078", "156.0.8078.100")
        assert ver == f"156.1.1+g{sha[:7]}+chromium-156.0.8078.100", ver

    print("sync-upstream-chromium.py --self-test PASSED")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Run offline unit/rewrite self-tests")
    parser.add_argument("--dry-run", action="store_true", help="Check upstream without modifying files")
    parser.add_argument("--force", action="store_true", help="Rewrite pins even if commits match")
    parser.add_argument("--chromium-branch", type=int, default=None, help="Explicit CEF numeric branch override")
    parser.add_argument("--cef-commit", type=str, default=None, help="Explicit 40-char CEF commit override")
    parser.add_argument("--json-out", type=Path, default=None, help="Write sync metadata JSON to path")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    root = Path(__file__).resolve().parent.parent
    manifest_path = root / "crates/cefpack/manifest/cef-android.toml"
    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))

    old_chromium_version = str(manifest["engine"]["chromium_version"])
    old_chromium_commit = str(manifest["chromium"]["commit"])
    old_cef_commit = str(manifest["source"]["commit"])
    old_branch = int(manifest["engine"]["branch"])

    dash_releases = fetch_chromium_dash_stable_android()
    cef_branches = list_cef_numeric_branches()
    target_branch = select_target_cef_branch(
        old_branch,
        cef_branches,
        dash_releases,
        override_branch=args.chromium_branch,
    )

    patch_file = root / "crates/cefpack/patches/cef-android-gn-asserts.patch"
    cef_version, cef_commit, chromium_version = inspect_cef_branch(
        target_branch,
        patch_file=patch_file,
        cef_commit_override=args.cef_commit,
    )
    chromium_commit = resolve_chromium_tag_commit(chromium_version, dash_releases)

    changed = (
        args.force
        or cef_commit != old_cef_commit
        or chromium_commit != old_chromium_commit
        or chromium_version != old_chromium_version
    )

    result: dict[str, Any] = {
        "changed": changed,
        "old_chromium_version": old_chromium_version,
        "old_chromium_commit": old_chromium_commit,
        "old_cef_commit": old_cef_commit,
        "chromium_version": chromium_version,
        "chromium_commit": chromium_commit,
        "chromium_branch": str(target_branch),
        "cef_version": cef_version,
        "cef_commit": cef_commit,
    }

    if not changed:
        print(
            f"Already up to date: Chromium {chromium_version} ({chromium_commit[:12]}), "
            f"CEF {cef_version} ({cef_commit[:12]})"
        )
        if args.json_out:
            args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        return 0

    base_url = str(manifest["chromium"]["base_url"])
    sysroot_path = str(manifest["sysroot"]["path"])
    deps_bytes = fetch_chromium_file(base_url, chromium_version, "DEPS")
    sysroot = parse_sysroot_from_deps(deps_bytes.decode("utf-8", errors="replace"), sysroot_path)

    header_shas: dict[str, str] = {}
    for hdr in manifest["chromium"].get("headers", []):
        hdr_path = str(hdr["path"])
        body = fetch_chromium_file(base_url, chromium_version, hdr_path)
        header_shas[hdr_path] = hashlib.sha256(body).hexdigest()

    result["sysroot_sha256"] = sysroot["sha256"]

    if not args.dry_run:
        update_repo_files(
            root,
            old_chromium_version=old_chromium_version,
            old_chromium_commit=old_chromium_commit,
            cef_version=cef_version,
            chromium_version=chromium_version,
            branch=str(target_branch),
            cef_commit=cef_commit,
            chromium_commit=chromium_commit,
            sysroot=sysroot,
            header_shas=header_shas,
        )
        print(
            f"Updated pins: Chromium {old_chromium_version} -> {chromium_version} ({chromium_commit[:12]}), "
            f"CEF -> {cef_version}"
        )
    else:
        print(
            f"[dry-run] Would update: Chromium {old_chromium_version} -> {chromium_version} "
            f"({chromium_commit[:12]}), CEF -> {cef_version}"
        )

    if args.json_out:
        args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
