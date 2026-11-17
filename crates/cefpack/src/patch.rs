//! The patches of the service, and the machinery that applies them.
//!
//! CEF is written for the desktop: three of its assertions in `BUILD.gn`
//! cannot hold on Android, and one of its own patches to Chromium cannot be
//! configured on Android at all.  The service carries the patches that fix
//! both, and applies them to the two trees they belong to:
//!
//! * `cef-android-gn-asserts.patch` goes to the tree of **CEF**;
//! * `chromium-android-base-test.patch` goes to the tree of **Chromium**.
//!
//! # Why the second patch is not the first one's business
//!
//! The patch of Chromium belongs to CEF: `cef/patch/patches/base_test_4396276.patch`
//! is in the list of `cef/patch/patch.cfg`, and CEF's own tool applies it.
//! It cannot be skipped for Android with the `condition` key of `patch.cfg`,
//! because that key only ever *adds* a patch, and because the patch is not
//! macOS-only in its effect: it changes the type of a target from
//! `shared_library` to `component`, and a `component` on Android is a
//! `static_library`, whose default configurations do not carry the config
//! that the target then tries to remove.
//!
//! So the patch stays, and the service corrects the one line that Android
//! cannot accept.  The correction is written against the pinned Chromium
//! commit, so a Chromium that changes the line stops the build with a
//! message that says so.
//!
//! # The order of the two patches
//!
//! CEF's patch rewrites `base/test/BUILD.gn` and the patch of the service
//! rewrites a line of the same file, so the two must not be applied at the
//! same time and in the wrong order.  The order is: **CEF's patcher first,
//! the patch of the service second.**  The reason is that the patch of the
//! service is written against the file as Chromium ships it, and CEF's
//! patcher changes the lines *around* the line that the service touches,
//! never the line itself.  Applying the service's patch first would work
//! too — the two hunks do not overlap — but the order above is the one
//! that is tested.

use std::{path::Path, process::Command};

use anyhow::{bail, Context, Result};

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
pub const CEF_ANDROID_PATCH: &str = include_str!("../patches/cef-android-gn-asserts.patch");

/// The patch that makes the tree of Chromium accept the target of Android.
///
/// CEF's own patch `base_test_4396276.patch` changes the target of the trace
/// processor in `base/test/BUILD.gn` from a `shared_library` to a
/// `component`.  On Android a `component` is a `static_library` — Chromium
/// asserts that Android is never a component build — and the default
/// configurations of a `static_library` do not carry
/// `//build/config/android:hide_all_but_jni_onload`, which only shared
/// libraries get.  The target then tries to remove a config that was never
/// there, and the configuration of the build stops with
///
/// ```text
/// ERROR at //base/test/BUILD.gn:742:18: Item not found
///     configs -= [ "//build/config/android:hide_all_but_jni_onload" ]
/// ```
///
/// The patch changes the condition of that removal so that it only happens
/// for the target type that actually carries the config.  A Chromium that
/// changes the line stops the build with a message that says so.
pub const CHROMIUM_ANDROID_PATCH: &str =
    include_str!("../patches/chromium-android-base-test.patch");

/// The patch that lets the framework of the views be built for Android.
///
/// Chromium builds the framework of the views — the user interface of the
/// desktop browser — only for the desktop platforms, and it ties the flag
/// to them with an assertion in its own build of the resources:
///
/// ```text
/// ERROR at //tools/grit/grit_args.gni:18:1: Assertion failed.
/// assert(toolkit_views ==
///        (is_chromeos || is_fuchsia || is_linux || is_mac || is_win))
/// ```
///
/// The flag `toolkit_views` is the switch that says "the user interface is
/// built with the views", and CEF's browser — the Alloy browser — is built
/// with the views and cannot exist without them.  The assertion of the
/// `grit` tool is about the **resources** of the desktop, not about the
/// framework itself, and it is the only place in Chromium where the two
/// are tied together.
///
/// The patch lets the flag be on for Android as well.  It is written
/// against the file as CEF's own patcher leaves it, because the service
/// applies its patches to Chromium **after** CEF's patcher has run.
pub const CHROMIUM_TOOLKIT_VIEWS_PATCH: &str =
    include_str!("../patches/chromium-android-toolkit-views.patch");

/// The patch that bounds the workers of the linker by the memory of the
/// machine.
///
/// Chromium computes the number of workers that read the input of a link
/// as a quarter of the number of the cores, and a machine of ninety-six
/// cores asks for twenty-four of them.  Every worker holds the part of the
/// input that it reads in memory, and the input of a link of Blink is
/// measured in gigabytes: a container of sixteen gigabytes cannot give
/// twenty-four workers the input of the link.
///
/// The patch is made against the file of the pinned revision, and the
/// service reads the file back after it has applied it.
pub const CHROMIUM_LLD_WORKERS_PATCH: &str =
    include_str!("../patches/chromium-android-lld-workers.patch");

/// Apply a patch to a tree of sources.
///
/// The step is idempotent: a tree that already carries the patch is left
/// alone, so an interrupted build can be resumed.
///
/// The patch is applied in exactly three states, and only three:
///
///   * the patch is already there — the tree is resumable, and a tree that
///     was patched keeps the patch;
///   * the patch fits — it is applied;
///   * the patch does not fit — the tree is not the one this service knows,
///     and the build says so.
///
/// The middle state used to be decided by the text of the error of git,
/// which said "patch does not apply" for a tree that did *not* carry the
/// patch.  The build then went on without the group that the patch adds,
/// and the configuration of the build stopped with
///
/// ```text
/// ERROR Root source path not found.
/// The path "//cef:cef_android" doesn't exist.
/// ```
///
/// `name` is the name of the patch, for the messages.
pub fn apply_patch(tree: &Path, patch: &str, name: &str) -> Result<()> {
    // The tree and the file are made absolute before they are used: the
    // command runs *in* the tree and names the patch with a path, and a
    // relative path is resolved against the directory the command runs in
    // — so a relative tree makes the patch be looked for twice.
    let tree = absolute(tree);
    let file = tree.join(format!(".cefpack-{name}.patch"));
    std::fs::write(&file, patch).with_context(|| format!("cannot write {}", file.display()))?;

    let git = |args: &[&str]| {
        Command::new("git")
            .current_dir(&tree)
            .args(args)
            .arg(&file)
            .output()
            .with_context(|| format!("cannot run git in {}", tree.display()))
    };

    let reverse = git(&["apply", "--reverse", "--check"])?;
    if reverse.status.success() {
        log::info!("{tree:?} already carries the patch of {name}");
    } else {
        let check = git(&["apply", "--check"])?;
        if !check.status.success() {
            let detail = String::from_utf8_lossy(&check.stderr).trim().to_string();
            bail!("the patch of {name} does not fit {tree:?}: {detail}");
        }
        let applied = git(&["apply"])?;
        if !applied.status.success() {
            let detail = String::from_utf8_lossy(&applied.stderr).trim().to_string();
            bail!("the patch of {name} could not be applied: {detail}");
        }
        log::info!("the patch of {name} is applied to {tree:?}");
    }
    let _ = std::fs::remove_file(&file);
    Ok(())
}

/// A path, made absolute against the working directory.
fn absolute(path: &Path) -> std::path::PathBuf {
    if path.is_absolute() {
        return path.to_path_buf();
    }
    match std::env::current_dir() {
        Ok(directory) => directory.join(path),
        Err(_) => path.to_path_buf(),
    }
}

/// Read a file of a tree and check that it carries what a patch put in it.
///
/// A patch that git accepted and that did not change the file is not a
/// patch, so the result is read back.
pub fn verify(tree: &Path, file: &str, expected: &[&str]) -> Result<()> {
    let path = tree.join(file);
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("cannot read {}", path.display()))?;
    for want in expected {
        if !text.contains(want) {
            bail!(
                "{} does not carry the patch of the service: {want} is not in it",
                path.display()
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::process::Command;

    /// A repository with one file in it.
    fn repository() -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let run = |args: &[&str]| {
            let status = Command::new("git")
                .current_dir(dir.path())
                .args(args)
                .status()
                .expect("git runs");
            assert!(status.success(), "git {args:?} failed");
        };
        run(&["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(dir.path().join("file"), "before\n").expect("can write");
        run(&["add", "file"]);
        run(&[
            "-c",
            "user.email=cefpack@example.invalid",
            "-c",
            "user.name=cefpack",
            "commit",
            "--quiet",
            "-m",
            "x",
        ]);
        dir
    }

    #[test]
    fn a_patch_that_fits_is_applied() {
        let dir = repository();
        let patch =
            "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n";
        apply_patch(dir.path(), patch, "test").expect("the patch fits");
        let text = std::fs::read_to_string(dir.path().join("file")).expect("can read");
        assert_eq!(text, "after\n");
    }

    #[test]
    fn a_patch_that_is_already_there_is_not_applied_twice() {
        let dir = repository();
        let patch =
            "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n";
        apply_patch(dir.path(), patch, "test").expect("the patch fits");
        // The second run must not fail, and it must not change the file.
        apply_patch(dir.path(), patch, "test").expect("the patch is already there");
        let text = std::fs::read_to_string(dir.path().join("file")).expect("can read");
        assert_eq!(text, "after\n");
    }

    #[test]
    fn a_patch_that_does_not_fit_is_refused() {
        let dir = repository();
        // The file says "before", and the patch expects "something else".
        let patch = "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-something else\n+after\n";
        let error = apply_patch(dir.path(), patch, "test").expect_err("the patch does not fit");
        assert!(
            error.to_string().contains("does not fit"),
            "the error says what happened: {error}"
        );
    }

    #[test]
    fn a_patch_is_applied_to_a_tree_named_relatively() {
        // The command runs *in* the tree and names the patch with a path.
        // A relative tree would make the patch be looked for twice — in
        // `tree/tree/` — and the build would stop with a message about a
        // file that nobody has ever heard of.
        let repository = repository();
        let previous = std::env::current_dir().expect("the working directory");
        std::env::set_current_dir(repository.path().parent().expect("a parent"))
            .expect("the working directory is set");
        let tree = PathBuf::from(repository.path().file_name().expect("a name"));
        let result = std::panic::catch_unwind(|| {
            let patch =
                "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n";
            apply_patch(&tree, patch, "test")
        });
        std::env::set_current_dir(previous).expect("the working directory is restored");
        let outcome = result.expect("the patch does not panic");
        outcome.expect("the patch fits a tree that is named relatively");
        let text = std::fs::read_to_string(repository.path().join("file")).expect("can read");
        assert_eq!(text, "after\n");
    }

    #[test]
    fn the_patch_of_cef_makes_the_group_test_only() {
        // `libcef` is test-only in CEF, and a group that depends on a
        // test-only target must be test-only itself:
        //
        //     ERROR at //cef/BUILD.gn:1:1: Test-only dependency not allowed.
        //
        assert!(CEF_ANDROID_PATCH.contains("group(\"cef_android\") {"));
        let group = CEF_ANDROID_PATCH
            .split("group(\"cef_android\") {")
            .nth(1)
            .expect("the group is in the patch");
        assert!(
            group.contains("testonly = true"),
            "the group is test-only: {group}"
        );
    }

    #[test]
    fn the_patch_of_chromium_guards_the_removal_of_the_config() {
        // The removal of the config only works for a target that carries
        // it, and only a shared library carries it on Android.
        assert!(
            CHROMIUM_ANDROID_PATCH
                .contains("if (is_android && _target_type == \"shared_library\") {"),
            "the removal is guarded: {CHROMIUM_ANDROID_PATCH}"
        );
    }

    #[test]
    fn the_patch_of_chromium_is_written_against_the_pinned_commit() {
        // The blob of the file that the patch changes, before the patch.
        assert!(
            CHROMIUM_ANDROID_PATCH.contains("afddfd4a555750837875292fee037329f4b0e585"),
            "the patch names the tree it was made against: {CHROMIUM_ANDROID_PATCH}"
        );
    }

    /// The number of lines a hunk of a patch says it has.
    ///
    /// A hunk header says how many lines the hunk has *before* the patch and
    /// how many it has *after* it, and the body of the hunk is read exactly
    /// that many lines long.  A header that says fewer lines than the body
    /// has is not an error: git reads the header, takes the lines it names,
    /// and **silently leaves the rest of the body out**.
    ///
    /// That is how the group that is the root of the build was lost: the
    /// header said `+3065,12`, the body had sixteen added lines, and the
    /// group — the last seven of them — was never applied.  The tree of CEF
    /// then had the assertions relaxed and no group, and the configuration
    /// of the build stopped with
    ///
    /// ```text
    /// ERROR Root source path not found.
    /// The path "//cef:cef_android" doesn't exist.
    /// ```
    ///
    /// which says nothing about a patch with a wrong header.
    fn hunk_lengths(patch: &str) -> Vec<(usize, usize, usize, usize)> {
        let mut lengths = Vec::new();
        let mut lines = patch.lines().peekable();
        while let Some(line) = lines.next() {
            let Some(header) = line.strip_prefix("@@ -") else {
                continue;
            };
            let mut parts = header.split_whitespace();
            let old = parts.next().unwrap_or_default();
            let new = parts.next().unwrap_or_default();
            let old_count = old
                .split(',')
                .nth(1)
                .and_then(|n| n.parse::<usize>().ok())
                .unwrap_or(1);
            let new_count = new
                .split(',')
                .nth(1)
                .and_then(|n| n.parse::<usize>().ok())
                .unwrap_or(1);

            let mut old_seen = 0;
            let mut new_seen = 0;
            while old_seen < old_count || new_seen < new_count {
                let Some(body) = lines.next() else {
                    break;
                };
                if body.starts_with('-') {
                    old_seen += 1;
                } else if body.starts_with('+') {
                    new_seen += 1;
                } else if body.starts_with(' ') || body.is_empty() {
                    old_seen += 1;
                    new_seen += 1;
                } else {
                    break;
                }
            }
            lengths.push((old_count, new_count, old_seen, new_seen));
        }
        lengths
    }

    #[test]
    fn the_patch_of_chromium_lets_the_views_be_built_for_android() {
        // The browser of CEF is built with the framework of the views, and
        // Chromium builds that framework for the desktop platforms only.
        // The one place where Chromium ties the flag to the desktop is the
        // build of the resources, and that is what the patch of the service
        // relaxes.
        assert!(
            CHROMIUM_TOOLKIT_VIEWS_PATCH.contains("assert(toolkit_views == (is_android) ||"),
            "the flag is not tied to the desktop any more: {CHROMIUM_TOOLKIT_VIEWS_PATCH}"
        );
    }

    #[test]
    fn the_hunks_of_the_patches_say_how_long_they_are() {
        for (name, patch) in [
            ("CEF", CEF_ANDROID_PATCH),
            ("Chromium", CHROMIUM_ANDROID_PATCH),
            ("the views", CHROMIUM_TOOLKIT_VIEWS_PATCH),
            ("the workers of the linker", CHROMIUM_LLD_WORKERS_PATCH),
        ] {
            let hunks = hunk_lengths(patch);
            assert!(!hunks.is_empty(), "the patch of {name} has hunks");
            for (old, new, old_seen, new_seen) in hunks {
                assert_eq!(
                    (old, new),
                    (old_seen, new_seen),
                    "a hunk of the patch of {name} says {old}/{new} lines and has {old_seen}/{new_seen}: \
                     git would leave the rest of the hunk out"
                );
            }
        }
    }

    #[test]
    fn the_patch_of_cef_carries_the_whole_of_the_group() {
        // The group is the last thing in the patch, and the lines that
        // follow the header of its hunk are the ones that a wrong header
        // would leave out.
        let group = CEF_ANDROID_PATCH
            .split("+group(\"cef_android\") {")
            .nth(1)
            .expect("the group is in the patch");
        for line in [
            "+  testonly = true",
            "+  deps = [",
            "+    \":libcef\",",
            "+    \":libcef_dll_wrapper\",",
            "+  ]",
            "+}",
        ] {
            assert!(
                group.contains(line),
                "the group is complete: {line} is missing"
            );
        }
    }
}
