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

fn curl_text(url: &str) -> Result<String> {
    let out = std::process::Command::new("curl")
        .args(["-fsSL", url])
        .output()
        .context("could not run curl")?;
    if !out.status.success() {
        anyhow::bail!(
            "request failed ({url}): {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn curl_json(url: &str) -> Result<String> {
    curl_text(url)
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

/// Download URL for a GitHub release asset.
pub fn asset_url(repo: &str, tag: &str, asset: &str) -> String {
    format!("https://github.com/{repo}/releases/download/{tag}/{asset}")
}

/// Latest (or pinned) Node.js version from nodejs.org/dist. Returns "X.Y.Z".
pub fn fetch_node(version: Option<&str>) -> Result<String> {
    match version {
        Some(v) => Ok(v.trim_start_matches('v').to_string()),
        None => {
            let index = curl_text("https://nodejs.org/dist/index.json")?;
            let v = index
                .split("\"version\":\"v")
                .nth(1)
                .and_then(|rest| rest.split('"').next())
                .context("could not parse the nodejs.org dist index")?;
            Ok(v.to_string())
        }
    }
}

/// sha256 of a Node.js asset from its release SHASUMS256.txt.
pub fn node_digest(version: &str, asset: &str) -> Result<String> {
    let sums = curl_text(&format!(
        "https://nodejs.org/dist/v{version}/SHASUMS256.txt"
    ))?;
    let line = sums
        .lines()
        .find(|l| l.trim_end().ends_with(asset))
        .with_context(|| format!("no entry for {asset} in SHASUMS256.txt"))?;
    Ok(line
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_string())
}
