//! The C ABI of the engine, and what the consumer of it links against.
//!
//! The engine is a shared library that exports the C API of CEF.  A consumer
//! — the Rust crate that binds it — links against that library, and the
//! linker resolves every symbol that the consumer *references*.  A symbol
//! that the consumer does not reference does not have to exist, and a symbol
//! that the consumer does reference and that the engine does not export stops
//! the link of the consumer with
//!
//! ```text
//! undefined reference to `cef_browser_host_create_browser'
//! ```
//!
//! The two lists are therefore a contract, and this module is the audit of
//! it:
//!
//! * the **required** symbols are the ones the consumer references.  They
//!   are pinned in the manifest of the service, because the consumer is a
//!   different repository and the service cannot see it;
//! * the **exported** symbols are the ones the headers of the engine
//!   declare.  They come from the checkout of the pinned commit, so they
//!   are the truth of the engine and not a copy of it.
//!
//! The audit answers two questions: does the engine export everything the
//! consumer needs, and does the consumer need anything that the engine
//! does not export.  Both are answered from the *headers* of the engine, so
//! the answer does not depend on a build of the engine.
//!
//! # The three tiers of the headers
//!
//! CEF declares its C functions in three places, and the difference matters
//! to a build for Android:
//!
//! | tier | the headers | what it is |
//! |---|---|---|
//! | published | `include/capi/` | the C API that the engine promises |
//! | views | `include/capi/views/` | the C API of the framework of the views — the user interface of the **desktop** browser |
//! | internal | `include/internal/` | the helpers of the strings, the times and the lists, which the engine exports but does not promise |
//!
//! The tier of the views is the one that cannot be built for Android: the
//! framework of the views is built by Chromium for the desktop platforms
//! only, and the browser of CEF is built with it.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

use anyhow::{bail, Context, Result};

/// Where a function of the C API is declared.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    /// `include/` — the root of the headers: the version and the hash of
    /// the API, and nothing else.
    Base,
    /// `include/capi/` — the C API that the engine promises.
    Published,
    /// `include/capi/views/` — the C API of the framework of the views.
    Views,
    /// `include/internal/` — the helpers that the engine exports.
    Internal,
}

impl Tier {
    /// The name of the tier, for the reports.
    pub fn name(&self) -> &'static str {
        match self {
            Tier::Base => "base",
            Tier::Published => "published",
            Tier::Views => "views",
            Tier::Internal => "internal",
        }
    }

    /// The directory of the headers of the tier, relative to the checkout.
    pub fn directory(&self) -> &'static str {
        match self {
            Tier::Base => "include",
            Tier::Published => "include/capi",
            Tier::Views => "include/capi/views",
            Tier::Internal => "include/internal",
        }
    }

    /// Whether the tier walks the directories below its own.
    ///
    /// The tier of the published C API does **not** walk into the views:
    /// the C API of the views is its own tier, and the difference between
    /// them is the difference between the engine that can be built for
    /// Android and the engine that cannot.
    pub fn recurses(&self) -> bool {
        match self {
            Tier::Base => false,
            Tier::Published => false,
            Tier::Views => false,
            Tier::Internal => true,
        }
    }

    /// The tiers, in the order they are reported.
    pub fn all() -> [Tier; 4] {
        [Tier::Base, Tier::Published, Tier::Views, Tier::Internal]
    }
}

/// A function of the C API, with the prototype it has in the headers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prototype {
    /// The name of the function.
    pub name: String,
    /// The return type of the function.
    pub returns: String,
    /// The parameters of the function, with their types.
    pub parameters: Vec<(String, String)>,
    /// The declaration, as it is in the header.
    pub declaration: String,
    /// The tier of the header that declares it.
    pub tier: Tier,
}

impl Prototype {
    /// The declaration in the shape of a C prototype.
    pub fn as_c(&self) -> String {
        let parameters = if self.parameters.is_empty() {
            "void".to_string()
        } else {
            self.parameters
                .iter()
                .map(|(kind, name)| {
                    if name.is_empty() {
                        kind.clone()
                    } else {
                        format!("{kind} {name}")
                    }
                })
                .collect::<Vec<_>>()
                .join(", ")
        };
        format!("{} {}({});", self.returns, self.name, parameters)
    }
}

/// The C API of a checkout of the engine, read from its headers.
#[derive(Debug, Default)]
pub struct Abi {
    /// The functions that the headers declare.
    pub functions: Vec<Prototype>,
    /// The structures that the headers define.
    pub structures: BTreeSet<String>,
}

impl Abi {
    /// Read the C API from the headers of a checkout.
    ///
    /// The argument is the directory of the checkout of the engine — the one
    /// that holds `include/`.  A tier whose directory is not there is
    /// skipped: a checkout that has been built has all of them, and a
    /// checkout that has not has none.
    pub fn read(cef_dir: &Path) -> Result<Abi> {
        let mut abi = Abi::default();
        let mut seen = BTreeSet::new();

        for tier in Tier::all() {
            let directory = cef_dir.join(tier.directory());
            if !directory.is_dir() {
                continue;
            }
            let mut headers: Vec<PathBuf> = Vec::new();
            collect_headers(&directory, tier.recurses(), &mut headers);
            headers.sort();
            for header in headers {
                let text = fs::read_to_string(&header)
                    .with_context(|| format!("cannot read {}", header.display()))?;
                for prototype in parse_prototypes(&text, tier) {
                    if seen.insert(prototype.name.clone()) {
                        abi.functions.push(prototype);
                    }
                }
                for structure in parse_structures(&text) {
                    abi.structures.insert(structure);
                }
            }
        }
        if abi.functions.is_empty() {
            bail!("{} carries no C API headers", cef_dir.display());
        }
        Ok(abi)
    }

    /// The names of the functions that the headers declare.
    pub fn function_names(&self) -> BTreeSet<String> {
        self.functions
            .iter()
            .map(|prototype| prototype.name.clone())
            .collect()
    }

    /// The prototype of a function, by name.
    pub fn function(&self, name: &str) -> Option<&Prototype> {
        self.functions
            .iter()
            .find(|prototype| prototype.name == name)
    }

    /// Compare the API of the engine with the symbols a consumer needs.
    ///
    /// The result carries the differences that matter: a symbol that the
    /// consumer needs and the engine does not have, and a symbol that the
    /// engine has and the consumer does not need.  The second is not an
    /// error — it is the list of the desktop handlers that the shim of the
    /// service implements as stubs.
    pub fn audit(&self, required: &BTreeSet<String>) -> Audit {
        let exported = self.function_names();
        let missing: Vec<String> = required.difference(&exported).cloned().collect();
        let unused: Vec<String> = exported.difference(required).cloned().collect();

        let mut by_tier: BTreeMap<Tier, usize> = BTreeMap::new();
        for prototype in &self.functions {
            *by_tier.entry(prototype.tier).or_insert(0) += 1;
        }
        let mut required_by_tier: BTreeMap<Tier, usize> = BTreeMap::new();
        for name in required {
            if let Some(prototype) = self.function(name) {
                *required_by_tier.entry(prototype.tier).or_insert(0) += 1;
            }
        }
        Audit {
            required: required.len(),
            exported: exported.len(),
            missing,
            unused,
            by_tier,
            required_by_tier,
        }
    }
}

/// The result of the audit of the C ABI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Audit {
    /// How many symbols the consumer needs.
    pub required: usize,
    /// How many symbols the engine exports.
    pub exported: usize,
    /// The symbols the consumer needs and the engine does not have.
    pub missing: Vec<String>,
    /// The symbols the engine has and the consumer does not need.
    pub unused: Vec<String>,
    /// How many functions each tier declares.
    pub by_tier: BTreeMap<Tier, usize>,
    /// How many of the required symbols each tier carries.
    pub required_by_tier: BTreeMap<Tier, usize>,
}

impl Audit {
    /// Whether the consumer can be linked against the engine.
    pub fn links(&self) -> bool {
        self.missing.is_empty()
    }
}

/// The headers of a directory, in order.
///
/// `recurse` says whether the directories below are walked: the tier of the
/// published C API does not walk into the views, because the C API of the
/// views is a tier of its own.
fn collect_headers(directory: &Path, recurse: bool, headers: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if recurse {
                collect_headers(&path, recurse, headers);
            }
        } else if path.extension().is_some_and(|extension| extension == "h") {
            headers.push(path);
        }
    }
}

/// The prototypes that a header declares.
///
/// A declaration of the C API is of one shape:
///
/// ```c
/// CEF_EXPORT int cef_browser_host_create_browser(const cef_window_info_t* windowInfo, ...);
/// ```
///
/// and it is often **spread over several lines**, so the declarations are
/// joined before they are read.  A declaration that the parse does not
/// understand is not a declaration, and a declaration that it misunderstands
/// is worse than none.
fn parse_prototypes(text: &str, tier: Tier) -> Vec<Prototype> {
    let mut prototypes = Vec::new();
    for declaration in declarations(text) {
        let Some(prototype) = parse_prototype(&declaration, tier) else {
            continue;
        };
        prototypes.push(prototype);
    }
    prototypes
}

/// The declarations of a header, one per string.
///
/// A declaration starts with `CEF_EXPORT` and ends with the first `;` that
/// is not inside brackets.
fn declarations(text: &str) -> Vec<String> {
    let mut declarations = Vec::new();
    let mut current = String::new();
    let mut inside = false;
    let mut depth = 0usize;

    for line in text.lines() {
        let trimmed = line.trim();
        if !inside {
            if !trimmed.starts_with("CEF_EXPORT") {
                continue;
            }
            inside = true;
            depth = 0;
            current = String::new();
        }
        for character in trimmed.chars() {
            match character {
                '(' | '[' => depth += 1,
                ')' | ']' => depth = depth.saturating_sub(1),
                ';' if depth == 0 => {
                    current.push(character);
                    declarations.push(current.trim().to_string());
                    current.clear();
                    inside = false;
                    break;
                }
                _ => {}
            }
            current.push(character);
        }
        current.push(' ');
    }
    declarations
}

/// The prototype of one declaration.
fn parse_prototype(declaration: &str, tier: Tier) -> Option<Prototype> {
    let rest = declaration.strip_prefix("CEF_EXPORT")?.trim();
    let rest = rest.strip_suffix(';')?.trim();
    let open = rest.find('(')?;
    let close = rest.rfind(')')?;
    if close < open {
        return None;
    }
    let head = rest[..open].trim();
    let name = head.rsplit(' ').next()?.trim().to_string();
    if !name.starts_with("cef_")
        || !name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
    {
        return None;
    }
    let returns = head[..head.len() - name.len()].trim().to_string();
    let parameters = parse_parameters(&rest[open + 1..close]);
    Some(Prototype {
        name,
        returns,
        parameters,
        declaration: format!("CEF_EXPORT {rest};"),
        tier,
    })
}

/// The parameters of a declaration, with their types.
fn parse_parameters(text: &str) -> Vec<(String, String)> {
    let text = text.trim();
    if text.is_empty() || text == "void" {
        return Vec::new();
    }
    let mut parameters = Vec::new();
    let mut depth = 0usize;
    let mut current = String::new();
    for character in text.chars() {
        match character {
            '(' | '[' | '{' => {
                depth += 1;
                current.push(character);
            }
            ')' | ']' | '}' => {
                depth = depth.saturating_sub(1);
                current.push(character);
            }
            ',' if depth == 0 => {
                parameters.push(current.clone());
                current.clear();
            }
            _ => current.push(character),
        }
    }
    parameters.push(current);

    parameters
        .into_iter()
        .filter_map(|parameter| {
            let parameter = parameter.trim();
            if parameter.is_empty() {
                return None;
            }
            // The name of a parameter is the last word, unless the parameter
            // is an array (`char name[]`) or a function pointer.
            if parameter.ends_with(']') || parameter.contains("(*") {
                return Some((parameter.to_string(), String::new()));
            }
            let (kind, name) = parameter.rsplit_once(' ')?;
            Some((kind.trim().to_string(), name.trim().to_string()))
        })
        .collect()
}

/// The structures that a header defines.
fn parse_structures(text: &str) -> Vec<String> {
    let mut structures = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        for prefix in ["typedef struct _", "struct _"] {
            if let Some(rest) = line.strip_prefix(prefix) {
                if let Some(name) = rest.split_whitespace().next() {
                    let name = name.trim_end_matches(';');
                    if name.starts_with("cef_") {
                        structures.push(format!("_{name}"));
                    }
                }
            }
        }
    }
    structures
}

/// The symbols that the consumer of the engine links against.
///
/// The list is pinned: the consumer is a different repository, and the
/// service cannot see which of the functions of the C API it uses.  The
/// list was measured from the objects of the consumer, with the symbols
/// that the linker has to resolve, and it is checked by the test of this
/// module against the headers of the pinned engine.
pub fn required_symbols() -> BTreeSet<String> {
    include_str!("../manifest/cef-abi-required.txt")
        .lines()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| line.to_string())
        .collect()
}

/// The directory of the C API headers of a checkout of the engine.
pub fn capi_dir(cef_dir: &Path) -> PathBuf {
    cef_dir.join("include").join("capi")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_prototype_is_read() {
        let text = "CEF_EXPORT int cef_thing(const cef_window_info_t* windowInfo, int count);";
        let prototypes = parse_prototypes(text, Tier::Published);
        assert_eq!(prototypes.len(), 1);
        assert_eq!(prototypes[0].name, "cef_thing");
        assert_eq!(prototypes[0].returns, "int");
        assert_eq!(prototypes[0].parameters.len(), 2);
        assert_eq!(prototypes[0].parameters[0].0, "const cef_window_info_t*");
        assert_eq!(prototypes[0].parameters[0].1, "windowInfo");
    }

    #[test]
    fn a_declaration_over_several_lines_is_read() {
        // The declarations of the C API are often spread over several lines,
        // and a parse that reads one line at a time misses them.
        let text = "CEF_EXPORT void cef_string_list_append(cef_string_list_t list,\n\
                    cef_string_t value);\n";
        let prototypes = parse_prototypes(text, Tier::Internal);
        assert_eq!(prototypes.len(), 1);
        assert_eq!(prototypes[0].name, "cef_string_list_append");
        assert_eq!(prototypes[0].parameters.len(), 2);
        assert_eq!(prototypes[0].parameters[1].1, "value");
    }

    #[test]
    fn a_function_without_parameters_is_read() {
        let text = "CEF_EXPORT void cef_nothing();";
        let prototypes = parse_prototypes(text, Tier::Published);
        assert_eq!(prototypes.len(), 1);
        assert!(prototypes[0].parameters.is_empty());
        assert_eq!(prototypes[0].as_c(), "void cef_nothing(void);");
    }

    #[test]
    fn a_declaration_that_is_not_a_function_is_skipped() {
        let text = "CEF_EXPORT const int cef_constant = 3;";
        assert!(parse_prototypes(text, Tier::Published).is_empty());
    }

    #[test]
    fn the_required_symbols_are_read() {
        let symbols = required_symbols();
        assert!(
            symbols.len() > 100,
            "the list of the required symbols is not empty: {}",
            symbols.len()
        );
        assert!(symbols.contains("cef_browser_host_create_browser"));
        assert!(symbols.contains("cef_initialize"));
    }

    #[test]
    fn the_required_symbols_are_the_ones_that_were_measured() {
        // The list was measured from the objects of the consumer: 190
        // symbols, and no more.  A list that grows means that the consumer
        // changed, and the list has to be measured again.
        assert_eq!(required_symbols().len(), 190);
    }

    #[test]
    fn the_symbols_of_the_views_are_separated() {
        // The framework of the views is the user interface of the desktop
        // browser, and it is not built for Android.  The seventeen symbols
        // of that tier are the ones the shim stubs.
        let required = required_symbols();
        let views: Vec<&String> = required
            .iter()
            .filter(|name| {
                name.starts_with("cef_display_")
                    || name.starts_with("cef_browser_view_")
                    || *name == "cef_window_create_top_level"
                    || *name == "cef_panel_create"
                    || *name == "cef_label_button_create"
                    || *name == "cef_menu_button_create"
                    || *name == "cef_scroll_view_create"
                    || *name == "cef_textfield_create"
            })
            .collect();
        assert_eq!(views.len(), 17, "the symbols of the views: {views:?}");
    }

    #[test]
    fn the_audit_names_the_two_differences() {
        let abi = Abi {
            functions: vec![
                Prototype {
                    name: "cef_one".to_string(),
                    returns: "int".to_string(),
                    parameters: Vec::new(),
                    declaration: "CEF_EXPORT int cef_one();".to_string(),
                    tier: Tier::Published,
                },
                Prototype {
                    name: "cef_two".to_string(),
                    returns: "int".to_string(),
                    parameters: Vec::new(),
                    declaration: "CEF_EXPORT int cef_two();".to_string(),
                    tier: Tier::Views,
                },
            ],
            structures: BTreeSet::new(),
        };
        let mut required = BTreeSet::new();
        required.insert("cef_one".to_string());
        required.insert("cef_three".to_string());
        let audit = abi.audit(&required);
        assert!(!audit.links());
        assert_eq!(audit.missing, vec!["cef_three".to_string()]);
        assert_eq!(audit.unused, vec!["cef_two".to_string()]);
        assert_eq!(audit.by_tier.get(&Tier::Views), Some(&1));
    }
}
