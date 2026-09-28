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

## Options

Every script takes the same options (substitute the tool's env prefix):

```sh
sh nushell.sh --version 0.116.0      # pin a release instead of latest
sh nushell.sh --prefix ~/.nushell    # install under DIR/bin instead of ~/.local/bin
sh nushell.sh --no-path              # skip the ~/.zshrc offer
sh nushell.sh --help
```

| Flag | Env (nushell / fastfetch) | Effect |
| --- | --- | --- |
| `--version X` | `NU_VERSION` / `FASTFETCH_VERSION` | pin a release |
| `--prefix DIR` | `NU_PREFIX` / `FASTFETCH_PREFIX` | install root (binaries land in `DIR/bin`) |
| `--no-path` | — | skip the PATH offer |

Upgrading is just running the script again.

## Design notes

- **Scripts are intentionally self-contained** — each one is a single file
  with no shared library, so it can be fetched and piped with one `curl`.
  Duplicated boilerplate between scripts is accepted for that property.
- Only official release archives are used, and checksums are always
  verified against GitHub's asset digests.
- Other platforms are out of scope here: Nushell has
  [mdrv/nui](https://github.com/mdrv/nui) (macOS & Linux), Windows tools
  have `winget`/`scoop`, and Linux has distro packages.

## Adding a script

Copy `apps/fastfetch.sh` (the smaller one), then change: the `REPO` /
env-prefix block at the top, the architecture → asset-name mapping, the
expected archive layout, and the list of binaries to install + final
hints. Run `sh -n` and `shellcheck` on it; CI enforces both.

## License

GPL-3.0 — see [LICENSE](LICENSE).
