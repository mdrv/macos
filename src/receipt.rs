//! Install receipts: what a package installed, where, and which rc-file
//! blocks belong to it. `uninstall` removes exactly this.

use crate::cache;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub fn dir() -> PathBuf {
    if let Ok(d) = std::env::var("MDRV_STATE_DIR") {
        return PathBuf::from(d);
    }
    cache::home::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join(".local/state/mdrv-macos")
}

#[derive(Serialize, Deserialize, Clone)]
pub struct RcBlock {
    pub file: PathBuf,
    /// Comment line introducing the block, e.g. "# Added by mdrv-macos".
    pub marker: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Receipt {
    pub name: String,
    pub version: String,
    pub asset: String,
    pub sha256: Option<String>,
    /// Unix epoch seconds.
    pub installed_at: u64,
    /// Install root the script was given (`--prefix`).
    pub prefix: PathBuf,
    pub files: Vec<PathBuf>,
    pub rc_blocks: Vec<RcBlock>,
}

pub fn path(name: &str) -> PathBuf {
    dir().join(format!("{name}.json"))
}

pub fn load(name: &str) -> Result<Option<Receipt>> {
    let p = path(name);
    if !p.exists() {
        return Ok(None);
    }
    let text =
        std::fs::read_to_string(&p).with_context(|| format!("read receipt {}", p.display()))?;
    Ok(Some(serde_json::from_str(&text)?))
}

pub fn save(receipt: &Receipt) -> Result<()> {
    let d = dir();
    std::fs::create_dir_all(&d)?;
    let p = path(&receipt.name);
    std::fs::write(&p, serde_json::to_string_pretty(receipt)?)
        .with_context(|| format!("write receipt {}", p.display()))?;
    Ok(())
}

pub fn delete(name: &str) -> Result<()> {
    let p = path(name);
    if p.exists() {
        std::fs::remove_file(p)?;
    }
    Ok(())
}

pub fn all() -> Result<Vec<Receipt>> {
    let mut out = Vec::new();
    let d = dir();
    if !d.exists() {
        return Ok(out);
    }
    let mut entries: Vec<_> = std::fs::read_dir(&d)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    entries.sort();
    for p in entries {
        let text = std::fs::read_to_string(&p)?;
        if let Ok(r) = serde_json::from_str::<Receipt>(&text) {
            out.push(r);
        }
    }
    Ok(out)
}

/// Remove a rc-file block: the marker line plus every line after it up to
/// (excluding) the next non-empty line that is not part of the block. Our
/// blocks are the marker followed by one `export PATH=...` line.
pub fn remove_rc_block(block: &RcBlock) -> Result<bool> {
    if !block.file.exists() {
        return Ok(false);
    }
    let text = std::fs::read_to_string(&block.file)?;
    let mut lines: Vec<String> = Vec::new();
    let mut skipping = false;
    let mut removed = false;
    for line in text.lines() {
        if line.trim() == block.marker {
            skipping = true;
            removed = true;
            continue;
        }
        if skipping {
            if line.trim_start().starts_with("export ") {
                continue; // still inside the block
            }
            skipping = false;
        }
        lines.push(line.to_string());
    }
    if removed {
        std::fs::write(&block.file, format!("{}\n", lines.join("\n")))?;
    }
    Ok(removed)
}
