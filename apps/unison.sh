#!/bin/sh
# apps/unison.sh — install prebuilt unison (file synchronizer) on macOS in one command.
# Part of https://github.com/mdrv/macos
#
# Downloads the official release tarball from GitHub, verifies its sha256
# against GitHub's per-asset digest, and installs the unison binary into
# ~/.local/bin (man page into ~/.local/share/man).
#
# For the GUI application, grab the Unison-*.app.tar.gz asset from the same
# release instead.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/unison.sh | sh
#   sh unison.sh [--version X.Y.Z] [--prefix DIR] [--no-path]
#
# Env: UNISON_VERSION (pin a release, e.g. 2.54.0), UNISON_PREFIX.
# Upgrade any time by running it again. Both ends of a sync must run
# compatible unison versions.

set -eu

REPO="bcpierce00/unison"
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
unison.sh — install prebuilt unison on macOS (no compilation)

Usage:
  curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/apps/unison.sh | sh
  sh unison.sh [options]

Options:
  --version X.Y.Z   install a specific release (default: latest)
  --prefix DIR      install under DIR/bin (default: ~/.local)
  --no-path         do not offer to add the binary dir to ~/.zshrc
  -h, --help        show this help

Environment:
  UNISON_VERSION    same as --version
  UNISON_PREFIX     same as --prefix
EOF
}

info() { printf '==> %s\n' "$1"; }
err() { printf 'unison: error: %s\n' "$1" >&2; exit 1; }

VERSION="${UNISON_VERSION:-}"
PREFIX="${UNISON_PREFIX:-$HOME/.local}"
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
	x86_64) ARCH="x86-64" ;;
	*) err "unsupported architecture: $(uname -m)" ;;
esac
command -v curl >/dev/null 2>&1 || err "curl is required"
command -v shasum >/dev/null 2>&1 || err "shasum is required"

# unison tags carry a v prefix (v2.54.0); accept pinned input with or without it.
VERSION=${VERSION#v}

# Resolve the release tag (latest or pinned) and remember the API response —
# it carries the per-asset sha256 digests used for verification below.
if [ -n "$VERSION" ]; then
	API="$API_URL/releases/tags/v$VERSION"
	info "resolving release v$VERSION"
else
	API="$API_URL/releases/latest"
	info "resolving latest unison release"
fi
RELEASE_JSON=$(curl -fsSL "$API") || err "could not fetch release info from the GitHub API (release '$VERSION' may not exist, or the API rate limit was hit — try again later)"
if [ -z "$VERSION" ]; then
	VERSION=$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)
	[ -n "$VERSION" ] || err "could not determine the latest release (pin one with --version X.Y.Z)"
fi

ASSET="unison-$VERSION-macos-$ARCH.tar.gz"
URL="$REPO_URL/releases/download/v$VERSION/$ASSET"
SRCDIR="unison-$VERSION-macos-$ARCH"
BINDIR="$PREFIX/bin"

OLD_VERSION=""
if [ -x "$BINDIR/unison" ]; then
	OLD_VERSION=$("$BINDIR/unison" -version 2>/dev/null | head -n 1 || true)
fi

TMP=$(mktemp -d)
TARBALL="$TMP/$ASSET"

info "downloading $ASSET"
curl -fsSL "$URL" -o "$TARBALL" || err "download failed: $URL"

DIGEST=$(printf '%s\n' "$RELEASE_JSON" | awk -v asset="\"name\": \"$ASSET\"" '
	# Scan the whole JSON: exiting early would SIGPIPE the feeding printf on
	# releases whose target asset sits past the 64 KiB pipe buffer.
	index($0, asset) { found = 1; next }
	# A later "name" line ends the JSON object of this asset — without the
	# reset below, an asset with no digest would steal the next digest.
	/"name":/ { found = 0 }
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

info "extracting"
tar -xzf "$TARBALL" -C "$TMP" || err "extraction failed"
# Archive layout: unison-<ver>-macos-<arch>/{bin/unison,man/unison.1,doc,...}
[ -f "$TMP/$SRCDIR/bin/unison" ] || err "unexpected archive layout (bin/unison not found)"

mkdir -p "$BINDIR" 2>/dev/null || err "cannot create $BINDIR (use --prefix or run under sudo)"
info "installing into $BINDIR"
install -m 0755 "$TMP/$SRCDIR/bin/unison" "$BINDIR/unison" || err "could not write to $BINDIR (use --prefix or run under sudo)"
MAN1DIR="$PREFIX/share/man/man1"
mkdir -p "$MAN1DIR" 2>/dev/null || true
if [ -f "$TMP/$SRCDIR/man/unison.1" ]; then
	install -m 0644 "$TMP/$SRCDIR/man/unison.1" "$MAN1DIR/unison.1"
fi

NEW_VERSION=$("$BINDIR/unison" -version 2>/dev/null | head -n 1)

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
					printf '\n# Added by mdriv/macos unison installer\nexport PATH="%s:$PATH"\n' "$BINDIR" >>"$HOME/.zshrc"
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
			printf '    PATH updated in ~/.zshrc — open a new terminal, then run:  unison\n'
		else
			printf '    Run it with:  unison\n'
		fi
		;;
	manual)
		# shellcheck disable=SC2016 # literal $PATH must end up in the rc file
		printf '    Add unison to your PATH by putting this in ~/.zshrc:\n        export PATH="%s:$PATH"\n    Then run it with:  unison\n' "$BINDIR"
		;;
esac
printf '    GUI app variant: download Unison-*.app.tar.gz from the same release\n        %s/releases/tag/v%s\n' "$REPO_URL" "$VERSION"
printf '    Both ends of a sync must run compatible unison versions.\n'
printf '    Upgrade:   run this script again\n'
