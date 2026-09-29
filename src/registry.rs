//! Package registry: every managed app, its upstream metadata, and the
//! outputs the installer is expected to produce (used for receipts).

use anyhow::Result;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// GitHub releases (per-asset sha256 digests via the API).
    GitHub,
    /// nodejs.org/dist (SHASUMS256.txt verification).
    Nodejs,
}

pub struct App {
    pub name: &'static str,
    pub source: Source,
    /// GitHub "owner/repo"; unused for Nodejs.
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
    /// Version to fall back to when the latest release has no build for this
    /// machine's arch (git-delta dropped Intel after 0.18.2).
    pub fallback_version: Option<&'static str>,
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

/// nodejs.org / tree-sitter style: arm64 | x64.
fn arch_node(uname: &str) -> Result<&'static str> {
    match uname {
        "arm64" | "aarch64" => Ok("arm64"),
        "x86_64" => Ok("x64"),
        other => Err(anyhow::anyhow!("unsupported architecture: {other}")),
    }
}

pub static APPS: &[App] = &[
    App {
        name: "nushell",
        source: Source::GitHub,
        repo: "nushell/nushell",
        script: include_str!("../apps/nushell.sh"),
        summary: "Nushell shell (nu + bundled plugins)",
        tag_prefix: "",
        asset_template: "nu-{version}-{arch}.tar.gz",
        arch_token: arch_triple,
        fallback_version: None,
        output_globs: &["bin/nu", "bin/nu_plugin_*"],
        extra_args: &["--no-shell"],
        purge_paths: &[],
        hint: "run `nu` to start; `mdrv-macos configure nushell` sets it as login shell",
    },
    App {
        name: "fzf",
        source: Source::GitHub,
        repo: "junegunn/fzf",
        script: include_str!("../apps/fzf.sh"),
        summary: "fuzzy finder (key bindings & completions are separate)",
        tag_prefix: "v",
        asset_template: "fzf-{version}-darwin_{arch}.tar.gz",
        arch_token: arch_short,
        fallback_version: None,
        output_globs: &["bin/fzf"],
        extra_args: &[],
        purge_paths: &[],
        hint: "see https://github.com/junegunn/fzf#installation for shell integrations",
    },
    App {
        name: "fnm",
        source: Source::GitHub,
        repo: "Schniz/fnm",
        script: include_str!("../apps/fnm.sh"),
        summary: "Fast Node Manager (universal macOS binary)",
        tag_prefix: "v",
        asset_template: "fnm-macos.zip",
        arch_token: arch_universal,
        fallback_version: None,
        output_globs: &["bin/fnm"],
        extra_args: &[],
        purge_paths: &[],
        hint: "next: fnm install --lts && fnm default lts-latest",
    },
    App {
        name: "fastfetch",
        source: Source::GitHub,
        repo: "fastfetch-cli/fastfetch",
        script: include_str!("../apps/fastfetch.sh"),
        summary: "system information tool (neofetch-like)",
        tag_prefix: "",
        asset_template: "fastfetch-macos-{arch}.tar.gz",
        arch_token: arch_short,
        fallback_version: None,
        output_globs: &[
            "bin/fastfetch",
            "share/fastfetch/**",
            "share/man/man1/fastfetch.1",
        ],
        extra_args: &[],
        purge_paths: &[],
        hint: "presets land in ~/.local/share/fastfetch (XDG data dir)",
    },
    App {
        name: "carapace",
        source: Source::GitHub,
        repo: "carapace-sh/carapace-bin",
        script: include_str!("../apps/carapace.sh"),
        summary: "multi-shell completions for hundreds of CLIs",
        tag_prefix: "v",
        asset_template: "carapace-bin_{version}_darwin_{arch}.tar.gz",
        arch_token: arch_short,
        fallback_version: None,
        output_globs: &["bin/carapace"],
        extra_args: &[],
        purge_paths: &[],
        hint: "hook: source <(carapace zsh) — nushell: carapace _carapace nushell",
    },
    App {
        name: "unison",
        source: Source::GitHub,
        repo: "bcpierce00/unison",
        script: include_str!("../apps/unison.sh"),
        summary: "file synchronizer (bidirectional, rsync-compatible protocol)",
        tag_prefix: "v",
        asset_template: "unison-{version}-macos-{arch}.tar.gz",
        arch_token: |u| match u {
            "arm64" | "aarch64" => Ok("arm64"),
            "x86_64" => Ok("x86-64"),
            other => Err(anyhow::anyhow!("unsupported architecture: {other}")),
        },
        fallback_version: None,
        output_globs: &["bin/unison", "share/man/man1/unison.1"],
        extra_args: &[],
        purge_paths: &[],
        hint: "both sync ends should run compatible unison versions; GUI lives in the Unison-*.app asset",
    },
    App {
        name: "git-delta",
        source: Source::GitHub,
        repo: "dandavison/delta",
        script: include_str!("../apps/git-delta.sh"),
        summary: "syntax-highlighting pager for git diffs",
        tag_prefix: "",
        asset_template: "delta-{version}-{arch}.tar.gz",
        arch_token: arch_triple,
        fallback_version: Some("0.18.2"),
        output_globs: &["bin/delta"],
        extra_args: &[],
        purge_paths: &[],
        hint: "wire into git: git config --global core.pager delta (also interactive.diffFilter 'delta --color-only')",
    },
    App {
        name: "tree-sitter-cli",
        source: Source::GitHub,
        repo: "tree-sitter/tree-sitter",
        script: include_str!("../apps/tree-sitter-cli.sh"),
        summary: "parser generator toolchain CLI (create & test grammars)",
        tag_prefix: "v",
        asset_template: "tree-sitter-macos-{arch}.gz",
        arch_token: arch_node,
        fallback_version: None,
        output_globs: &["bin/tree-sitter"],
        extra_args: &[],
        purge_paths: &[],
        hint: "config lives at ~/.config/tree-sitter/config.json (tree-sitter init-config)",
    },
    App {
        name: "turso",
        source: Source::GitHub,
        repo: "tursodatabase/turso",
        script: include_str!("../apps/turso.sh"),
        summary: "Turso embedded database (libSQL) CLI & shell",
        tag_prefix: "v",
        asset_template: "turso_cli-{arch}.tar.xz",
        arch_token: arch_triple,
        fallback_version: None,
        output_globs: &["bin/tursodb", "bin/turso"],
        extra_args: &[],
        purge_paths: &[],
        hint: "the upstream binary is tursodb; `turso` is a symlink to it",
    },
    App {
        name: "node",
        source: Source::Nodejs,
        repo: "",
        script: include_str!("../apps/node.sh"),
        summary: "Node.js runtime (node, npm, npx — full official build)",
        tag_prefix: "v",
        asset_template: "node-v{version}-darwin-{arch}.tar.gz",
        arch_token: arch_node,
        fallback_version: None,
        output_globs: &[
            "bin/node",
            "bin/npm",
            "bin/npx",
            "bin/corepack",
            "lib/node_modules/**",
            "include/node/**",
            "share/**",
        ],
        extra_args: &[],
        purge_paths: &[],
        hint: "fnm users may prefer `fnm install --lts` instead — both can coexist",
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
