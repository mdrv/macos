#!/bin/sh
# apps/tree-sitter-cli.sh — install prebuilt tree-sitter CLI on macOS in one command.
# Part of https://github.com/mdrv/macos
#
# Downloads the official .gz release asset from GitHub (a single gzip'd
# binary), verifies its sha256 against GitHub's per-asset digest, and
# installs the tree-sitter binary into ~/.local/bin.
#
# The release also ships .zip variants with identical contents — the .gz is
# used because it needs nothing beyond the gzip macOS already has.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/tree-sitter-cli.sh | sh
#   sh tree-sitter-cli.sh [--version X.Y.Z] [--prefix DIR] [--no-path]
#
# Env: TREE_SITTER_VERSION (pin a release, e.g. 0.27.0), TREE_SITTER_PREFIX.
# Upgrade any time by running it again.

set -eu

REPO="tree-sitter/tree-sitter"
REPO_URL="https://github.com/$REPO"
API_URL="https://api.github.com/repos/$REPO"

TMP=""

cleanup() {
	[ -n "$TMP" ] && rm -rf -- "$TMP"
	return 0
}
trap cleanup EXIT INT TERM

usage() {
	cat <<'EOF'
tree-sitter-cli.sh — install prebuilt tree-sitter CLI on macOS (no compilation)

Usage:
  curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/tree-sitter-cli.sh | sh
  sh tree-sitter-cli.sh [options]

Options:
  --version X.Y.Z   install a specific release (default: latest)
  --prefix DIR      install under DIR/bin (default: ~/.local)
  --no-path         do not offer to add the binary dir to ~/.zshrc
  -h, --help        show this help

Environment:
  TREE_SITTER_VERSION    same as --version
  TREE_SITTER_PREFIX     same as --prefix
EOF
}

info() { printf '==> %s\n' "$1"; }
err() { printf 'tree-sitter: error: %s\n' "$1" >&2; exit 1; }

VERSION="${TREE_SITTER_VERSION:-}"
PREFIX="${TREE_SITTER_PREFIX:-$HOME/.local}"
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
	arm64) ARCH="arm64" ;;
	x86_64) ARCH="x64" ;;
	*) err "unsupported architecture: $(uname -m)" ;;
esac
command -v curl >/dev/null 2>&1 || err "curl is required"
command -v shasum >/dev/null 2>&1 || err "shasum is required"

# Tags carry a v prefix (v0.27.0) while asset names are version-free
# (tree-sitter-macos-x64.gz); accept pinned input with or without the v.
VERSION=${VERSION#v}

	# mdrv-macos contract: MDRV_VERSION/MDRV_ASSET_FILE skip resolution, download
	# and verification (the manager has already done both).
if [ -n "${MDRV_VERSION:-}" ]; then
	VERSION=${MDRV_VERSION#v}
else
	fetch_release() {
		# $1: tag (empty = latest). Sets RELEASE_JSON.
		if [ -n "$1" ]; then
			info "resolving release $1"
			URL_GH_API="${API_URL}/releases/tags/$1"
		else
			info "resolving latest tree-sitter release"
			URL_GH_API="${API_URL}/releases/latest"
		fi
		RELEASE_JSON=$(curl -fsSL "$URL_GH_API") || err "could not fetch release info from the GitHub API${1:+ (release $1 may not exist)}, or the API rate limit was hit — try again later"
	}

	if [ -n "$VERSION" ]; then
		fetch_release "v$VERSION"
	else
		fetch_release ""
	fi

	if [ -z "$VERSION" ]; then
		VERSION=$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)
		[ -n "$VERSION" ] || err "could not determine the latest release (pin one with --version X.Y.Z)"
	fi
fi

ASSET="tree-sitter-macos-$ARCH.gz"
URL="$REPO_URL/releases/download/v$VERSION/$ASSET"
GZNAME="tree-sitter-macos-$ARCH"
BINDIR="$PREFIX/bin"

OLD_VERSION=""
if [ -x "$BINDIR/tree-sitter" ]; then
	OLD_VERSION=$("$BINDIR/tree-sitter" --version 2>/dev/null | head -n 1 || true)
fi

TMP=$(mktemp -d)
TARBALL="$TMP/$ASSET"

if [ -n "${MDRV_ASSET_FILE:-}" ]; then
	info "installing from mdrv-macos verified cache: $(basename -- "$MDRV_ASSET_FILE")"
	cp -- "$MDRV_ASSET_FILE" "$TARBALL"
else
	info "downloading $ASSET"
	curl -fsSL "$URL" -o "$TARBALL" || err "download failed: $URL"

	DIGEST=$(printf '%s\n' "$RELEASE_JSON" | awk -v asset="\"name\": \"$ASSET\"" '
		# Scan the whole JSON: exiting early would SIGPIPE the feeding printf on
		# releases whose target asset sits past the 64 KiB pipe buffer. A later
		# "name" line ends the JSON object of this asset — without the reset
		# below, an asset with no digest would steal the next digest.
		/"name":/ { found = 0 }
		index($0, asset) { found = 1; next }
		found && dig == "" && /"digest": *"sha256:[0-9a-f]{64}"/ { sub(/^.*"digest": *"/, ""); sub(/".*$/, ""); dig = $0 }
		END { print dig }
	')
	if [ -n "$DIGEST" ]; then
		info "verifying sha256 ($DIGEST)"
		printf '%s  %s\n' "${DIGEST#sha256:}" "$TARBALL" | shasum -a 256 -c - >/dev/null 2>&1 ||
			err "checksum mismatch — the download is corrupted or was tampered with"
	else
		info "no digest published for this asset — skipping checksum verification"
	fi
fi

info "extracting"
gzip -d -c "$TARBALL" >"$TMP/$GZNAME" || err "extraction failed"
# Archive layout: a single gzip'd tree-sitter binary (no exec bit stored).
[ -f "$TMP/$GZNAME" ] || err "unexpected archive layout (binary not found)"

mkdir -p "$BINDIR" 2>/dev/null || err "cannot create $BINDIR (use --prefix or run under sudo)"
info "installing into $BINDIR"
install -m 0755 "$TMP/$GZNAME" "$BINDIR/tree-sitter" || err "could not write to $BINDIR (use --prefix or run under sudo)"

NEW_VERSION=$("$BINDIR/tree-sitter" --version 2>/dev/null | head -n 1)

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
					printf '\n# Added by mdriv/macos tree-sitter-cli installer\nexport PATH="%s:$PATH"\n' "$BINDIR" >>"$HOME/.zshrc"
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
			printf '    PATH updated in ~/.zshrc — open a new terminal, then run:  tree-sitter --version\n'
		else
			printf '    Run it with:  tree-sitter --version\n'
		fi
		;;
	manual)
		# shellcheck disable=SC2016 # literal $PATH must end up in the rc file
		printf '    Add tree-sitter to your PATH by putting this in ~/.zshrc:\n        export PATH="%s:$PATH"\n    Then run it with:  tree-sitter --version\n' "$BINDIR"
		;;
esac
printf '    First run:   tree-sitter init-config\n'
printf '    Parsers are built per project with:  tree-sitter generate / build\n'
printf '    Upgrade:   run this script again\n'
