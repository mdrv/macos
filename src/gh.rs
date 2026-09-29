//! GitHub release resolution over the REST API (fetched through `curl`,
//! keeping the tool's transport dependency identical to the installer
//! scripts: curl + system TLS).

use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Deserialize)]
pub struct Asset {
    pub name: String,
    pub digest: Option<String>,
}

#[derive(Deserialize)]
pub struct Release {
    pub tag_name: String,
    pub assets: Vec<Asset>,
}

fn curl_json(url: &str) -> Result<String> {
    let out = std::process::Command::new("curl")
        .args(["-fsSL", url])
        .output()
        .context("could not run curl")?;
    if !out.status.success() {
        anyhow::bail!(
            "GitHub API request failed ({url}): {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Fetch a release: pinned (`tags/<prefix><version>`) or latest.
pub fn fetch(repo: &str, tag_prefix: &str, version: Option<&str>) -> Result<Release> {
    let url = match version {
        Some(v) => format!("https://api.github.com/repos/{repo}/releases/tags/{tag_prefix}{v}"),
        None => format!("https://api.github.com/repos/{repo}/releases/latest"),
    };
    let body = curl_json(&url)?;
    let rel: Release =
        serde_json::from_str(&body).context("could not parse GitHub API response")?;
    Ok(rel)
}

impl Release {
    /// Version without the tag prefix.
    pub fn version(&self, tag_prefix: &str) -> String {
        self.tag_name
            .strip_prefix(tag_prefix)
            .unwrap_or(&self.tag_name)
            .to_string()
    }

    /// `sha256:<hex>` digest of an asset, if GitHub publishes one.
    pub fn digest(&self, asset: &str) -> Option<String> {
        self.assets
            .iter()
            .find(|a| a.name == asset)
            .and_then(|a| a.digest.clone())
    }
}
