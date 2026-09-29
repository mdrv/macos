//! mdrv-macos — curated binary package manager for macOS.
//!
//! Wraps the self-contained installers in `apps/` with pacman-like
//! mechanics: artifact caching, install receipts, uninstall, configure,
//! and upgrades. The installers stay fully usable standalone via curl|sh.

mod cache;
mod gh;
mod ops;
mod receipt;
mod registry;
mod ui;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "mdrv-macos",
    version,
    about = "Curated binary package manager for macOS (mdrv/macos)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Install a package (name or name@version; no args = interactive picker)
    #[command(alias = "add")]
    Install {
        packages: Vec<String>,
        /// Install root (default ~/.local)
        #[arg(long)]
        prefix: Option<std::path::PathBuf>,
        /// Never offer to edit shell rc files
        #[arg(long)]
        no_path: bool,
    },
    /// Remove a managed package (receipt-driven)
    #[command(alias = "remove")]
    Uninstall {
        packages: Vec<String>,
        /// Also remove the app's own configuration/data
        #[arg(long)]
        purge: bool,
    },
    /// Re-run installer-level configuration (PATH, login shell)
    Configure { packages: Vec<String> },
    /// Upgrade installed packages to the latest release
    Upgrade { packages: Vec<String> },
    /// List packages and their install state
    List,
    /// Show details about a package
    Info { package: String },
    /// Manage the artifact cache
    Cache {
        #[command(subcommand)]
        cmd: CacheCmd,
    },
    /// Update mdrv-macos itself from GitHub releases
    #[command(name = "self-update")]
    SelfUpdate,
}

#[derive(Subcommand)]
enum CacheCmd {
    /// List cached artifacts
    #[command(alias = "list")]
    Ls,
    /// Remove all cached artifacts
    Clean,
}

fn main() {
    let cli = Cli::parse();
    let result = match cli.cmd {
        None => ops::install(&[], None, false),
        Some(Cmd::Install {
            packages,
            prefix,
            no_path,
        }) => ops::install(&packages, prefix, no_path),
        Some(Cmd::Uninstall { packages, purge }) => ops::uninstall(&packages, purge),
        Some(Cmd::Configure { packages }) => ops::configure(&packages),
        Some(Cmd::Upgrade { packages }) => ops::upgrade(&packages),
        Some(Cmd::List) => ops::list(),
        Some(Cmd::Info { package }) => ops::info(&package),
        Some(Cmd::Cache { cmd }) => match cmd {
            CacheCmd::Ls => ops::cache_list(),
            CacheCmd::Clean => ops::cache_clean(),
        },
        Some(Cmd::SelfUpdate) => ops::self_update(),
    };
    if let Err(e) = result {
        eprintln!(
            "{} {}",
            console::style("mdrv-macos: error:").red().bold(),
            e
        );
        std::process::exit(1);
    }
}
