#!/bin/sh
# RitCode installer for macOS and Linux.
#
# Proprietary. (c) 2026 Ritik Sharma. All rights reserved.
#
# Downloads the prebuilt `ritcode` binary from GitHub Releases, verifies its
# SHA256 before trusting it, and installs it user-local with no sudo:
#
#     curl -fsSL https://raw.githubusercontent.com/ritiksharmma/ritcode-dist/main/install.sh | sh
#
# Environment:
#   RITCODE_HOME            install root (default: ~/.ritcode)
#   RITCODE_VERSION         install a specific tag (e.g. v0.1.0) instead of latest
#   RITCODE_NO_MODIFY_PATH  when "1", never edit a shell profile; only print PATH help

set -eu

REPO="ritiksharmma/ritcode-dist"
API="https://api.github.com/repos/${REPO}"
HOME_DIR="${RITCODE_HOME:-$HOME/.ritcode}"
BIN_DIR="$HOME_DIR/bin"

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# ---- 1. detect OS and architecture, map to a target triple -------------------

detect_target() {
	os=$(uname -s)
	arch=$(uname -m)
	case "$os" in
	Darwin) os=macos ;;
	Linux) os=linux ;;
	*) die "unsupported OS: $os (RitCode ships macOS and Linux here; Windows uses install.ps1)" ;;
	esac
	case "$arch" in
	arm64 | aarch64) arch=aarch64 ;;
	x86_64 | amd64) arch=x86_64 ;;
	*) die "unsupported architecture: $arch" ;;
	esac
	case "$os-$arch" in
	macos-aarch64) echo "aarch64-apple-darwin" ;;
	macos-x86_64) echo "x86_64-apple-darwin" ;;
	linux-x86_64) echo "x86_64-unknown-linux-gnu" ;;
	linux-aarch64) echo "aarch64-unknown-linux-gnu" ;;
	*) die "no RitCode release for $os-$arch" ;;
	esac
}

# ---- 2. resolve the release and its asset URLs -------------------------------

resolve_release() {
	if [ -n "${RITCODE_VERSION:-}" ]; then
		tag="$RITCODE_VERSION"
		case "$tag" in v*) : ;; *) tag="v$tag" ;; esac
		url="$API/releases/tags/$tag"
	else
		url="$API/releases/latest"
	fi
	curl -fsSL -H "Accept: application/vnd.github+json" "$url" ||
		die "could not reach the GitHub Releases API at $url"
}

# Pull every asset download URL out of the release JSON without needing jq.
asset_urls() {
	grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
		sed -E 's/.*"(https[^"]+)".*/\1/'
}

# ---- 3. download, verify, and extract ----------------------------------------

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "no sha256 tool found (need sha256sum or shasum)"
	fi
}

# Reject absolute paths and any `..` component before extracting anything.
# Loops in the main shell (not a pipe subshell) so `die` truly aborts.
assert_safe_archive() {
	entries=$(tar -tzf "$1") || die "could not read archive contents"
	oldifs=$IFS
	IFS='
'
	for entry in $entries; do
		case "$entry" in
		/* | ../* | */../* | */.. | ..) die "unsafe archive entry rejected: $entry" ;;
		esac
	done
	IFS=$oldifs
}

main() {
	need curl
	need tar
	need uname

	target=$(detect_target)
	say "RitCode: resolving the latest release for $target"

	json=$(resolve_release)
	urls=$(printf '%s' "$json" | asset_urls)

	archive_url=$(printf '%s\n' "$urls" | grep -E "${target}\.tar\.gz$" | head -n1 || true)
	sha_url=$(printf '%s\n' "$urls" | grep -E "${target}\.tar\.gz\.sha256$" | head -n1 || true)
	[ -n "$archive_url" ] || die "no archive asset found for $target in the release"
	[ -n "$sha_url" ] || die "no checksum asset found for $target in the release"

	tmp=$(mktemp -d "${TMPDIR:-/tmp}/ritcode.XXXXXX") || die "could not create a temp dir"
	trap 'rm -rf "$tmp"' EXIT INT TERM

	archive="$tmp/$(basename "$archive_url")"
	sha_file="$tmp/$(basename "$sha_url")"

	say "RitCode: downloading $(basename "$archive_url")"
	curl -fsSL "$archive_url" -o "$archive" || die "download failed: $archive_url"
	curl -fsSL "$sha_url" -o "$sha_file" || die "checksum download failed: $sha_url"

	expected=$(awk '{print $1}' "$sha_file")
	actual=$(sha256_of "$archive")
	[ -n "$expected" ] || die "empty checksum file"
	if [ "$expected" != "$actual" ]; then
		die "checksum mismatch: expected $expected, got $actual (refusing to install)"
	fi
	say "RitCode: checksum verified"

	assert_safe_archive "$archive"
	mkdir -p "$tmp/extract"
	tar -xzf "$archive" -C "$tmp/extract" || die "extraction failed"

	bin_src=$(find "$tmp/extract" -type f -name ritcode | head -n1 || true)
	[ -n "$bin_src" ] || die "no ritcode binary inside the archive"

	# ---- 4. install user-local, no sudo ----------------------------------

	mkdir -p "$BIN_DIR"
	mv "$bin_src" "$BIN_DIR/ritcode"
	chmod +x "$BIN_DIR/ritcode"
	say "RitCode: installed to $BIN_DIR/ritcode"

	# macOS: clear the quarantine flag so Gatekeeper does not block first run.
	# Proper codesigning and notarization is the real fix and is not done yet.
	if [ "$(uname -s)" = "Darwin" ]; then
		xattr -d com.apple.quarantine "$BIN_DIR/ritcode" >/dev/null 2>&1 || true
	fi

	setup_path
	warn_if_shadowed
	say ""
	say "Done. Start RitCode with:"
	say "  ritcode"
}

# ---- 5. PATH handling --------------------------------------------------------

setup_path() {
	case ":$PATH:" in
	*":$BIN_DIR:"*)
		return 0
		;;
	esac

	if [ "${RITCODE_NO_MODIFY_PATH:-0}" != "1" ]; then
		profile=$(detect_profile)
		if [ -n "$profile" ]; then
			line="export PATH=\"$BIN_DIR:\$PATH\""
			if ! grep -qsF "$BIN_DIR" "$profile" 2>/dev/null; then
				{
					printf '\n# added by the RitCode installer\n'
					printf '%s\n' "$line"
				} >>"$profile"
			fi
			say "RitCode: added $BIN_DIR to your PATH in $profile"
			say "  open a new shell, or run: export PATH=\"$BIN_DIR:\$PATH\""
			return 0
		fi
	fi

	say ""
	say "Add $BIN_DIR to your PATH:"
	say "  zsh         echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc"
	say "  bash        echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
	say "  fish        fish_add_path $BIN_DIR"
	say "  PowerShell  \$env:PATH = \"$BIN_DIR:\$env:PATH\"   (add to your \$PROFILE)"
}

# ---- 6. shadow warning -------------------------------------------------------

# If some other `ritcode` earlier on PATH will run instead of the one we just
# installed, say so loudly. Non-destructive: we never touch the other file.
warn_if_shadowed() {
	active=$(command -v ritcode 2>/dev/null || true)
	[ -n "$active" ] || return 0
	[ "$active" = "$BIN_DIR/ritcode" ] && return 0
	warn "another 'ritcode' is already on your PATH and will run instead of the one just installed:"
	warn "    $active"
	warn "the binary just installed is at:"
	warn "    $BIN_DIR/ritcode"
	warn "remove the other one, or make sure $BIN_DIR comes first in PATH."
	warn "a new shell picks up the updated PATH."
}

# The profile file for the current login shell, if we can pick one safely.
detect_profile() {
	shell_name=$(basename "${SHELL:-}")
	case "$shell_name" in
	zsh) echo "$HOME/.zshrc" ;;
	bash)
		if [ -f "$HOME/.bashrc" ]; then echo "$HOME/.bashrc"; else echo "$HOME/.bash_profile"; fi
		;;
	*) echo "" ;;
	esac
}

if [ "${RITCODE_SELFTEST_SHADOW:-0}" = "1" ]; then
	warn_if_shadowed
	exit 0
fi

main "$@"
