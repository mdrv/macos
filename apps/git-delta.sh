#!/bin/sh
# apps/git-delta.sh — install prebuilt git-delta (pager) on macOS in one command.
# Part of https://github.com/mdrv/macos
#
# Downloads the official release tarball from GitHub, verifies its sha256
# against GitHub's per-asset digest (when published), and installs the delta
# binary into ~/.local/bin.
#
# Intel note: upstream stopped shipping x86_64-apple-darwin tarballs after
# 0.18.2. On Intel Macs this script pins to 0.18.2 (the last dual-arch
# release) unless you pass an explicit --version. If you need a newer delta
# on an Intel Mac, conda-forge publishes osx-64 builds of every release
# (e.g. via micromamba: `micromamba create -p ~/mm/delta -c conda-forge git-delta`).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/git-delta.sh | sh
#   sh git-delta.sh [--version X.Y.Z] [--prefix DIR] [--no-path]
#
# Env: DELTA_VERSION (pin a release, e.g. 0.18.2), DELTA_PREFIX.
# Upgrade any time by running it again.

set -eu

REPO="dandavison/delta"
REPO_URL="https://github.com/$REPO"
API_URL="https://api.github.com/repos/$REPO"
# Last release that shipped an x86_64-apple-darwin tarball (0.19.1+ is arm64-only).
LAST_INTEL_VERSION="0.18.2"

TMP=""

cleanup() {
	[ -n "$TMP" ] && rm -rf -- "$TMP"
	return 0
}
trap cleanup EXIT INT TERM

usage() {
	cat <<'EOF'
git-delta.sh — install prebuilt git-delta on macOS (no compilation)

Usage:
  curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/git-delta.sh | sh
  sh git-delta.sh [options]

Options:
  --version X.Y.Z   install a specific release (default: latest; Intel Macs
                    fall back to 0.18.2, the last release with x86_64 builds)
  --prefix DIR      install under DIR/bin (default: ~/.local)
  --no-path         do not offer to add the binary dir to ~/.zshrc
  -h, --help        show this help

Environment:
  DELTA_VERSION     same as --version
  DELTA_PREFIX      same as --prefix
EOF
}

info() { printf '==> %s\n' "$1"; }
err() { printf 'delta: error: %s\n' "$1" >&2; exit 1; }

VERSION="${DELTA_VERSION:-}"
PREFIX="${DELTA_PREFIX:-$HOME/.local}"
ADD_PATH=1

while [ $# -gt 0 ]; do
	case "$1" in
		--version)
			[ $# -ge 2 ] || err "--version needs a value"
			VERSION="$2"
			shift 2
			;;
		--version=*)
			VERSION="${1#--version=}"
			shift
			;;
		--prefix)
			[ $# -ge 2 ] || err "--prefix needs a value"
			PREFIX="$2"
			shift 2
			;;
		--prefix=*)
			PREFIX="${1#--prefix=}"
			shift
			;;
		--no-path)
			ADD_PATH=0
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			err "unknown option: $1 (try --help)"
			;;
	esac
done

[ "$(uname -s)" = "Darwin" ] || err "this script supports macOS only"
case "$(uname -m)" in
	arm64) TARGET="aarch64-apple-darwin" ;;
	x86_64) TARGET="x86_64-apple-darwin" ;;
	*) err "unsupported architecture: $(uname -m)" ;;
esac
command -v curl >/dev/null 2>&1 || err "curl is required"
command -v shasum >/dev/null 2>&1 || err "shasum is required"

# delta tags carry no v prefix (0.18.2); accept pinned input with or without it.
VERSION=${VERSION#v}

fetch_release() {
	# $1: tag (empty = latest). Sets RELEASE_JSON.
	if [ -n "$1" ]; then
		info "resolving release $1"
	else
		info "resolving latest git-delta release"
	fi
	RELEASE_JSON=$(curl -fsSL "${API_URL}/releases/${1:+tags/}$1") || err "could not fetch release info from the GitHub API (release '$1' may not exist, or the API rate limit was hit — try again later)"
}

if [ -n "$VERSION" ]; then
	fetch_release "$VERSION"
else
	fetch_release ""
	if [ "$TARGET" = "x86_64-apple-darwin" ]; then
		case "$RELEASE_JSON" in
			*"x86_64-apple-darwin.tar.gz"*) ;;
			*)
				info "upstream stopped shipping Intel builds after $LAST_INTEL_VERSION — pinning to it"
				VERSION="$LAST_INTEL_VERSION"
				fetch_release "$VERSION"
				;;
		esac
	fi
fi

if [ -z "$VERSION" ]; then
	VERSION=$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
	[ -n "$VERSION" ] || err "could not determine the latest release (pin one with --version X.Y.Z)"
fi

ASSET="delta-$VERSION-$TARGET.tar.gz"
URL="$REPO_URL/releases/download/$VERSION/$ASSET"
SRCDIR="delta-$VERSION-$TARGET"
BINDIR="$PREFIX/bin"

OLD_VERSION=""
if [ -x "$BINDIR/delta" ]; then
	OLD_VERSION=$("$BINDIR/delta" --version 2>/dev/null | head -n 1 || true)
fi

TMP=$(mktemp -d)
TARBALL="$TMP/$ASSET"

info "downloading $ASSET"
curl -fsSL "$URL" -o "$TARBALL" || err "download failed: $URL"

DIGEST=$(printf '%s\n' "$RELEASE_JSON" | awk -v asset="\"name\": \"$ASSET\"" '
	# Scan the whole JSON: exiting early would SIGPIPE the feeding printf on
	# releases whose target asset sits past the 64 KiB pipe buffer.
	index($0, asset) { found = 1; next }
	found && /"digest":/ && dig == "" { sub(/^.*"digest": *"/, ""); sub(/".*$/, ""); dig = $0 }
	END { print dig }
')
if [ -n "$DIGEST" ]; then
	info "verifying sha256 ($DIGEST)"
	printf '%s  %s\n' "${DIGEST#sha256:}" "$TARBALL" | shasum -a 256 -c - >/dev/null 2>&1 ||
		err "checksum mismatch — the download is corrupted or was tampered with"
else
	info "no digest published for this asset — skipping checksum verification"
fi

info "extracting"
tar -xzf "$TARBALL" -C "$TMP" || err "extraction failed"
# Archive layout: delta-<ver>-<triple>/{delta,LICENSE,README.md}
[ -f "$TMP/$SRCDIR/delta" ] || err "unexpected archive layout (delta not found)"

mkdir -p "$BINDIR" 2>/dev/null || err "cannot create $BINDIR (use --prefix or run under sudo)"
info "installing into $BINDIR"
install -m 0755 "$TMP/$SRCDIR/delta" "$BINDIR/delta" || err "could not write to $BINDIR (use --prefix or run under sudo)"

NEW_VERSION=$("$BINDIR/delta" --version 2>/dev/null | head -n 1)

# PATH: only relevant when the bin dir is not already on PATH. Offers to
# append an export line to ~/.zshrc when running interactively; otherwise
# prints the instructions. Never touches rc files without an answer.
on_path=0
case ":$PATH:" in
	*":$BINDIR:"*) on_path=1 ;;
esac
path_action="already-on-path"
if [ "$on_path" = 0 ]; then
	path_action="manual"
	if [ "$ADD_PATH" = 1 ] && [ -t 0 ] && [ -t 1 ]; then
		if [ -f "$HOME/.zshrc" ] && grep -qF "$BINDIR" "$HOME/.zshrc"; then
			path_action="already-in-zshrc"
		else
			printf '\n%s is not on your PATH.\nAdd it to ~/.zshrc? [y/N] ' "$BINDIR"
			read -r answer || answer=""
			case "$answer" in
				y | Y | yes | Yes | YES)
					# shellcheck disable=SC2016 # literal $PATH must end up in the rc file
					printf '\n# Added by mdriv/macos git-delta installer\nexport PATH="%s:$PATH"\n' "$BINDIR" >>"$HOME/.zshrc"
					path_action="added"
					;;
			esac
		fi
	fi
fi

printf '\n'
info "$NEW_VERSION installed in $BINDIR"
if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
	info "upgraded from $OLD_VERSION"
fi
case "$path_action" in
	already-on-path | already-in-zshrc | added)
		if [ "$path_action" = "added" ]; then
			printf '    PATH updated in ~/.zshrc — open a new terminal, then run:  delta --version\n'
		else
			printf '    Run it with:  delta --version\n'
		fi
		;;
	manual)
		# shellcheck disable=SC2016 # literal $PATH must end up in the rc file
		printf '    Add delta to your PATH by putting this in ~/.zshrc:\n        export PATH="%s:$PATH"\n    Then run it with:  delta --version\n' "$BINDIR"
		;;
esac
printf '    Wire it into git (run as your user):\n'
printf '        git config --global core.pager delta\n'
printf '        git config --global interactive.diffFilter "delta --color-only"\n'
printf '        git config --global delta.navigate true\n'
printf '        git config --global merge.conflictstyle zdiff3\n'
printf '    Intel Macs are pinned to %s until upstream ships x86_64 again\n' "$LAST_INTEL_VERSION"
printf '    (newer Intel builds: conda-forge osx-64, e.g. via micromamba)\n'
printf '    Upgrade:   run this script again\n'
