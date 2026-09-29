#!/bin/sh
# fnm — install prebuilt Fast Node Manager on macOS & Linux (no compilation).
#
# Downloads the official Schniz/fnm release zip, verifies it against the
# GitHub API per-asset sha256 digest, and installs the single `fnm` binary.
#
# Usage:
#   sh fnm.sh [--version X] [--prefix DIR] [--no-path]
#
# Environment (flags win): FNM_VERSION, FNM_PREFIX, FNM_ADD_PATH=0
#
# Repository: https://github.com/mdrv/macos

set -eu

REPO="Schniz/fnm"
REPO_URL="https://github.com/$REPO"
API_URL="https://api.github.com/repos/$REPO"
PREFIX="${FNM_PREFIX:-$HOME/.local}"
WANT_VERSION="${FNM_VERSION:-}"
ADD_PATH="${FNM_ADD_PATH:-1}"

usage() {
	cat <<'EOF'
fnm installer — prebuilt Fast Node Manager for macOS & Linux

Usage: sh fnm.sh [--version X] [--prefix DIR] [--no-path]

Flags:
  --version X   install a specific fnm version (e.g. 1.39.0 or v1.39.0);
                defaults to the latest GitHub release
  --prefix DIR  install root (default: ~/.local → ~/.local/bin/fnm)
  --no-path     skip the shell-rc PATH offer
  -h, --help    show this help

Environment:
  FNM_VERSION / FNM_PREFIX / FNM_ADD_PATH=0 — same as the flags above

After installing, get some Node:
  fnm install --lts && fnm default lts-latest

https://github.com/mdrv/macos
EOF
}

err() {
	printf 'fnm: error: %s\n' "$1" >&2
	exit 1
}
info() {
	printf '==> %s\n' "$1"
}

cleanup() {
	[ -n "${TMPD:-}" ] && rm -rf -- "$TMPD"
}
trap cleanup EXIT INT TERM

while [ $# -gt 0 ]; do
	case "$1" in
	--version)
		[ $# -ge 2 ] || err "--version requires an argument"
		WANT_VERSION="$2"
		shift 2
		;;
	--version=*)
		WANT_VERSION="${1#*=}"
		shift
		;;
	--prefix)
		[ $# -ge 2 ] || err "--prefix requires an argument"
		PREFIX="$2"
		shift 2
		;;
	--prefix=*)
		PREFIX="${1#*=}"
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
		usage >&2
		err "unknown option: $1"
		;;
	esac
done

command -v unzip >/dev/null 2>&1 || err "unzip is required (macOS ships it; on Linux: apt install unzip / pacman -S unzip)"

# --- resolve platform ------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
Darwin) ASSET="fnm-macos.zip" ;; # universal binary (x86_64 + arm64)
Linux)
	case "$ARCH" in
	x86_64 | amd64) ASSET="fnm-linux.zip" ;;
	arm64 | aarch64) ASSET="fnm-arm64.zip" ;;
	armv7l | armv8l) ASSET="fnm-arm32.zip" ;;
	*) err "unsupported architecture: $ARCH" ;;
	esac
	;;
*) err "unsupported OS: $OS (fnm ships darwin/linux zips; Windows: fnm-windows.zip)" ;;
esac

# --- resolve version -------------------------------------------------------
case "$WANT_VERSION" in
v*) WANT_VERSION="${WANT_VERSION#v}" ;;
esac
fetch_release() {
	if [ -n "${1:-}" ]; then
		URL_GH_API="$API_URL/releases/tags/v$1"
	else
		URL_GH_API="$API_URL/releases/latest" # skips prereleases
	fi
	curl -fsSL "$URL_GH_API" || err "could not fetch release info from the GitHub API${1:+ (release $1 may not exist)}"
}
info "resolving ${WANT_VERSION:+release $WANT_VERSION}${WANT_VERSION:-latest fnm release}"
RELEASE_JSON="$(fetch_release "$WANT_VERSION")"
VERSION="$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"v\([0-9][0-9.]*\)".*/\1/p' | head -n 1)"
[ -n "$VERSION" ] || err "could not determine the release tag"
ASSET_URL="$REPO_URL/releases/download/v$VERSION/$ASSET"

# --- download --------------------------------------------------------------
TMPD="$(mktemp -d)"
info "downloading $ASSET"
curl -fsSL "$ASSET_URL" -o "$TMPD/$ASSET" || err "download failed (asset $ASSET may not exist for release $VERSION)"

# --- verify ----------------------------------------------------------------
info "verifying sha256"
# scan only the JSON object of our asset: a later asset's "name" line ends the
# window, and only a full sha256:<64 hex> value is accepted
DIGEST="$(
	printf '%s\n' "$RELEASE_JSON" | awk -v asset="\"name\": \"$ASSET\"" '
		index($0, asset) { found = 1; next }
		/"name":/ { found = 0 }
		found && dig == "" && /"digest": *"sha256:[0-9a-f]{64}"/ { sub(/^.*"digest": *"/, ""); sub(/".*$/, ""); dig = $0 }
		END { print dig }
	'
)"
case "$DIGEST" in
sha256:[0-9a-f]*) ;;
*) info "no digest published for this asset — skipping verification" ;;
esac
if [ -n "$DIGEST" ]; then
	ACTUAL="$(/usr/bin/shasum -a 256 "$TMPD/$ASSET" | awk '{print $1}')"
	[ "$ACTUAL" = "${DIGEST#sha256:}" ] || err "checksum mismatch — the download is corrupted or was tampered with"
	info "checksum OK ($DIGEST)"
fi

# --- extract & install -----------------------------------------------------
info "extracting"
unzip -q "$TMPD/$ASSET" -d "$TMPD"
if [ -f "$TMPD/fnm" ]; then
	FNM_BIN="$TMPD/fnm"
else
	FNM_BIN="$(find "$TMPD" -type f -name fnm -print -quit)"
fi
if [ -z "$FNM_BIN" ] || [ ! -f "$FNM_BIN" ]; then
	err "unexpected zip layout (no fnm binary)"
fi

BINDIR="$PREFIX/bin"
mkdir -p -- "$BINDIR"
install -m 0755 "$FNM_BIN" "$BINDIR/fnm"

# --- PATH offer ------------------------------------------------------------
if [ "$ADD_PATH" = "1" ] && [ "$BINDIR" != "$HOME/.local/bin" ]; then
	case ":$PATH:" in
	*":$BINDIR:"*) on_path=1 ;;
	*) on_path=0 ;;
	esac
	if [ "$on_path" = "0" ]; then
		if [ -t 0 ]; then
			# shellcheck disable=SC2016
			printf '    %s is not on your PATH. Add it to your shell rc? [y/N] ' "$BINDIR"
			read -r answer
			case "$answer" in
			y | Y)
				case "${SHELL:-}" in
				*zsh*) RC="$HOME/.zshrc" ;;
				*) RC="$HOME/.bashrc" ;;
				esac
				# shellcheck disable=SC2016
				printf '\nexport PATH="%s:$PATH" # Added by mdrv/macos fnm installer\n' "$BINDIR" >>"$RC"
				printf '==> added %s to %s (restart your shell)\n' "$BINDIR" "$RC"
				;;
			esac
		else
			printf '    note: %s is not on your PATH (re-run without --no-path in a terminal to add it)\n' "$BINDIR"
		fi
	fi
fi

info "installed fnm v$VERSION into $BINDIR"
"$BINDIR/fnm" --version
printf '    next: fnm install --lts && fnm default lts-latest\n'
