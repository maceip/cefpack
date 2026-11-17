//! The command line of the bundling service.
//!
//! ```text
//! cefpack plan                     resolve the plan and check the host
//! cefpack fetch                    check out the pinned CEF sources
//! cefpack headers [CEF_DIR] [BUNDLE]  generate the C API headers and assemble them
//! cefpack build                    configure and compile CEF for Android
//! cefpack audit [BUNDLE]           check a bundle
//! cefpack bindgen [BUNDLE]         generate the Rust FFI of the bundled version
//! cefpack pack [BUNDLE] [STAGING]  stage the bundle for a Gradle build
//! cefpack apk <APK>                check a built APK
//! cefpack manifest                 print the pinned manifest
//! ```
//!
//! Every path comes from the environment or from an argument.  The service
//! knows nothing about the machine it runs on.

use std::{path::PathBuf, process::ExitCode};

use anyhow::{bail, Context, Result};
use cefpack::{abi, apk, audit, bindgen, build, fetch, manifest::Manifest, plan::Plan};

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cefpack: {error:#}");
            ExitCode::FAILURE
        }
    }
}

/// Run the service.
fn run(arguments: &[String]) -> Result<()> {
    let command = arguments.first().map(String::as_str).unwrap_or("help");
    let rest = Arguments::read(&arguments[arguments.len().min(1)..])?;

    match command {
        "plan" => command_plan(),
        "fetch" => command_fetch(),
        "build" => command_build(),
        "headers" => {
            let cef_dir = rest
                .positional(0)
                .map(PathBuf::from)
                .unwrap_or_else(default_source_dir);
            let bundle = rest
                .positional(1)
                .map(PathBuf::from)
                .unwrap_or_else(default_bundle);
            let plan_args = manifest()?.gn_args(false);
            let root = build::headers(&cef_dir, &bundle, &plan_args)?;
            println!("the headers are in {}", root.display());
            Ok(())
        }
        "audit" => {
            let bundle = rest
                .positional(0)
                .map(PathBuf::from)
                .unwrap_or_else(default_bundle);
            command_audit(&bundle)
        }
        "abi" => {
            let cef_dir = rest
                .positional(0)
                .map(PathBuf::from)
                .unwrap_or_else(default_source_dir);
            command_abi(&cef_dir)
        }
        "bindgen" => {
            let bundle = rest
                .positional(0)
                .map(PathBuf::from)
                .unwrap_or_else(default_bundle);
            command_bindgen(&bundle, &rest)
        }
        "pack" => {
            let bundle = rest
                .positional(0)
                .map(PathBuf::from)
                .unwrap_or_else(default_bundle);
            let staging = rest
                .positional(1)
                .map(PathBuf::from)
                .unwrap_or_else(default_staging);
            command_pack(&bundle, &staging)
        }
        "apk" => {
            let apk_path = rest
                .positional(0)
                .map(PathBuf::from)
                .context("the APK to audit is missing")?;
            let app_lib = rest
                .option("--app-lib")
                .unwrap_or_else(|| "libonion_vault.so".to_string());
            command_apk(&apk_path, &app_lib)
        }
        "manifest" => command_manifest(),
        "help" | "--help" | "-h" => {
            print_help();
            Ok(())
        }
        other => {
            print_help();
            bail!("unknown command {other:?}");
        }
    }
}

/// The arguments of a command: the paths and the options.
///
/// The options are `--name value` or `--name=value`.  A path is an argument
/// that is not an option, so that the order of the options does not matter
/// and an option is never mistaken for a path.
#[derive(Debug)]
struct Arguments {
    positionals: Vec<String>,
    options: Vec<(String, String)>,
}

impl Arguments {
    /// Read the arguments of a command.
    fn read(arguments: &[String]) -> Result<Self> {
        let mut positionals = Vec::new();
        let mut options = Vec::new();
        let mut index = 0;
        while index < arguments.len() {
            let argument = &arguments[index];
            if let Some(name) = argument.strip_prefix("--") {
                if let Some((name, value)) = name.split_once('=') {
                    options.push((format!("--{name}"), value.to_string()));
                } else {
                    let value = arguments
                        .get(index + 1)
                        .with_context(|| format!("the option --{name} needs a value"))?;
                    options.push((format!("--{name}"), value.clone()));
                    index += 1;
                }
            } else {
                positionals.push(argument.clone());
            }
            index += 1;
        }
        Ok(Self {
            positionals,
            options,
        })
    }

    /// The path at an index.
    fn positional(&self, index: usize) -> Option<String> {
        self.positionals.get(index).cloned()
    }

    /// The value of an option.
    fn option(&self, name: &str) -> Option<String> {
        self.options
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.clone())
    }
}

/// The directory of the checked out sources.
fn default_source_dir() -> PathBuf {
    std::env::var("CEF_SOURCE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::var("CEF_SOURCE_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("cef-source"))
                .join("cef")
        })
}

/// The directory of the bundle.
fn default_bundle() -> PathBuf {
    std::env::var("CEF_BUNDLE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("cef-bundle"))
}

/// The directory of the staging tree.
fn default_staging() -> PathBuf {
    std::env::var("CEF_STAGING_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("cef-staging"))
}

/// The wrapper header that the generator reads.
fn default_wrapper() -> PathBuf {
    std::env::var("CEF_PACK_WRAPPER")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("include/wrapper.h"))
}

/// The pinned manifest.
fn manifest() -> Result<Manifest> {
    Manifest::read(&cefpack::manifest_path())
}

/// Resolve the plan and check the host.
fn command_plan() -> Result<()> {
    let manifest = manifest()?;
    println!("CEF      {}", manifest.engine.cef_version);
    println!("Chromium {}", manifest.engine.chromium_version);
    println!("commit   {}", manifest.source.commit);
    println!(
        "target   android/{}/api{}",
        manifest.target.abi, manifest.target.min_sdk
    );
    println!("NDK      {}", manifest.toolchain.ndk_version);

    match Plan::resolve(manifest) {
        Ok(plan) => {
            if !plan.problems.is_empty() {
                println!();
                println!("the host is not ready:");
                for problem in &plan.problems {
                    println!("  - {problem}");
                }
            }
            println!();
            println!("NDK      {}", plan.ndk.path.display());
            println!("SDK      {}", plan.sdk.path.display());
            println!("depot    {}", plan.depot_tools.path.display());
            println!("sources  {}", plan.source_root.display());
            println!("output   {}", plan.out_dir.display());
            println!("bundle   {}", plan.bundle_dir.display());
            println!();
            println!("the host has everything the build needs");
            Ok(())
        }
        Err(error) => {
            println!();
            println!("the host is not ready: {error:#}");
            Ok(())
        }
    }
}

/// Check out the pinned CEF sources.
fn command_fetch() -> Result<()> {
    let plan = Plan::resolve(manifest()?)?;
    // The checkout of the sources writes tens of gigabytes through the
    // memory of the machine, and the container of the build has a ceiling
    // of sixteen gigabytes.  The pages are given back while the checkout
    // runs, so that the checkout does not reach the ceiling.
    fetch::with_a_small_page_cache(&plan.source_root, || {
        let tree = fetch::fetch(&plan)?;
        println!("the sources are at {}", tree.cef_dir.display());
        fetch::sync(&plan, &tree)?;
        println!("the dependencies are in sync");
        Ok::<(), anyhow::Error>(())
    })
}

/// Configure and compile CEF for Android.
fn command_build() -> Result<()> {
    let debug = std::env::var("CEF_DEBUG").is_ok();
    let plan = Plan::resolve(manifest()?)?;
    let output = build::build(&plan, debug)?;
    println!("the bundle is in {}", output.bundle.display());
    Ok(())
}

/// Audit the C ABI of a checkout against the symbols a consumer links against.
fn command_abi(cef_dir: &std::path::Path) -> Result<()> {
    let abi = abi::Abi::read(cef_dir)?;
    let required = abi::required_symbols();
    let audit = abi.audit(&required);

    println!("the C API of {}", cef_dir.display());
    for tier in abi::Tier::all() {
        let declared = audit.by_tier.get(&tier).copied().unwrap_or(0);
        let needed = audit.required_by_tier.get(&tier).copied().unwrap_or(0);
        println!(
            "  {:9} {declared:4} declared, {needed:4} of them needed by the consumer",
            tier.name()
        );
    }
    println!();
    println!(
        "the consumer needs {} symbols; the engine declares {}",
        audit.required, audit.exported
    );

    if audit.missing.is_empty() {
        println!("every symbol of the consumer is declared by the engine");
    } else {
        println!(
            "{} symbols of the consumer are declared nowhere in the headers:",
            audit.missing.len()
        );
        for name in &audit.missing {
            println!("  {name}");
        }
    }
    println!();
    println!(
        "{} symbols are declared by the engine and not needed by the consumer;",
        audit.unused.len()
    );
    println!("they are the handlers of the desktop, and the shim stubs them.");

    // The prototypes of the symbols that the consumer needs.  This is the
    // contract that the shim of the service implements, and it is written
    // out so that the shim and the consumer cannot drift apart without a
    // diff that says so.
    println!();
    println!("the prototypes of the symbols that the consumer needs");
    for tier in abi::Tier::all() {
        let prototypes: Vec<&abi::Prototype> = abi
            .functions
            .iter()
            .filter(|prototype| prototype.tier == tier && required.contains(&prototype.name))
            .collect();
        if prototypes.is_empty() {
            continue;
        }
        println!();
        println!("--- {} ({} symbols) ---", tier.name(), prototypes.len());
        for prototype in prototypes {
            println!("{}", prototype.as_c());
        }
    }
    Ok(())
}

/// Check a bundle.
fn command_audit(bundle: &std::path::Path) -> Result<()> {
    let report = audit::audit(bundle)?;
    print!("{}", report.render());
    if !report.is_ok() {
        bail!("the bundle at {} is not sound", bundle.display());
    }
    Ok(())
}

/// Generate the Rust FFI of the bundled version.
///
/// The bindings are written into the bundle, so that the bundle carries the
/// engine, its headers and the FFI of that engine — one thing to fetch, one
/// thing to verify.
fn command_bindgen(bundle: &std::path::Path, arguments: &Arguments) -> Result<()> {
    let manifest = manifest()?;

    // The public headers of CEF include a few headers of Chromium.  They are
    // fetched from the pinned revision and verified, so that the bindings
    // are generated against the headers of the engine that is shipped.
    fetch::chromium_headers(bundle, &manifest)?;

    // The identifiers of the colours and of the commands are derived from
    // the headers of Chromium, which have just been fetched.
    let cef_source = default_source_dir();
    if cef_source.join("tools/make_colorids_header.py").is_file() {
        let generated = build::generate_id_headers(&cef_source, bundle)?;
        println!("the generated headers: {}", generated.join(", "));
    }

    let wrapper = arguments
        .option("--wrapper")
        .map(PathBuf::from)
        .unwrap_or_else(default_wrapper);
    let output = arguments
        .option("--out")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            bundle
                .join("bindings")
                .join(bindgen::bindings_file(bindgen::ANDROID_TARGET))
        });
    let ndk = std::env::var("ANDROID_NDK_HOME")
        .or_else(|_| std::env::var("ANDROID_NDK_ROOT"))
        .or_else(|_| std::env::var("CEF_ANDROID_NDK"))
        .unwrap_or_else(|_| "/opt/android-ndk-r27c".to_string());
    let args = bindgen::android_clang_args(std::path::Path::new(&ndk), manifest.target.min_sdk);

    match bindgen::generate(bundle, &wrapper, bindgen::ANDROID_TARGET, &output, &args) {
        Ok(()) => {
            println!("the bindings are in {}", output.display());
            Ok(())
        }
        Err(error) => {
            // The generator needs the headers of Chromium, which are the
            // generated ones of a build.  When they are not at hand, the
            // bindings of another target of the same API version are
            // correct — the version is checked, so a mismatch is refused.
            let fallback = match arguments.option("--from") {
                Some(path) => PathBuf::from(path),
                None => {
                    eprintln!(
                        "cefpack: {error:#}\n\
                         cefpack: pass --from <bindings.rs> to use the bindings of another \
                         target of the same API version"
                    );
                    return Err(error);
                }
            };
            println!("the generator could not run: {error:#}");
            match bindgen::fallback(bundle, &fallback, &output) {
                Ok(note) => {
                    println!("{note} were used instead: {}", output.display());
                    Ok(())
                }
                Err(fallback_error) => {
                    eprintln!("cefpack: {fallback_error:#}");
                    Err(error)
                }
            }
        }
    }
}

/// Stage a bundle for a Gradle build.
fn command_pack(bundle: &std::path::Path, staging: &std::path::Path) -> Result<()> {
    let manifest = manifest()?;
    let staged = apk::pack(bundle, staging, &manifest.target.abi)?;
    println!("the bundle is staged in {}", staged.root().display());
    Ok(())
}

/// Check a built APK.
fn command_apk(apk_path: &std::path::Path, app_lib: &str) -> Result<()> {
    let manifest = manifest()?;
    let report = apk::audit_apk(apk_path, &manifest.target.abi, app_lib)?;
    print!("{}", report.render());
    if !report.is_ok() {
        bail!("the APK {} is not sound", apk_path.display());
    }
    Ok(())
}

/// Print the pinned manifest.
fn command_manifest() -> Result<()> {
    let manifest = manifest()?;
    print!("{}", manifest.to_toml()?);
    Ok(())
}

/// Print the help.
fn print_help() {
    println!(
        r#"cefpack — the CEF bundling service for Android

  cefpack plan                       resolve the plan and check the host
  cefpack fetch                      check out the pinned CEF sources
  cefpack headers [CEF_DIR] [BUNDLE] generate the C API headers and assemble them
  cefpack build                      configure and compile CEF for Android
  cefpack audit [BUNDLE]             check a bundle
  cefpack bindgen [BUNDLE]           generate the Rust FFI of the bundled version
  cefpack pack [BUNDLE] [STAGING]    stage the bundle for a Gradle build
  cefpack apk <APK>                  check a built APK
  cefpack manifest                   print the pinned manifest

Options
  bindgen --out <FILE>               where the bindings are written
  bindgen --from <FILE>              bindings of another target of the same API
                                     version, used when the generator cannot run
  bindgen --wrapper <FILE>           the header that the generator reads
  apk --app-lib <NAME>               the native library of the application

Environment
  CEF_SOURCE_ROOT   the checkout of the sources        (./cef-source)
  CEF_SOURCE_DIR    the CEF directory of the checkout   ($CEF_SOURCE_ROOT/cef)
  CEF_OUT_DIR       the output of the build             (./cef-out)
  CEF_BUNDLE_DIR    the bundle                         (./cef-bundle)
  CEF_STAGING_DIR   the staging tree                   (./cef-staging)
  CEF_ANDROID_NDK   the NDK that builds the engine      (/opt/android-ndk-r27c)
  ANDROID_SDK_ROOT  the SDK of the platform             (/opt/android-sdk)
  CEF_DEPOT_TOOLS   the checkout of depot_tools
  CEF_DEBUG         build a debug engine
"#
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_command_is_refused() {
        let error = run(&["frobnicate".to_string()]).expect_err("the command does not exist");
        assert!(error.to_string().contains("unknown command"));
    }

    #[test]
    fn the_help_is_printed_without_a_command() {
        run(&[]).expect("the help is printed");
    }

    #[test]
    fn a_path_is_read_by_its_index() {
        let arguments = Arguments::read(&["first".to_string(), "second".to_string()])
            .expect("the arguments are read");
        assert_eq!(arguments.positional(0).as_deref(), Some("first"));
        assert_eq!(arguments.positional(1).as_deref(), Some("second"));
        assert_eq!(arguments.positional(2), None);
    }

    #[test]
    fn an_option_is_read_in_both_forms() {
        let arguments = Arguments::read(&[
            "--out".to_string(),
            "/tmp/bindings.rs".to_string(),
            "--from=/tmp/desktop.rs".to_string(),
        ])
        .expect("the arguments are read");
        assert_eq!(
            arguments.option("--out").as_deref(),
            Some("/tmp/bindings.rs")
        );
        assert_eq!(
            arguments.option("--from").as_deref(),
            Some("/tmp/desktop.rs")
        );
        assert_eq!(arguments.option("--missing"), None);
    }

    #[test]
    fn an_option_is_never_a_path() {
        // The bug this guards: `--from <file>` was read as the bundle, and
        // the headers were fetched into a directory named `--from`.
        let arguments = Arguments::read(&[
            "--from".to_string(),
            "/tmp/desktop.rs".to_string(),
            "/tmp/bundle".to_string(),
        ])
        .expect("the arguments are read");
        assert_eq!(arguments.positional(0).as_deref(), Some("/tmp/bundle"));
        assert_eq!(
            arguments.option("--from").as_deref(),
            Some("/tmp/desktop.rs")
        );
    }

    #[test]
    fn an_option_without_a_value_is_refused() {
        let error = Arguments::read(&["--out".to_string()]).expect_err("the option has no value");
        assert!(error.to_string().contains("needs a value"));
    }

    #[test]
    fn the_defaults_are_relative_to_the_working_directory() {
        // The service must not carry the paths of the machine it was written
        // on: every default is relative or comes from the environment.
        std::env::remove_var("CEF_BUNDLE_DIR");
        assert_eq!(default_bundle(), PathBuf::from("cef-bundle"));
        assert_eq!(default_staging(), PathBuf::from("cef-staging"));
    }
}
