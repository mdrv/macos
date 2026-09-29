#!/bin/sh
# node — install prebuilt Node.js on macOS & Linux (no compilation).
#
# Downloads the official nodejs.org tarball for your platform, verifies it
# against the release SHASUMS256.txt, and installs the full runtime
# (node, npm, npx + headers) under $PREFIX.
#
# Usage:
#   sh node.sh [--version X] [--prefix DIR] [--no-path]
#
# Environment (flags win): NODE_VERSION, NODE_PREFIX, NODE_ADD_PATH=0
#
# Repository: https://github.com/mdrv/macos

set -eu

DIST_URL="https://nodejs.org/dist"
PREFIX="${NODE_PREFIX:-$HOME/.local}"
WANT_VERSION="${NODE_VERSION:-}"
ADD_PATH="${NODE_ADD_PATH:-1}"

usage() {
	cat <<'EOF'
node installer — prebuilt Node.js for macOS & Linux

Usage: sh node.sh [--version X] [--prefix DIR] [--no-path]

Flags:
  --version X   install a specific Node.js version (e.g. 26.10.0 or v26.10.0);
                defaults to the latest release from nodejs.org/dist/index.json
  --prefix DIR  install root (default: ~/.local → ~/.local/bin/node)
  --no-path     skip the shell-rc PATH offer
  -h, --help    show this help

Environment:
  NODE_VERSION / NODE_PREFIX / NODE_ADD_PATH=0 — same as the flags above

https://github.com/mdrv/macos
EOF
}

err() {
	printf 'node: error: %s\n' "$1" >&2
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

# --- resolve platform ------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
Darwin) OS_TAG="darwin" ;;
Linux) OS_TAG="linux" ;;
*) err "unsupported OS: $OS (nodejs.org ships darwin/linux tarballs)" ;;
esac
case "$ARCH" in
x86_64 | amd64) ARCH_TAG="x64" ;;
arm64 | aarch64) ARCH_TAG="arm64" ;;
armv7l | armv8l) ARCH_TAG="armv7l" ;;
*) err "unsupported architecture: $ARCH" ;;
esac

	# mdrv-macos contract: MDRV_VERSION/MDRV_ASSET_FILE skip resolution, download
	# and verification (the manager has already done both).
if [ -n "${MDRV_VERSION:-}" ]; then
	WANT_VERSION=${MDRV_VERSION#v}
else
	# --- resolve version -------------------------------------------------------
	case "$WANT_VERSION" in
	v*) WANT_VERSION="${WANT_VERSION#v}" ;;
	esac
	if [ -z "$WANT_VERSION" ]; then
		info "resolving latest Node.js release"
		VERSION="$(curl -fsSL "$DIST_URL/index.json" | sed -n 's/.*"version":"v\([0-9.]*\)".*/\1/p' | head -n 1)"
		[ -n "$VERSION" ] || err "could not resolve the latest version from nodejs.org"
	else
		VERSION="$WANT_VERSION"
	fi
fi

ASSET="node-v$VERSION-$OS_TAG-$ARCH_TAG.tar.gz"
ASSET_URL="$DIST_URL/v$VERSION/$ASSET"
SUMS_URL="$DIST_URL/v$VERSION/SHASUMS256.txt"
DEST="$PREFIX"

info "resolving release $VERSION"

# --- download --------------------------------------------------------------
TMPD="$(mktemp -d)"
if [ -n "${MDRV_ASSET_FILE:-}" ]; then
	info "installing from mdrv-macos verified cache: $(basename -- "$MDRV_ASSET_FILE")"
	cp -- "$MDRV_ASSET_FILE" "$TMPD/$ASSET"
else
	info "downloading $ASSET"
	curl -fsSL "$ASSET_URL" -o "$TMPD/$ASSET" || err "download failed (release $VERSION may not exist, or the network is unreachable)"

	# --- verify ----------------------------------------------------------------
	info "verifying sha256 against SHASUMS256.txt"
	EXPECTED="$(curl -fsSL "$SUMS_URL" | grep -F " $ASSET" | awk '{print $1}')"
	case "$EXPECTED" in
	[0-9a-f]*) ;;
	*) err "no entry for $ASSET in SHASUMS256.txt" ;;
	esac
	ACTUAL="$(/usr/bin/shasum -a 256 "$TMPD/$ASSET" | awk '{print $1}')"
	[ "$ACTUAL" = "$EXPECTED" ] || err "checksum mismatch — the download is corrupted or was tampered with"
	info "checksum OK (sha256:$EXPECTED)"

	# --- extract & install -----------------------------------------------------
fi
info "extracting"
tar -xzf "$TMPD/$ASSET" -C "$TMPD"
SRC="$TMPD/node-v$VERSION-$OS_TAG-$ARCH_TAG"
[ -f "$SRC/bin/node" ] || err "unexpected tarball layout (no bin/node)"

mkdir -p -- "$DEST"
# the tarball carries bin, lib (npm lives in lib/node_modules), include, share
cp -R "$SRC/." "$DEST/"

if [ -x "$DEST/bin/node" ]; then
	:
else
	err "node not found at $DEST/bin/node after install"
fi

# --- PATH offer ------------------------------------------------------------
BINDIR="$DEST/bin"
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
				printf '\nexport PATH="%s:$PATH" # Added by mdrv/macos node installer\n' "$BINDIR" >>"$RC"
				printf '==> added %s to %s (restart your shell)\n' "$BINDIR" "$RC"
				;;
			esac
		else
			printf '    note: %s is not on your PATH (re-run with --no-path omitted in a terminal to add it)\n' "$BINDIR"
		fi
	fi
fi

if [ -x "$BINDIR/node" ]; then
	:
else
	err "install finished but $BINDIR/node is missing"
fi

info "installed Node.js v$VERSION into $DEST"
"$BINDIR/node" --version
"$BINDIR/npm" --version >/dev/null 2>&1 && printf '    npm %s\n' "$("$BINDIR/npm" --version)"
printf '    run node --version in a new shell to confirm\n'
