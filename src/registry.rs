//! Package registry: every managed app, its upstream metadata, and the
//! outputs the installer is expected to produce (used for receipts).

use anyhow::Result;

pub struct App {
    pub name: &'static str,
    pub repo: &'static str,
    /// Embedded installer (single source of truth: apps/*.sh, still usable standalone).
    pub script: &'static str,
    pub summary: &'static str,
    /// Prefix of release tags: "" (nushell) or "v" (fzf, fnm).
    pub tag_prefix: &'static str,
    /// Asset name template; {version} and {arch} are substituted.
    pub asset_template: &'static str,
    /// Map `uname -m` to the arch token this app uses in asset names.
    pub arch_token: fn(uname: &str) -> Result<&'static str>,
    /// File globs (relative to the install prefix) the installer produces.
    pub output_globs: &'static [&'static str],
    /// Extra flags always passed to the embedded installer script.
    pub extra_args: &'static [&'static str],
    /// Paths (relative to $HOME) removed by `uninstall --purge`.
    pub purge_paths: &'static [&'static str],
    pub hint: &'static str,
}

pub(crate) fn arch_triple(uname: &str) -> Result<&'static str> {
    match uname {
        "arm64" => Ok("aarch64-apple-darwin"),
        "x86_64" => Ok("x86_64-apple-darwin"),
        other => Err(anyhow::anyhow!("unsupported architecture: {other}")),
    }
}

fn arch_short(uname: &str) -> Result<&'static str> {
    match uname {
        "arm64" => Ok("arm64"),
        "x86_64" => Ok("amd64"),
        other => Err(anyhow::anyhow!("unsupported architecture: {other}")),
    }
}

fn arch_universal(_uname: &str) -> Result<&'static str> {
    Ok("universal")
}

pub static APPS: &[App] = &[
    App {
        name: "nushell",
        repo: "nushell/nushell",
        script: include_str!("../apps/nushell.sh"),
        summary: "Nushell shell (nu + bundled plugins)",
        tag_prefix: "",
        asset_template: "nu-{version}-{arch}.tar.gz",
        arch_token: arch_triple,
        output_globs: &["bin/nu", "bin/nu_plugin_*"],
        extra_args: &["--no-shell"],
        purge_paths: &[],
        hint: "run `nu` to start; `mdrv-macos configure nushell` sets it as login shell",
    },
    App {
        name: "fzf",
        repo: "junegunn/fzf",
        script: include_str!("../apps/fzf.sh"),
        summary: "fuzzy finder (key bindings & completions are separate)",
        tag_prefix: "v",
        asset_template: "fzf-{version}-darwin_{arch}.tar.gz",
        arch_token: arch_short,
        output_globs: &["bin/fzf"],
        extra_args: &[],
        purge_paths: &[],
        hint: "see https://github.com/junegunn/fzf#installation for shell integrations",
    },
    App {
        name: "fnm",
        repo: "Schniz/fnm",
        script: include_str!("../apps/fnm.sh"),
        summary: "Fast Node Manager (universal macOS binary)",
        tag_prefix: "v",
        asset_template: "fnm-macos.zip",
        arch_token: arch_universal,
        output_globs: &["bin/fnm"],
        extra_args: &[],
        purge_paths: &[],
        hint: "next: fnm install --lts && fnm default lts-latest",
    },
];

pub fn find(name: &str) -> Option<&'static App> {
    APPS.iter().find(|a| a.name == name)
}

/// The machine's `uname -m`.
pub fn uname_m() -> Result<String> {
    let out = std::process::Command::new("uname").arg("-m").output()?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}
