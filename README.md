# macos

One-command installers for CLI tools on macOS, built on **official GitHub
release binaries** — no Homebrew, no compilation, no waiting on source
builds. Every script:

1. detects your Mac's architecture (Apple silicon / Intel)
2. resolves the latest release from GitHub (or the one you pin)
3. downloads the official archive and **verifies its sha256** against
   GitHub's per-asset digest
4. installs the binaries into `~/.local/bin`
5. offers to add `~/.local/bin` to your `PATH` in `~/.zshrc` (asks first;
   when piped non-interactively it prints the line to add instead)

## Available scripts

| Tool | Install |
| --- | --- |
| [Nushell](https://www.nushell.sh) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/nushell.sh \| sh` |
| [fastfetch](https://github.com/fastfetch-cli/fastfetch) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/fastfetch.sh \| sh` |
| [fzf](https://github.com/junegunn/fzf) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/fzf.sh \| sh` |
| [carapace](https://carapace.sh) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/carapace.sh \| sh` |
| [unison](https://github.com/bcpierce00/unison) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/unison.sh \| sh` |
| [git-delta](https://github.com/dandavison/delta) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/git-delta.sh \| sh` |
| [tree-sitter CLI](https://github.com/tree-sitter/tree-sitter) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/tree-sitter-cli.sh \| sh` |
| [turso](https://github.com/tursodatabase/turso) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/turso.sh \| sh` |
| [Node.js](https://nodejs.org) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/node.sh \| sh` |
| [fnm](https://github.com/Schniz/fnm) | `curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/fnm.sh \| sh` |

## Options

Every script takes the same options (substitute the tool's env prefix):

```sh
sh nushell.sh --version 0.116.0      # pin a release instead of latest
sh nushell.sh --prefix ~/.nushell    # install under DIR/bin instead of ~/.local/bin
sh nushell.sh --no-path              # skip the ~/.zshrc offer
sh nushell.sh --help
```

| Flag | Env (nushell / fastfetch / fzf / carapace / unison / git-delta / tree-sitter-cli / turso / node / fnm) | Effect |
| --- | --- | --- |
| `--version X` | `NU_VERSION` / `FASTFETCH_VERSION` / `FZF_VERSION` / `CARAPACE_VERSION` / `UNISON_VERSION` / `DELTA_VERSION` / `TREE_SITTER_VERSION` / `TURSO_VERSION` / `NODE_VERSION` / `FNM_VERSION` | pin a release |
| `--prefix DIR` | `NU_PREFIX` / `FASTFETCH_PREFIX` / `FZF_PREFIX` / `CARAPACE_PREFIX` / `UNISON_PREFIX` / `DELTA_PREFIX` / `TREE_SITTER_PREFIX` / `TURSO_PREFIX` / `NODE_PREFIX` / `FNM_PREFIX` | install root (binaries land in `DIR/bin`) |
| `--no-path` | — | skip the PATH offer |
| `--no-shell` | — | nushell only: skip the login-shell offer |

Upgrading is just running the script again.

## Design notes

- **Scripts are intentionally self-contained** — each one is a single file
  with no shared library, so it can be fetched and piped with one `curl`.
  Duplicated boilerplate between scripts is accepted for that property.
- Only official release archives are used, and checksums are always
  verified — against GitHub's per-asset digest, or the project's own
  checksum file when GitHub doesn't publish one (Node's `SHASUMS256.txt`).
- Other platforms are out of scope here: Nushell has
  [mdrv/nui](https://github.com/mdrv/nui) (macOS & Linux), Windows tools
  have `winget`/`scoop`, and Linux has distro packages.

## Adding a script

Copy `apps/fastfetch.sh` (the smaller one), then change: the `REPO` /
env-prefix block at the top, the architecture → asset-name mapping, the
expected archive layout, and the list of binaries to install + final
hints. Run `sh -n` and `shellcheck` on it; CI enforces both.

## mdrv-macos (the manager)

The installers above stay single-file and standalone, but `mdrv-macos`
 orchestrates them pacman-style:

```
curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/scripts/install.sh | sh
```

| Command | Behaviour |
| --- | --- |
| `mdrv-macos install [pkg[@ver]…]` (alias `add`) | install; bare → interactive multi-select (filter as you type) |
| `mdrv-macos uninstall <pkg>` (alias `remove`) | remove exactly the files + rc blocks recorded in the receipt; `--purge` also deletes app config (double confirmation) |
| `mdrv-macos configure <pkg> [action]` | interactive menu of configure actions (`set-login-shell`, `revert-login-shell` for nushell — the previous shell is recorded for revert); pass an action id for scripting |
| `mdrv-macos upgrade [pkg…]` | re-resolve latest upstream, reinstall what differs |
| `mdrv-macos list` / `info <pkg>` | installed packages / full detail incl. owned files |
| `mdrv-macos cache ls\|clean` | downloaded release archives (`~/.cache/mdrv-macos/pkg`), sha-keyed, reused across installs |
| `mdrv-macos self-update` | replace the manager binary from its own releases |

Design: the manager downloads and checksum-verifies each release asset into
the cache, then runs the **same embedded installer script** with
`MDRV_ASSET_FILE` + `MDRV_NO_DOWNLOAD` set — so `apps/*.sh` keep working
standalone via `curl | sh`, and every write is recorded in
`~/.local/state/mdrv-macos/<pkg>.json` for clean uninstalls.
Override points: `MDRV_CACHE_DIR`, `MDRV_STATE_DIR`, `MDRV_MACOS_PREFIX`.
Currently packaged: `nushell`, `fzf`, `fnm`, `fastfetch`, `carapace`,
`unison`, `git-delta`, `tree-sitter-cli`, `turso`, `node`.
Verification is per-source: GitHub's per-asset digests, or Node's
`SHASUMS256.txt`. Packages that dropped Intel builds (git-delta after
0.18.2) fall back to the last version that shipped one.

## License

GPL-3.0 — see [LICENSE](LICENSE).
