//! The commands themselves: install, uninstall, configure, upgrade, list,
//! info, cache, self-update.

use crate::cache;
use crate::gh;
use crate::receipt::{self, RcBlock, Receipt};
use crate::registry::{self, App, Source};
use crate::ui;
use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

pub const RC_MARKER: &str = "# Added by mdrv-macos";

pub fn default_prefix() -> PathBuf {
    cache::home::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join(".local")
}

fn epoch_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// "name" or "name@1.2.3".
fn parse_pkg(spec: &str) -> Result<(&str, Option<String>)> {
    match spec.split_once('@') {
        Some((name, ver)) if !name.is_empty() && !ver.is_empty() => {
            Ok((name, Some(ver.trim_start_matches('v').to_string())))
        }
        Some(_) => bail!("bad package spec: {spec} (expected name or name@version)"),
        None => Ok((spec, None)),
    }
}

fn bindir(prefix: &Path) -> PathBuf {
    prefix.join("bin")
}

fn on_path(dir: &Path) -> bool {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).any(|p| p == dir)
}

fn rc_file() -> PathBuf {
    let home = cache::home::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    let sh = std::env::var("SHELL").unwrap_or_default();
    if sh.ends_with("zsh") {
        home.join(".zshrc")
    } else {
        home.join(".bashrc")
    }
}

/// Ensure the bin dir is reachable: report PATH state, offer the rc block,
/// and return the block if it exists in the rc file afterwards.
fn ensure_path(prefix: &Path, skip_offer: bool) -> Result<Option<RcBlock>> {
    let dir = bindir(prefix);
    if on_path(&dir) {
        return Ok(None);
    }
    let rc = rc_file();
    let already = rc.exists()
        && std::fs::read_to_string(&rc)
            .map(|t| t.contains(&format!("\n{RC_MARKER}\n")) || t.contains(RC_MARKER))
            .unwrap_or(false);
    if already {
        return Ok(Some(RcBlock {
            file: rc,
            marker: RC_MARKER.into(),
        }));
    }
    if skip_offer || !ui::is_interactive() {
        ui::warn(&format!(
            "{} is not on your PATH — add: export PATH=\"{}:$PATH\"",
            dir.display(),
            dir.display()
        ));
        return Ok(None);
    }
    if ui::confirm(&format!(
        "{} is not on your PATH. Add it to {}?",
        dir.display(),
        rc.display()
    )) {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&rc)?;
        writeln!(f, "\n{RC_MARKER}")?;
        writeln!(f, "export PATH=\"{}:$PATH\"", dir.display())?;
        println!(
            "    {} added to {} — open a new shell",
            style_fmt("PATH"),
            rc.display()
        );
        return Ok(Some(RcBlock {
            file: rc,
            marker: RC_MARKER.into(),
        }));
    }
    Ok(None)
}

fn style_fmt(s: &str) -> String {
    console::style(s).bold().to_string()
}

struct Resolved {
    version: String,
    asset: String,
    url: String,
    digest: Option<String>,
    upstream: String,
}

fn render_asset(app: &App, version: &str, arch: &str) -> String {
    app.asset_template
        .replace("{version}", version)
        .replace("{arch}", arch)
}

/// Resolve the latest (or pinned) release of an app into the concrete asset
/// to fetch, honouring per-source resolution rules and arch fallbacks.
fn resolve(app: &App, version_req: Option<&str>, arch: &str) -> Result<Resolved> {
    match app.source {
        Source::GitHub => {
            let rel = gh::fetch(app.repo, app.tag_prefix, version_req)
                .with_context(|| format!("resolving {}", app.name))?;
            let mut version = rel.version(app.tag_prefix);
            let mut asset = render_asset(app, &version, arch);
            let mut rel = rel;
            // Arch fallback: the latest release may have dropped this arch.
            if let Some(fb) = app.fallback_version {
                if arch == "x86_64-apple-darwin" && rel.digest(&asset).is_none() {
                    ui::info(&format!(
                        "{}: no Intel build in {} — falling back to {fb}",
                        app.name, version
                    ));
                    version = fb.to_string();
                    asset = render_asset(app, &version, arch);
                    rel = gh::fetch(app.repo, app.tag_prefix, Some(fb))?;
                }
            }
            let tag = format!("{}{version}", app.tag_prefix);
            Ok(Resolved {
                digest: rel
                    .digest(&asset)
                    .map(|d| d.trim_start_matches("sha256:").to_string()),
                url: gh::asset_url(app.repo, &tag, &asset),
                version,
                asset,
                upstream: format!("https://github.com/{}", app.repo),
            })
        }
        Source::Nodejs => {
            let version = gh::fetch_node(version_req)?;
            let asset = render_asset(app, &version, arch);
            let url = format!("https://nodejs.org/dist/v{version}/{asset}");
            let digest = gh::node_digest(&version, &asset)?;
            Ok(Resolved {
                version,
                asset,
                url,
                digest: Some(digest),
                upstream: "https://nodejs.org/dist".into(),
            })
        }
    }
}

fn expand_outputs(app: &App, prefix: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for pattern in app.output_globs {
        let full = prefix.join(pattern);
        let pattern = full.to_string_lossy().into_owned();
        for entry in glob::glob(&pattern)? {
            match entry {
                Ok(p) if p.is_file() => files.push(p),
                _ => {}
            }
        }
    }
    files.sort();
    files.dedup();
    Ok(files)
}

pub fn install_one(
    app: &App,
    version_req: Option<String>,
    prefix: &Path,
    skip_path_offer: bool,
) -> Result<()> {
    let arch = (app.arch_token)(&registry::uname_m()?)?;
    let r = resolve(app, version_req.as_deref(), arch)?;

    ui::info(&format!(
        "{} {} ({}{})",
        app.name,
        r.version,
        r.asset,
        r.digest
            .as_deref()
            .map(|d| format!(" sha256:{d}"))
            .unwrap_or_default()
    ));
    let file = cache::ensure(&r.asset, &r.url, r.digest.as_deref())?;

    // Run the embedded installer script with the verified cache entry.
    let script = tempfile::NamedTempFile::new()?;
    std::fs::write(script.path(), app.script)?;
    let status = std::process::Command::new("sh")
        .arg(script.path())
        .arg("--prefix")
        .arg(prefix)
        .arg("--no-path")
        .args(app.extra_args)
        .env("MDRV_VERSION", &r.version)
        .env("MDRV_ASSET_FILE", &file)
        .status()
        .context("could not run sh")?;
    if !status.success() {
        bail!("installer for {} failed", app.name);
    }

    let files = expand_outputs(app, prefix)?;
    if files.is_empty() {
        bail!(
            "no expected outputs found under {} — installer layout changed?",
            bindir(prefix).display()
        );
    }
    let rc_block = ensure_path(prefix, skip_path_offer)?;

    receipt::save(&Receipt {
        name: app.name.into(),
        version: r.version.clone(),
        asset: r.asset.clone(),
        sha256: r.digest.clone(),
        installed_at: epoch_now(),
        prefix: prefix.into(),
        files: files.clone(),
        rc_blocks: rc_block.into_iter().collect(),
        previous_shell: None,
    })?;

    ui::info(&format!(
        "{} {} installed → {} ({} files tracked)",
        app.name,
        r.version,
        bindir(prefix).display(),
        files.len()
    ));
    println!("    {}", app.hint);
    Ok(())
}

pub fn install(specs: &[String], prefix: Option<PathBuf>, no_path: bool) -> Result<()> {
    let prefix = prefix.unwrap_or_else(default_prefix);
    if specs.is_empty() {
        let chosen = interactive_select()?;
        if chosen.is_empty() {
            ui::warn("nothing selected");
            return Ok(());
        }
        for app in chosen {
            install_one(app, None, &prefix, no_path)?;
        }
        return Ok(());
    }
    for spec in specs {
        let (name, version) = parse_pkg(spec)?;
        let app = registry::find(name).ok_or_else(|| {
            anyhow::anyhow!(
                "unknown package: {name} (available: {})",
                registry::APPS
                    .iter()
                    .map(|a| a.name)
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;
        install_one(app, version, &prefix, no_path)?;
    }
    Ok(())
}

pub fn uninstall(specs: &[String], purge: bool) -> Result<()> {
    if specs.is_empty() {
        bail!("uninstall needs at least one package name");
    }
    for spec in specs {
        let (name, _) = parse_pkg(spec)?;
        let app = registry::find(name).ok_or_else(|| anyhow::anyhow!("unknown package: {name}"))?;
        let rec = receipt::load(name)?
            .ok_or_else(|| anyhow::anyhow!("{name} is not managed by mdrv-macos"))?;

        let mut removed = 0;
        for f in &rec.files {
            if f.exists() {
                std::fs::remove_file(f).with_context(|| format!("remove {}", f.display()))?;
                removed += 1;
            }
        }
        for block in &rec.rc_blocks {
            receipt::remove_rc_block(block)?;
        }
        let bin = bindir(&rec.prefix);
        if bin.is_dir() {
            let _ = std::fs::remove_dir(&bin); // only succeeds when empty
        }
        receipt::delete(name)?;

        ui::info(&format!(
            "{name} {} removed ({} files, rc blocks cleaned)",
            rec.version, removed
        ));

        if purge {
            if app.purge_paths.is_empty() {
                println!("    nothing to purge for {name}");
            } else if ui::confirm_dangerous(&format!("Also remove {} configuration/data?", name)) {
                let home = cache::home::home_dir().unwrap_or_else(|| PathBuf::from("/"));
                for p in app.purge_paths {
                    let target = home.join(p);
                    if target.is_dir() {
                        std::fs::remove_dir_all(&target)?;
                    } else if target.exists() {
                        std::fs::remove_file(&target)?;
                    }
                }
                ui::info("purged configuration/data");
            }
        }
    }
    Ok(())
}

/// A configurable aspect of a package, offered interactively by `configure`.
struct Action {
    id: &'static str,
    label: String,
}

fn actions(app: &App) -> Vec<Action> {
    match app.name {
        "nushell" => vec![
            Action {
                id: "set-login-shell",
                label: "Set as login shell".into(),
            },
            Action {
                id: "revert-login-shell",
                label: "Revert login shell to the previous one".into(),
            },
        ],
        _ => vec![],
    }
}

pub fn configure(pkg: &str, action: Option<&str>) -> Result<()> {
    let app = registry::find(pkg).ok_or_else(|| anyhow::anyhow!("unknown package: {pkg}"))?;
    let acts = actions(app);
    let chosen: Option<&Action> = match action {
        Some(id) => Some(acts.iter().find(|a| a.id == id).ok_or_else(|| {
            anyhow::anyhow!(
                "unknown action {id:?} for {pkg} (available: {})",
                acts.iter().map(|a| a.id).collect::<Vec<_>>().join(", ")
            )
        })?),
        None if acts.is_empty() => {
            ui::info(&format!("nothing to configure for {pkg}"));
            None
        }
        None if !ui::is_interactive() => {
            println!(
                "configure actions for {pkg}: {}",
                acts.iter().map(|a| a.id).collect::<Vec<_>>().join(", ")
            );
            bail!("pass an action when not attached to a terminal: mdrv-macos configure {pkg} <action>")
        }
        None => {
            let labels: Vec<String> = acts.iter().map(|a| a.label.clone()).collect();
            let picked = inquire::Select::new(&format!("Configure {pkg}:"), labels)
                .prompt_skippable()
                .map_err(|e| anyhow::anyhow!("selection cancelled: {e}"))?;
            picked.and_then(|l| acts.iter().find(|a| a.label == l))
        }
    };
    let Some(a) = chosen else {
        return Ok(());
    };

    let rec = receipt::load(pkg)?;
    let prefix = rec
        .as_ref()
        .map(|r| r.prefix.clone())
        .unwrap_or_else(default_prefix);
    match a.id {
        "set-login-shell" => set_login_shell(&prefix, rec)?,
        "revert-login-shell" => revert_login_shell(rec)?,
        _ => unreachable!(),
    }
    Ok(())
}

/// The login shell recorded in Directory Services for the current user.
fn current_login_shell() -> Result<String> {
    let user = std::env::var("USER").unwrap_or_default();
    let out = std::process::Command::new("dscl")
        .args([".", "-read", &format!("/Users/{user}"), "UserShell"])
        .output()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok(text
        .strip_prefix("UserShell: ")
        .unwrap_or(&text)
        .trim()
        .to_string())
}

/// Register nu in /etc/shells and set it as the login shell, transparently
/// handing the terminal to sudo/chsh for their prompts. The previous shell is
/// recorded in the receipt so `revert-login-shell` can restore it.
fn set_login_shell(prefix: &Path, rec: Option<Receipt>) -> Result<()> {
    let nu = bindir(prefix).join("nu");
    if !nu.exists() {
        bail!("nu not found at {}", nu.display());
    }
    let nu = nu.canonicalize().unwrap_or(nu);
    let current = current_login_shell()?;
    if Path::new(&current) == nu {
        ui::info(&format!("login shell already {nu:?}"));
        return Ok(());
    }
    let shells = std::fs::read_to_string("/etc/shells").unwrap_or_default();
    let registered = shells.lines().any(|l| l.trim() == nu.to_string_lossy());
    if !registered {
        if !ui::confirm(&format!("Register {nu:?} in /etc/shells (needs sudo)?")) {
            println!("    cancelled — add it manually: echo {nu:?} | sudo tee -a /etc/shells");
            return Ok(());
        }
        let status = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!(
                "printf '%s\\n' '{}' | sudo tee -a /etc/shells >/dev/null",
                nu.display()
            ))
            .status()?;
        if !status.success() {
            bail!("could not write /etc/shells");
        }
    }
    if !ui::confirm(&format!("Set the login shell to {nu:?} (runs chsh)?")) {
        return Ok(());
    }
    // Record the previous shell (once) so it can be restored later.
    let mut rec = rec.ok_or_else(|| {
        anyhow::anyhow!(
            "{nu:?} was not installed via mdrv-macos — no receipt to record the previous shell in"
        )
    })?;
    if rec.previous_shell.is_none() {
        rec.previous_shell = Some(current);
        receipt::save(&rec)?;
    }
    let status = std::process::Command::new("chsh")
        .arg("-s")
        .arg(&nu)
        .status()?;
    if status.success() {
        ui::info(&format!(
            "login shell set to {nu:?} — log out and back in (revert: mdrv-macos configure nushell revert-login-shell)"
        ));
    } else {
        bail!("chsh failed");
    }
    Ok(())
}

/// Restore the login shell captured before `set-login-shell` changed it.
fn revert_login_shell(rec: Option<Receipt>) -> Result<()> {
    let Some(mut rec) = rec else {
        bail!("no receipt — this package was not installed via mdrv-macos");
    };
    let Some(prev) = rec.previous_shell.clone() else {
        ui::warn("no previous shell recorded — nothing was changed via mdrv-macos");
        println!("    set one manually with: chsh -s /bin/zsh");
        return Ok(());
    };
    if !ui::confirm(&format!(
        "Set the login shell back to {prev:?} (runs chsh)?"
    )) {
        return Ok(());
    }
    let status = std::process::Command::new("chsh")
        .arg("-s")
        .arg(&prev)
        .status()?;
    if status.success() {
        rec.previous_shell = None;
        receipt::save(&rec)?;
        ui::info(&format!(
            "login shell reverted to {prev:?} — log out and back in"
        ));
    } else {
        bail!("chsh failed");
    }
    Ok(())
}

/// Latest upstream version of an app, honouring its source.
fn latest_version(app: &App) -> Result<String> {
    match app.source {
        Source::GitHub => {
            let rel = gh::fetch(app.repo, app.tag_prefix, None)?;
            Ok(rel.version(app.tag_prefix))
        }
        Source::Nodejs => gh::fetch_node(None),
    }
}

pub fn upgrade(specs: &[String]) -> Result<()> {
    let receipts = receipt::all()?;
    if receipts.is_empty() {
        ui::warn("nothing managed is installed yet");
        return Ok(());
    }
    let mut outdated: Vec<(&App, &Receipt, String)> = Vec::new();
    for rec in &receipts {
        if !specs.is_empty()
            && !specs
                .iter()
                .any(|s| parse_pkg(s).map(|(n, _)| n == rec.name).unwrap_or(false))
        {
            continue;
        }
        let Some(app) = registry::find(&rec.name) else {
            continue;
        };
        let latest = latest_version(app)?;
        if latest != rec.version {
            outdated.push((app, rec, latest));
        } else {
            println!("    {} {} — up to date", rec.name, rec.version);
        }
    }
    if outdated.is_empty() {
        ui::info("everything up to date");
        return Ok(());
    }
    for (app, rec, latest) in &outdated {
        println!(
            "    {} {} → {}",
            app.name,
            style_fmt(&rec.version),
            console::style(latest).green()
        );
    }
    if !ui::confirm(&format!("Upgrade {} package(s)?", outdated.len())) {
        return Ok(());
    }
    for (app, rec, _) in outdated {
        install_one(app, None, &rec.prefix, true)?;
    }
    Ok(())
}

pub fn list() -> Result<()> {
    let receipts = receipt::all()?;
    println!("{:<12} {:<10} {:<6} files", "PACKAGE", "VERSION", "SOURCE");
    for app in registry::APPS {
        match receipts.iter().find(|r| r.name == app.name) {
            Some(r) => println!(
                "{:<12} {:<10} {:<6} {}",
                app.name,
                r.version,
                "mdrv",
                r.files.len()
            ),
            None => println!("{:<12} {:<10} {:<6}", app.name, "-", "-"),
        }
    }
    for r in receipts
        .iter()
        .filter(|r| registry::find(&r.name).is_none())
    {
        println!(
            "{:<12} {:<10} {:<6} {}",
            r.name,
            r.version,
            "mdrv?",
            r.files.len()
        );
    }
    Ok(())
}

fn fmt_time(epoch: u64) -> String {
    jiff::Timestamp::from_second(epoch as i64)
        .map(|t| t.to_string())
        .unwrap_or_else(|_| epoch.to_string())
}

pub fn info(spec: &str) -> Result<()> {
    let (name, _) = parse_pkg(spec)?;
    let app = registry::find(name).ok_or_else(|| anyhow::anyhow!("unknown package: {name}"))?;
    let arch = (app.arch_token)(&registry::uname_m()?)?;
    let r = resolve(app, None, arch)?;
    println!("package:   {}", app.name);
    println!("summary:   {}", app.summary);
    println!("upstream:  {}", r.upstream);
    println!("latest:    {}", r.version);
    println!("asset:     {}", r.asset);
    if let Some(d) = &r.digest {
        println!("digest:    sha256:{d}");
    }
    match receipt::load(name)? {
        Some(r) => {
            println!("installed: {} at {}", r.version, fmt_time(r.installed_at));
            println!("prefix:    {}", r.prefix.display());
            println!(
                "files:     {}",
                r.files
                    .iter()
                    .map(|f| f.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        None => println!("installed: no"),
    }
    Ok(())
}

pub fn cache_list() -> Result<()> {
    let d = cache::dir();
    if !d.exists() {
        println!("cache is empty ({})", d.display());
        return Ok(());
    }
    let mut total: u64 = 0;
    let mut entries: Vec<_> = std::fs::read_dir(&d)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .collect();
    entries.sort();
    for p in entries {
        let size = p.metadata().map(|m| m.len()).unwrap_or(0);
        total += size;
        println!("{:>10}  {}", human(size), p.display());
    }
    println!("{}  total", human(total));
    Ok(())
}

fn human(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 20 => format!("{:.1} MiB", b as f64 / (1 << 20) as f64),
        b if b >= 1 << 10 => format!("{:.1} KiB", b as f64 / (1 << 10) as f64),
        b => format!("{b} B"),
    }
}

pub fn cache_clean() -> Result<()> {
    let d = cache::dir();
    if !d.exists() {
        return Ok(());
    }
    let mut n = 0;
    for e in std::fs::read_dir(&d)?.filter_map(|e| e.ok()) {
        if e.path().is_file() {
            std::fs::remove_file(e.path())?;
            n += 1;
        }
    }
    ui::info(&format!(
        "removed {n} cached artifact(s) from {}",
        d.display()
    ));
    Ok(())
}

pub fn self_update() -> Result<()> {
    let exe = std::env::current_exe().context("could not locate own binary")?;
    let target = (registry::arch_triple)(&registry::uname_m()?)?;
    let rel = gh::fetch("mdrv/macos", "v", None)?;
    let asset = format!("mdrv-macos-{}-{target}.tar.gz", rel.tag_name);
    let Some(digest) = rel.digest(&asset) else {
        bail!("release {} has no asset {asset}", rel.tag_name);
    };
    let url = format!(
        "https://github.com/mdrv/macos/releases/download/{}/{}",
        rel.tag_name, asset
    );
    ui::info(&format!("updating to {}", rel.tag_name));
    let file = cache::ensure(&asset, &url, Some(digest.trim_start_matches("sha256:")))?;

    let tmp = tempfile::TempDir::new()?;
    let status = std::process::Command::new("tar")
        .args(["-xzf"])
        .arg(&file)
        .arg("-C")
        .arg(tmp.path())
        .status()?;
    if !status.success() {
        bail!("extraction failed");
    }
    let new_bin = tmp.path().join("mdrv-macos").join("mdrv-macos");
    if !new_bin.exists() {
        bail!("unexpected archive layout (mdrv-macos/mdrv-macos not found)");
    }
    let staging = exe.with_extension("new");
    std::fs::copy(&new_bin, &staging)?;
    std::fs::rename(&staging, &exe)?;
    ui::info(&format!("updated {} → {}", exe.display(), rel.tag_name));
    Ok(())
}

fn interactive_select() -> Result<Vec<&'static App>> {
    if !ui::is_interactive() {
        println!(
            "available packages: {}",
            registry::APPS
                .iter()
                .map(|a| a.name)
                .collect::<Vec<_>>()
                .join(", ")
        );
        bail!("no packages given (run `mdrv-macos install <pkg>` in a terminal for an interactive picker)");
    }
    let receipts = receipt::all()?;
    let options: Vec<String> = registry::APPS
        .iter()
        .map(|a| {
            let installed = receipts
                .iter()
                .find(|r| r.name == a.name)
                .map(|r| format!(" — installed {}", r.version))
                .unwrap_or_default();
            format!("{}{}  {}", a.name, installed, a.summary)
        })
        .collect();
    let defaults: Vec<usize> = registry::APPS
        .iter()
        .enumerate()
        .filter(|(_, a)| !receipts.iter().any(|r| r.name == a.name))
        .map(|(i, _)| i)
        .collect();
    let picked = inquire::MultiSelect::new("Install which packages?", options)
        .with_default(&defaults)
        .with_page_size(10)
        .prompt()
        .map_err(|e| anyhow::anyhow!("selection cancelled: {e}"))?;
    Ok(picked
        .into_iter()
        .filter_map(|s| {
            let name = s.split("  ").next()?.trim();
            registry::find(name)
        })
        .collect())
}
