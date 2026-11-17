//! The patches of the service are applied to a tree, and the tree is read
//! back afterwards.
//!
//! The test applies the patch of the service to the tree of CEF as it is at
//! the pinned commit, and checks that the result is what the build needs:
//! the assertions relaxed for Android, and the group that is the root of the
//! build.
//!
//! The fixtures are the files that the patches are diffs against, at the
//! commits that the manifest pins.  They are here because a test that does
//! not apply the patch to the file it was made against does not say
//! anything about the patch.
//!
//! The third test is the one that matters most: it applies the patch of the
//! service **twice**, and checks that the second application changes
//! nothing.  A patch with a hunk header that does not match its body is
//! applied by git *silently and partially*: git reads the number of lines
//! that the header names and leaves the rest of the hunk out.  The group
//! that is the root of the build was lost that way, and the tree of CEF then
//! had the assertions relaxed and no group at all.

use std::{path::Path, process::Command};

use cefpack::patch::{apply_patch, verify, CEF_ANDROID_PATCH, CHROMIUM_ANDROID_PATCH};

/// The `BUILD.gn` of CEF at the pinned commit.
const CEF_BUILD_GN: &str = include_str!("fixtures/cef-BUILD.gn");

/// The `base/test/BUILD.gn` of Chromium at the pinned commit.
const CHROMIUM_BASE_TEST_BUILD_GN: &str = include_str!("fixtures/chromium-base-test-BUILD.gn");

/// Make a repository with one file in it.
fn repository(directory: &Path, name: &str, content: &str) {
    let run = |args: &[&str]| {
        let status = Command::new("git")
            .current_dir(directory)
            .args(args)
            .status()
            .expect("git runs");
        assert!(status.success(), "git {args:?} failed");
    };
    if let Some(parent) = Path::new(name).parent() {
        std::fs::create_dir_all(directory.join(parent)).expect("can create");
    }
    run(&["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(directory.join(name), content).expect("can write");
    run(&["add", name]);
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
}

#[test]
fn the_patch_of_cef_is_applied_to_the_tree_of_cef() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    repository(dir.path(), "BUILD.gn", CEF_BUILD_GN);

    apply_patch(dir.path(), CEF_ANDROID_PATCH, "CEF").expect("the patch fits");

    let result = std::fs::read_to_string(dir.path().join("BUILD.gn")).expect("can read");

    // The three assertions of CEF are relaxed for Android.
    for relaxed in [
        "assert(enable_print_preview || is_android)",
        "assert(enable_widevine || is_android)",
        "assert(toolkit_views || is_android)",
    ] {
        assert!(result.contains(relaxed), "{relaxed} is in the result");
    }

    // The group that is the root of the build is in the result, and it is
    // **complete**.  A patch with a wrong hunk header leaves the last lines
    // of a hunk out, and the group was lost that way: the tree of CEF had
    // the assertions relaxed and no group at all, and the configuration of
    // the build stopped with a message about a path that does not exist.
    assert!(
        result.contains("group(\"cef_android\") {"),
        "the root of the build is in the result"
    );
    let group = result
        .split("group(\"cef_android\") {")
        .nth(1)
        .expect("the group is in the result");
    for line in [
        "testonly = true",
        "deps = [",
        "\":libcef\",",
        "\":libcef_dll_wrapper\",",
        "]",
    ] {
        assert!(group.contains(line), "the group carries {line}");
    }

    // The group is at the end of the file, and the file still ends with it.
    assert!(
        result.trim_end().ends_with("}"),
        "the file ends with the group"
    );
    assert_eq!(
        result.matches("group(\"cef_android\")").count(),
        1,
        "the group is there once"
    );
}

#[test]
fn the_patch_of_cef_is_applied_only_once() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    repository(dir.path(), "BUILD.gn", CEF_BUILD_GN);

    apply_patch(dir.path(), CEF_ANDROID_PATCH, "CEF").expect("the patch fits");
    let first = std::fs::read_to_string(dir.path().join("BUILD.gn")).expect("can read");

    // The second application must not fail, and it must not change the
    // file: a build that is resumed must not apply the patch twice.
    apply_patch(dir.path(), CEF_ANDROID_PATCH, "CEF").expect("the patch is already there");
    let second = std::fs::read_to_string(dir.path().join("BUILD.gn")).expect("can read");

    assert_eq!(first, second, "the second application changes nothing");
    assert_eq!(
        second.matches("group(\"cef_android\")").count(),
        1,
        "the group is there once"
    );
}

#[test]
fn the_patch_of_chromium_is_applied_to_the_tree_of_chromium() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    repository(
        dir.path(),
        "base/test/BUILD.gn",
        CHROMIUM_BASE_TEST_BUILD_GN,
    );

    apply_patch(dir.path(), CHROMIUM_ANDROID_PATCH, "Chromium").expect("the patch fits");

    let result = std::fs::read_to_string(dir.path().join("base/test/BUILD.gn")).expect("can read");

    // The removal of the config only happens for the target type that
    // carries it.
    assert!(
        result.contains("if (is_android && _target_type == \"shared_library\") {"),
        "the removal is guarded: {result}"
    );
    // The other removal, in the target that really is a shared library, is
    // untouched.
    assert!(
        result.contains("  if (is_android) {\n    configs -= [ \"//build/config/android:hide_all_but_jni_onload\" ]"),
        "the removal of the shared library is untouched"
    );
}

#[test]
fn the_patches_are_verified_against_the_tree_they_change() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    repository(dir.path(), "BUILD.gn", CEF_BUILD_GN);
    apply_patch(dir.path(), CEF_ANDROID_PATCH, "CEF").expect("the patch fits");

    // The read-back is what catches a patch that git accepted and that did
    // not change the file.
    verify(
        dir.path(),
        "BUILD.gn",
        &[
            "assert(enable_print_preview || is_android)",
            "group(\"cef_android\")",
        ],
    )
    .expect("the tree carries the patch");

    let error = verify(dir.path(), "BUILD.gn", &["group(\"cef_nothing\")"])
        .expect_err("the tree does not carry that");
    assert!(
        error.to_string().contains("does not carry"),
        "the error says what happened: {error}"
    );
}
