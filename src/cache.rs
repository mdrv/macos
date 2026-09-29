//! Artifact cache: `~/.cache/mdrv-macos/pkg/<asset>` — downloads land here
//! once and are reused on reinstall/downgrade without touching the network.

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

pub fn dir() -> PathBuf {
    if let Ok(d) = std::env::var("MDRV_CACHE_DIR") {
        return PathBuf::from(d);
    }
    home::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join(".cache/mdrv-macos/pkg")
}

pub(crate) mod home {
    use std::path::PathBuf;

    pub fn home_dir() -> Option<PathBuf> {
        std::env::var_os("HOME")
            .filter(|h| !h.is_empty())
            .map(PathBuf::from)
    }
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path).with_context(|| format!("open {}", path.display()))?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;
    Ok(hex::encode(hasher.finalize()))
}

fn download(url: &str, dest: &Path) -> Result<()> {
    let out = std::process::Command::new("curl")
        .args(["-fsSL", url, "-o"])
        .arg(dest)
        .status()
        .context("could not run curl")?;
    if !out.success() {
        anyhow::bail!("download failed: {url}");
    }
    Ok(())
}

/// Return a cached, checksum-verified copy of `asset_name`, downloading it
/// from `url` when missing or corrupted. `expected_sha256` is the bare hex
/// digest (no `sha256:` prefix); when `None` the download is not verifiable
/// and is trusted as-is.
pub fn ensure(asset_name: &str, url: &str, expected_sha256: Option<&str>) -> Result<PathBuf> {
    let dir = dir();
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let target = dir.join(asset_name);

    if target.exists() {
        match expected_sha256 {
            Some(hex) => {
                if sha256_file(&target)? == hex {
                    return Ok(target);
                }
                eprintln!("    cache entry corrupted, re-downloading {asset_name}");
                let _ = std::fs::remove_file(&target);
            }
            None => return Ok(target),
        }
    }

    let tmp = tempfile::NamedTempFile::new_in(&dir)?;
    download(url, tmp.path())?;
    if let Some(hex) = expected_sha256 {
        let actual = sha256_file(tmp.path())?;
        if actual != hex {
            anyhow::bail!("checksum mismatch — the download is corrupted or was tampered with");
        }
    }
    tmp.persist(&target)
        .with_context(|| format!("persist {}", target.display()))?;
    Ok(target)
}
