#!/bin/sh
# Bootstrap installer for mdrv-macos (the package manager itself).
# Installs a prebuilt release binary into $PREFIX/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/mdrv/macos/main/scripts/install.sh | sh
#
#   MDRV_MACOS_VERSION=0.1.0   pin a version (with or without leading v)
#   MDRV_MACOS_PREFIX=...      install root (binaries land in $PREFIX/bin)
set -eu

REPO="mdrv/macos"
BIN="mdrv-macos"
API_URL="https://api.github.com/repos/${REPO}"
DL_URL="https://github.com/${REPO}/releases"
PREFIX="${MDRV_MACOS_PREFIX:-$HOME/.local}"
BINDIR="${PREFIX}/bin"

usage() {
	sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}
case "${1:-}" in
-h | --help) usage ;;
esac

die() { printf '%s\n' "install-${BIN}: error: $*" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v curl >/dev/null || die "curl is required"
[ "$(uname -s)" = "Darwin" ] || die "prebuilt binaries are macOS-only — for Linux use apps/*.sh directly"

case "$(uname -m)" in
arm64 | aarch64) TARGET="aarch64-apple-darwin" ;;
x86_64) TARGET="x86_64-apple-darwin" ;;
*) die "unsupported architecture: $(uname -m)" ;;
esac

VERSION="${MDRV_MACOS_VERSION:-}"
if [ -n "$VERSION" ]; then
	VERSION="${VERSION#v}"
	URL="${API_URL}/releases/tags/v${VERSION}"
else
	URL="${API_URL}/releases/latest"
fi

printf '==> resolving release\n'
TAG="$(curl -fsSL "$URL" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$TAG" ] || die "could not resolve the release from the GitHub API (rate limit? try again later)"
[ -n "$VERSION" ] || VERSION="${TAG#v}"

ASSET="${BIN}-${TAG}-${TARGET}.tar.gz"
printf '==> downloading %s\n' "$ASSET"
curl -fsSL -o "$TMP/$ASSET" "${DL_URL}/download/${TAG}/${ASSET}" ||
	die "download failed (release ${TAG} exists but the asset is missing?)"

printf '==> verifying sha256\n'
curl -fsSL -o "$TMP/SHA256SUMS.txt" "${DL_URL}/download/${TAG}/SHA256SUMS.txt" &&
	grep -F "  $ASSET" "$TMP/SHA256SUMS.txt" | (cd "$TMP" && shasum -a 256 -c -) >/dev/null ||
	die "checksum verification failed"

tar -xzf "$TMP/$ASSET" -C "$TMP"

mkdir -p "$BINDIR"
[ -x "$TMP/$BIN/$BIN" ] || die "unexpected archive layout"
install -m 0755 "$TMP/$BIN/$BIN" "$BINDIR/$BIN"

case ":$PATH:" in
*":$BINDIR:"*) ;;
*)
	if [ -t 0 ]; then
		printf "    %s is not on your PATH. Add it? [y/N] " "$BINDIR"
		read -r answer
		case "$answer" in
		y | Y)
			RC="${ZDOTDIR:-$HOME}/.zshrc"
			printf '\n# Added by mdrv-macos installer\nexport PATH="%s:$PATH"\n' "$BINDIR" >>"$RC"
			printf '==> added to %s (restart your shell)\n' "$RC"
			;;
		esac
	else
		printf '!!> %s is not on your PATH — add: export PATH="%s:$PATH"\n' "$BINDIR" "$BINDIR"
	fi
	;;
esac

printf '==> %s %s installed → %s\n' "$BIN" "$VERSION" "$BINDIR/$BIN"
printf '    try: %s --help   (upgrade later with: %s self-update)\n' "$BIN" "$BIN"
