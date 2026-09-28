#!/bin/sh
# apps/nushell.sh — install prebuilt Nushell on macOS in one command.
# Part of https://github.com/mdrv/macos — adapted from https://github.com/mdrv/nui
#
# Downloads the official release tarball from GitHub, verifies its sha256
# against GitHub's per-asset digest, and installs `nu` plus the bundled
# plugins into ~/.local/bin.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/nushell.sh | sh
#   sh nushell.sh [--version X.Y.Z] [--prefix DIR] [--no-path]
#
# Env: NU_VERSION (pin a release, e.g. 0.116.0), NU_PREFIX.
# Upgrade any time by running it again.

set -eu

REPO="nushell/nushell"
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
nushell.sh — install prebuilt Nushell on macOS (no compilation)

Usage:
  curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/nushell.sh | sh
  sh nushell.sh [options]

Options:
  --version X.Y.Z   install a specific release (default: latest)
  --prefix DIR      install under DIR/bin (default: ~/.local)
  --no-path         do not offer to add the binary dir to ~/.zshrc
  -h, --help        show this help

Environment:
  NU_VERSION        same as --version
  NU_PREFIX         same as --prefix
EOF
}

info() { printf '==> %s\n' "$1"; }
err() { printf 'nushell: error: %s\n' "$1" >&2; exit 1; }

VERSION="${NU_VERSION:-}"
PREFIX="${NU_PREFIX:-$HOME/.local}"
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

# Resolve the release tag (latest or pinned) and remember the API response —
# it carries the per-asset sha256 digests used for verification below.
if [ -n "$VERSION" ]; then
	VERSION=${VERSION#v}
	API="$API_URL/releases/tags/$VERSION"
	info "resolving release $VERSION"
else
	API="$API_URL/releases/latest"
	info "resolving latest Nushell release"
fi
RELEASE_JSON=$(curl -fsSL "$API") || err "could not fetch release info from the GitHub API (release '$VERSION' may not exist, or the API rate limit was hit — try again later)"
if [ -z "$VERSION" ]; then
	VERSION=$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
	[ -n "$VERSION" ] || err "could not determine the latest release (pin one with --version X.Y.Z)"
fi

ASSET="nu-$VERSION-$TARGET.tar.gz"
URL="$REPO_URL/releases/download/$VERSION/$ASSET"
BINDIR="$PREFIX/bin"

OLD_VERSION=""
if [ -x "$BINDIR/nu" ]; then
	OLD_VERSION=$("$BINDIR/nu" --version 2>/dev/null || true)
fi

TMP=$(mktemp -d)
TARBALL="$TMP/$ASSET"

info "downloading $ASSET"
curl -fsSL "$URL" -o "$TARBALL" || err "download failed: $URL"

DIGEST=$(printf '%s\n' "$RELEASE_JSON" | awk -v asset="\"name\": \"$ASSET\"" '
	index($0, asset) { found = 1; next }
	found && /"digest":/ { sub(/^.*"digest": *"/, ""); sub(/".*$/, ""); print; exit }
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
SRC="$TMP/nu-$VERSION-$TARGET"
[ -d "$SRC" ] || err "unexpected archive layout (nu-$VERSION-$TARGET/ not found)"

mkdir -p "$BINDIR" 2>/dev/null || err "cannot create $BINDIR (use --prefix or run under sudo)"
info "installing into $BINDIR"
INSTALLED=0
for f in "$SRC"/nu*; do
	[ -x "$f" ] || continue
	install -m 0755 "$f" "$BINDIR/" || err "could not write to $BINDIR (use --prefix or run under sudo)"
	INSTALLED=$((INSTALLED + 1))
done
[ "$INSTALLED" -gt 0 ] || err "no nu binaries found in the archive"

NEW_VERSION=$("$BINDIR/nu" --version)

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
					printf '\n# Added by mdriv/macos nushell installer\nexport PATH="%s:$PATH"\n' "$BINDIR" >>"$HOME/.zshrc"
					path_action="added"
					;;
			esac
		fi
	fi
fi

printf '\n'
info "Nushell $NEW_VERSION installed ($INSTALLED binaries in $BINDIR)"
if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
	info "upgraded from $OLD_VERSION"
fi
case "$path_action" in
	already-on-path | already-in-zshrc | added)
		if [ "$path_action" = "added" ]; then
			printf '    PATH updated in ~/.zshrc — open a new terminal, then run:  nu\n'
		else
			printf '    Start it with:  nu\n'
		fi
		;;
	manual)
		# shellcheck disable=SC2016 # literal $PATH must end up in the rc file
		printf '    Add Nushell to your PATH by putting this in ~/.zshrc:\n        export PATH="%s:$PATH"\n    Then start it with:  nu\n' "$BINDIR"
		;;
esac
printf '    Docs:      https://www.nushell.sh/book/\n'
printf '    Upgrade:   run this script again\n'
