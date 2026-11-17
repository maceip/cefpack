//! Fetching the CEF sources.
//!
//! Nothing is downloaded as a *package*.  The service checks out the CEF
//! repository at the commit that the manifest pins and lets `gclient` pull
//! the Chromium sources and their dependencies at the revisions that CEF's own
//! `DEPS` file names.  Every revision in that file is a git SHA, so the whole
//! tree is pinned by the CEF commit alone and nothing is taken on trust from
//! a mirror.

use std::{
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{bail, Context, Result};

use crate::patch;
use crate::plan::Plan;

/// The checkout of the CEF sources.
#[derive(Debug, Clone)]
pub struct SourceTree {
    /// The directory that holds the checkout.
    pub root: PathBuf,
    /// The directory that holds the CEF sources themselves.
    pub cef_dir: PathBuf,
    /// The commit that is checked out.
    pub commit: String,
}

impl SourceTree {
    /// The directory of the Chromium checkout, which is the parent of the
    /// CEF directory.
    pub fn chromium_dir(&self) -> &Path {
        self.cef_dir.parent().unwrap_or(&self.root)
    }
}

/// Fetch the sources described by the plan.
///
/// The step is idempotent: a checkout that already carries the pinned commit
/// is left alone, so an interrupted build can be resumed.
pub fn fetch(plan: &Plan) -> Result<SourceTree> {
    let commit = &plan.manifest.source.commit;
    let cef_dir = plan.cef_dir();

    std::fs::create_dir_all(&plan.source_root)
        .with_context(|| format!("cannot create {}", plan.source_root.display()))?;
    // `gclient` reads the solution from the `.gclient` file of the directory
    // that holds it.  The Chromium tree is the solution, and the CEF layer
    // sits inside it at `src/cef` — the layout that CEF's own hook expects.
    write_gclient(&plan.source_root, plan)?;

    // Chromium is the tree that the engine is built in.  It is pinned by its
    // own commit, and it is checked out the same way as CEF.  It comes
    // first: the layer of CEF is cloned into it.
    checkout(
        &plan.chromium_dir(),
        &plan.manifest.chromium.repo,
        &plan.manifest.chromium.commit,
        "the Chromium checkout",
    )?;

    checkout(
        &cef_dir,
        &plan.manifest.source.repo,
        commit,
        "the CEF checkout",
    )?;

    apply_android_patch(&cef_dir)?;

    // The checkout of the sources fills the page cache of the machine with
    // the forty gigabytes of the pack of Chromium, and the machine of the
    // build has a ceiling of sixteen.  The pages are not needed again —
    // the tree is on the disk, and the kernel reads it back when it has to
    // — so they are given back.  The ceiling is what killed the checkout
    // of an earlier run: the process that was killed was not the one that
    // used the memory, but the one that happened to be the largest when
    // the ceiling was reached.
    release_page_cache(&plan.source_root);

    Ok(SourceTree {
        root: plan.source_root.clone(),
        cef_dir,
        commit: commit.clone(),
    })
}

/// Give the page cache of the machine back the pages of the tree.
///
/// The kernel has no way of doing that for a whole tree, and the service
/// has no right to write to `/proc/sys/vm/drop_caches`, which needs the
/// privilege of the superuser.  The file-by-file way is `posix_fadvise`
/// with `POSIX_FADV_DONTNEED`, and it needs no privilege at all.
fn release_page_cache(root: &Path) {
    use std::os::unix::io::AsRawFd;

    let mut files = 0u64;
    let mut bytes = 0u64;

    for entry in walkdir::WalkDir::new(root).follow_links(false) {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        if !entry.file_type().is_file() {
            continue;
        }
        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        if let Ok(file) = std::fs::File::open(entry.path()) {
            // The advice is a hint: a file that is open, or that the
            // kernel wants to keep, is not evicted.  That is fine, the
            // point is to give back what can be given back.
            unsafe {
                posix_fadvise(
                    file.as_raw_fd(),
                    0,
                    metadata.len() as i64,
                    POSIX_FADV_DONTNEED,
                );
            }
            files += 1;
            bytes += metadata.len();
        }
    }
    if files > 0 {
        log::info!(
            "the page cache of the tree was released: {files} files, {} MiB",
            bytes / (1024 * 1024)
        );
    }
}

/// The advice of `posix_fadvise` that gives the pages of a file back.
const POSIX_FADV_DONTNEED: i32 = 4;

extern "C" {
    /// Give the pages of a file back to the kernel.
    ///
    /// POSIX, and the only piece of the platform that this service needs
    /// and that the standard library does not have.
    fn posix_fadvise(fd: i32, offset: i64, len: i64, advice: i32) -> i32;
}

/// The patch that makes the tree of CEF accept the target of Android.
///
/// CEF has no Android target: its own `BUILD.gn` asserts three flags that
/// Chromium turns off for Android, and the build of the engine stops with
///
/// ```text
/// ERROR at //cef/BUILD.gn:255:1: Assertion failed.
/// assert(enable_print_preview)
/// ```
///
/// The flags cannot simply be turned on: Chromium's own `grit` asserts the
/// opposite, in the same build,
///
/// ```text
/// ERROR at //tools/grit/grit_args.gni:18:1: Assertion failed.
/// assert(toolkit_views == ...)
/// ```
///
/// so the two assertions cannot both hold for Android.  The patch lets the
/// desktop-only flags be off on Android, which is what Chromium expects and
/// what CEF's desktop targets need.
///
/// The patch is part of this service, it is applied to the tree of CEF after
/// the checkout, and it is a diff against the pinned commit: a CEF that
/// changes the lines it touches stops the build with a message that says
/// so, instead of being built with the wrong flags.
/// Apply the patch of the service to the tree of CEF.
///
/// The step is idempotent: a tree that already carries the patch is left
/// alone, so an interrupted build can be resumed.
fn apply_android_patch(cef_dir: &Path) -> Result<()> {
    patch::apply_patch(cef_dir, patch::CEF_ANDROID_PATCH, "CEF")?;

    // The result is read back, because a patch that git accepted and that
    // did not change the file is not a patch.
    patch::verify(
        cef_dir,
        "BUILD.gn",
        &[
            "assert(enable_print_preview || is_android)",
            "assert(enable_widevine || is_android)",
            "assert(toolkit_views || is_android)",
            "group(\"cef_android\")",
            "testonly = true",
        ],
    )?;
    Ok(())
}

/// Check a repository out at the commit that the manifest pins.
///
/// The checkout is made without the history and without the blobs, and it is
/// made at the commit itself: a branch could move, a commit cannot.  A
/// checkout that already carries the commit is left alone, so an interrupted
/// build can be resumed.
fn checkout(dir: &Path, repo: &str, commit: &str, what: &str) -> Result<()> {
    if dir.join(".git").exists() {
        let current = head_commit(dir)?;
        if current == commit {
            log::info!("{what} is already at {commit}");
            return Ok(());
        }
        log::info!("{what} is at {current}, fetching {commit}");
        git(dir, &["fetch", "--depth", "1", "origin", commit])?;
        git(dir, &["checkout", "--detach", commit])?;
    } else {
        log::info!("cloning {repo} at {commit}");
        // The repository is made empty and the commit is fetched into it.
        // A clone would fetch the branch as well, and the branch of Chromium
        // is an order of magnitude larger than the commit that is wanted.
        let parent = dir.parent().unwrap_or_else(|| Path::new("."));
        let name = dir
            .file_name()
            .unwrap_or_else(|| std::ffi::OsStr::new("checkout"));
        std::fs::create_dir_all(parent)
            .with_context(|| format!("cannot create {}", parent.display()))?;
        git(parent, &["init", "--quiet", &name.to_string_lossy()])?;
        git(dir, &["remote", "add", "origin", repo])?;
        git(dir, &["fetch", "--depth", "1", "origin", commit])?;
        git(dir, &["checkout", "--detach", "FETCH_HEAD"])?;
    }

    let current = head_commit(dir)?;
    if current != commit {
        bail!(
            "{what} is at {current} but the manifest pins {commit}; refusing to build something \
             that is not the pinned revision"
        );
    }
    Ok(())
}

/// Write the `.gclient` file of the solution.
///
/// The file names two solutions: the Chromium tree, and the CEF layer that
/// sits inside it at `src/cef`.  CEF's own `DEPS` file carries the hook
/// that patches Chromium and writes the files of the C API, and that hook
/// expects exactly this layout.
///
/// Neither solution is *managed* by `gclient`: the commits are pinned by
/// this service, and `gclient` is here for the dependencies that the `DEPS`
/// files name.  The form of the file is the one that CEF's own tooling
/// writes.
pub fn write_gclient(root: &Path, plan: &Plan) -> Result<()> {
    let path = root.join(".gclient");
    let chromium_repo = &plan.manifest.chromium.repo;
    let cef_repo = &plan.manifest.source.repo;
    // `target_os` is what turns the checkout into an Android checkout.  The
    // build of Chromium reads it, and without it the configuration of the
    // Android target stops with:
    //
    // The value is a list of strings and nothing else: a trailing comma
    // makes it a tuple *of* a list, and gclient hashes the elements of it:
    //
    //     TypeError: unhashable type: 'list'
    //
    //     ERROR at //build/config/android/config.gni:49:7: Assertion failed.
    //         assert(checkout_android,
    //     Missing native Android toolchain support.  |target_os| in your
    //     .gclient configuration file ... must include "android".
    let content = format!(
        "target_os = ['android']\n\nsolutions = [\n  {{\n    'managed': False,\n    'name': 'src',\n    'url': '{chromium_repo}',\n    \
         'custom_vars': {{\n      'checkout_pgo_profiles': False,\n      'source_tarball': False,\n      \
         'siso_version': 'latest',\n    }},\n    'custom_deps': {{}},\n    'deps_file': 'DEPS',\n    \
         'safesync_url': '',\n  }},\n  {{\n    'managed': False,\n    'name': 'src/cef',\n    \
         'url': '{cef_repo}',\n    'deps_file': 'DEPS',\n    'custom_deps': {{}},\n    \
         'custom_vars': {{}},\n  }},\n]\n"
    );
    std::fs::write(&path, content).with_context(|| format!("cannot write {}", path.display()))?;
    log::info!("the solution is written to {}", path.display());
    Ok(())
}

/// Run `gclient sync` for the checkout.
///
/// `gclient` reads the `DEPS` file of the CEF checkout and fetches Chromium
/// and every dependency at the revision that the file names.
pub fn sync(plan: &Plan, tree: &SourceTree) -> Result<()> {
    let gclient = plan.depot_tools.path.join("gclient");

    log::info!("running gclient sync in {}", tree.root.display());

    // The command runs in the directory that holds the `.gclient` file: that
    // is where the solution is described, and the Chromium sources land in
    // the solution directory, next to the `DEPS` file of CEF.
    // The flags are chosen for a container with a small memory ceiling:
    //
    //   * no `--reset`: the tree is already at the commit that the manifest
    //     pins, and a reset rewrites the index of a tree of twenty-nine
    //     gigabytes.  The measured cost of that rewrite was seventeen
    //     gigabytes of memory, and the container allows sixteen.
    //
    //   * no `--with_branch_heads`: the branches of Chromium move, and the
    //     build wants the commit, not the branch.
    //
    //   * `--shallow` and `--no-history`: the history of a tree that is
    //     pinned by a commit is not needed for anything.
    //
    //   * `--nohooks`: the hook of CEF configures and builds the *host*
    //     tree of Chromium, with the system libraries of a desktop Linux
    //     — cups among them.  The build of an engine for Android needs
    //     none of that, and the hook fails on a machine that does not
    //     carry the packages of a desktop.  The work of the hook — the
    //     patches and the headers of the C API — is done by this service,
    //     with the tools that CEF ships.
    let status = Command::new(&gclient)
        .current_dir(&tree.root)
        .args(["sync", "--no-history", "--shallow", "--force", "--nohooks"])
        .env("DEPOT_TOOLS_UPDATE", "0")
        .env("PATH", path_with_depot_tools(plan))
        .status()
        .with_context(|| format!("cannot run {}", gclient.display()))?;
    if !status.success() {
        bail!("gclient sync failed with {status}");
    }
    Ok(())
}

/// Fetch the headers of Chromium that the C API of CEF needs.
///
/// The public headers of CEF include a few headers of Chromium.  They are
/// fetched from the Chromium revision that CEF tracks — the branch head of the
/// Chromium release — and every one of them is checked against the checksum
/// that the manifest pins.  They are written into the bundle below its root,
/// so that the include path of the generator resolves both the headers of
/// CEF (`include/...`) and the headers of Chromium (`net/...`).
pub fn chromium_headers(bundle: &Path, manifest: &crate::manifest::Manifest) -> Result<()> {
    if manifest.chromium.revision.is_empty() || manifest.chromium.headers.is_empty() {
        return Ok(());
    }
    let base = manifest.chromium.base_url.trim_end_matches('/');
    for header in &manifest.chromium.headers {
        let url = format!("{base}/{}/{}", manifest.chromium.revision, header.path);
        log::info!("fetching {url}");
        let response = ureq::get(&url)
            .call()
            .with_context(|| format!("cannot fetch {url}"))?;
        let mut body = Vec::new();
        std::io::copy(&mut response.into_reader(), &mut body)
            .with_context(|| format!("cannot read {url}"))?;

        verify_header(&header.path, &header.sha256, &body)?;

        let target = bundle.join(&header.path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("cannot create {}", parent.display()))?;
        }
        std::fs::write(&target, &body)
            .with_context(|| format!("cannot write {}", target.display()))?;
        log::info!("{} is in {}", header.path, target.display());
    }
    Ok(())
}

/// Check a header against the checksum that the manifest pins.
///
/// The headers of Chromium end up in the bindings of the engine, and the
/// bindings end up in a binary that runs on the device of a user.  A header
/// that is not the one of the pinned revision is a silent mismatch, so the
/// checksum is verified before the header is used.
pub fn verify_header(path: &str, expected: &str, body: &[u8]) -> Result<()> {
    let digest = crate::sha256_bytes(body);
    if digest != expected {
        bail!("the header {path} has the checksum {digest}, the manifest pins {expected}");
    }
    Ok(())
}

/// The commit that a checkout carries.
pub fn head_commit(dir: &Path) -> Result<String> {
    let output = Command::new("git")
        .current_dir(dir)
        .args(["rev-parse", "HEAD"])
        .output()
        .with_context(|| format!("cannot ask git about {}", dir.display()))?;
    if !output.status.success() {
        bail!(
            "git rev-parse failed in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Run a git command in a directory.
///
/// The memory of `git` is bounded: the tree of Chromium has millions of
/// objects, and the pack that carries them does not fit in the memory of a
/// container.  `git` spills the pack to the disk instead of holding it.
fn git(dir: &Path, args: &[&str]) -> Result<()> {
    let output = Command::new("git")
        .current_dir(dir)
        // The options come first: they are the options of git itself, not of
        // the command that follows.
        .arg("-c")
        .arg("pack.threads=1")
        .arg("-c")
        .arg("pack.memoryLimit=2g")
        .arg("-c")
        .arg("core.deltaBaseCacheLimit=64m")
        .args(args)
        .output()
        .with_context(|| format!("cannot run git in {}", dir.display()))?;
    if !output.status.success() {
        bail!(
            "git {} failed in {}: {}",
            args.join(" "),
            dir.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

/// The PATH of the build, with depot_tools in front of it.
fn path_with_depot_tools(plan: &Plan) -> String {
    let depot = plan.depot_tools.path.display().to_string();
    match std::env::var("PATH") {
        Ok(current) if !current.is_empty() => format!("{depot}:{current}"),
        _ => depot,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;
    use crate::plan::Tool;

    #[test]
    fn the_page_cache_of_the_tree_is_released() {
        // The release of the page cache is what keeps the checkout of the
        // sources from filling the memory of the machine: the pack of
        // Chromium is forty gigabytes and the ceiling of the machine is
        // sixteen.
        let dir = tempfile::tempdir().expect("a temporary directory");
        let file = dir.path().join("a-file");
        std::fs::write(&file, vec![0u8; 4096]).expect("the file is written");
        let sub = dir.path().join("a-directory");
        std::fs::create_dir_all(&sub).expect("the directory is created");
        std::fs::write(sub.join("another-file"), vec![0u8; 4096]).expect("the file is written");

        // The function has no answer to give: it is a hint to the kernel,
        // and the kernel may keep what it wants.  What it must do is walk
        // the tree without failing on it.
        release_page_cache(dir.path());
    }

    #[test]
    fn the_head_commit_of_a_repository_is_read() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let ok = Command::new("git")
            .current_dir(dir.path())
            .args(["init", "--quiet", "--initial-branch=main"])
            .status()
            .expect("git runs");
        assert!(ok.success());
        std::fs::write(dir.path().join("a"), "x").expect("can write");
        let ok = Command::new("git")
            .current_dir(dir.path())
            .args(["add", "a"])
            .status()
            .expect("git runs");
        assert!(ok.success());
        let ok = Command::new("git")
            .current_dir(dir.path())
            .args([
                "-c",
                "user.email=cefpack@example.invalid",
                "-c",
                "user.name=cefpack",
                "commit",
                "--quiet",
                "-m",
                "x",
            ])
            .status()
            .expect("git runs");
        assert!(ok.success());
        let commit = head_commit(dir.path()).expect("the commit is read");
        assert_eq!(commit.len(), 40, "a commit is a full SHA");
    }

    #[test]
    fn a_header_with_the_wrong_checksum_is_refused() {
        let error = verify_header(
            "net/base/net_error_list.h",
            "0000000000000000000000000000000000000000000000000000000000000000",
            b"the header",
        )
        .expect_err("the checksum is wrong");
        assert!(error.to_string().contains("checksum"));
    }

    #[test]
    fn a_header_with_the_right_checksum_is_accepted() {
        verify_header(
            "net/base/net_error_list.h",
            &crate::sha256_bytes(b"the header"),
            b"the header",
        )
        .expect("the checksum is right");
    }

    #[test]
    fn the_head_commit_of_a_directory_without_a_repository_fails() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let error = head_commit(dir.path()).expect_err("there is no repository");
        assert!(error.to_string().contains("git rev-parse failed"));
    }

    #[test]
    fn the_patch_of_the_service_relaxes_the_assertions_of_cef_for_android() {
        // The patch is a diff against the pinned commit of CEF.  It has to
        // be a diff and not a description: a tree of CEF that changed the
        // lines it touches must stop the build, and `git apply --check`
        // is what says so.
        assert!(
            patch::CEF_ANDROID_PATCH.starts_with("diff --git"),
            "the patch is a diff"
        );
        for (assertion, relaxed) in [
            (
                "assert(enable_print_preview)",
                "assert(enable_print_preview || is_android)",
            ),
            (
                "assert(enable_widevine)",
                "assert(enable_widevine || is_android)",
            ),
            (
                "assert(toolkit_views)",
                "assert(toolkit_views || is_android)",
            ),
        ] {
            assert!(
                patch::CEF_ANDROID_PATCH.contains(&format!("-{assertion}")),
                "{assertion} is relaxed by the patch"
            );
            assert!(
                patch::CEF_ANDROID_PATCH.contains(&format!("+{relaxed}")),
                "{assertion} is relaxed for Android"
            );
        }
        // The patch also carries the root of the build: the engine and the
        // shim of the C API, and nothing else.
        assert!(
            patch::CEF_ANDROID_PATCH.contains("+group(\"cef_android\")"),
            "the patch carries the root of the build"
        );
        for target in [":libcef\"", ":libcef_dll_wrapper\""] {
            assert!(
                patch::CEF_ANDROID_PATCH.contains(target),
                "the root of the build carries {target}"
            );
        }
    }

    #[test]
    fn the_solution_names_chromium_and_the_cef_layer_inside_it() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let plan = plan_for_the_test();
        write_gclient(dir.path(), &plan).expect("the solution is written");
        let text = std::fs::read_to_string(dir.path().join(".gclient")).expect("can read");
        assert!(
            text.contains("'name': 'src'"),
            "the tree of Chromium is the solution"
        );
        assert!(
            text.contains("'name': 'src/cef'"),
            "the layer of CEF sits inside it, where the hook of CEF expects it"
        );
        assert!(
            text.contains("'deps_file': 'DEPS'"),
            "the solutions read the DEPS files"
        );
        assert!(
            text.contains("target_os = ['android']"),
            "the checkout is an Android checkout: without this the configuration of \
             the Android target stops with an assertion about the native Android \
             toolchain support"
        );
        assert!(
            text.contains("'managed': False"),
            "the repositories are not managed by gclient: this service pins them"
        );
        assert!(
            text.contains("https://github.com/chromiumembedded/cef.git"),
            "the solution names the repository of CEF"
        );
        assert!(
            text.contains("https://chromium.googlesource.com/chromium/src.git"),
            "the solution names the repository of Chromium"
        );
    }

    /// A plan that carries the repositories of the manifest, for the tests
    /// that write the solution.
    fn plan_for_the_test() -> Plan {
        let manifest = Manifest::read(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("manifest/cef-android.toml"),
        )
        .expect("the manifest of the crate is readable");
        Plan {
            manifest,
            source_root: PathBuf::from("cef-source"),
            out_dir: PathBuf::from("cef-out"),
            bundle_dir: PathBuf::from("cef-bundle"),
            ndk: Tool {
                name: "ndk",
                path: PathBuf::from("/nonexistent/ndk"),
                version: None,
            },
            sdk: Tool {
                name: "sdk",
                path: PathBuf::from("/nonexistent/sdk"),
                version: None,
            },
            depot_tools: Tool {
                name: "depot_tools",
                path: PathBuf::from("/nonexistent/depot_tools"),
                version: None,
            },
            git: Tool {
                name: "git",
                path: PathBuf::from("/usr/bin/git"),
                version: None,
            },
            problems: Vec::new(),
        }
    }
}
