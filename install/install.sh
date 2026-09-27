#!/bin/bash
# Download, verify and install the latest Boozted/bs-arm64 release on a Steam Frame.
#
#   curl -fsSL https://github.com/Boozted/bs-arm64/releases/latest/download/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- /path/to/BSManager/instance
#   curl -fsSL .../install.sh | bash -s -- --no-mods
set -euo pipefail

REPO=${BS_ARM64_REPO:-Boozted/bs-arm64}
INSTANCE=${BS_ARM64_INSTANCE:-$HOME/.local/share/BSManager/BSInstances/1.44.1}
INSTANCE_EXPLICIT=0
INSTALL_ARGS=()

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --no-mods | --debug) INSTALL_ARGS+=("$1"); shift ;;
        --cache | --prefix | --proton)
            [ $# -ge 2 ] || die "$1 needs a directory"
            INSTALL_ARGS+=("$1" "$2"); shift 2 ;;
        -h | --help)
            sed -n '2,6p' "$0"
            exit 0
            ;;
        --*) die "unknown option $1" ;;
        *)
            [ "$INSTANCE_EXPLICIT" = 0 ] || die "only one instance directory may be given"
            INSTANCE=$1
            INSTANCE_EXPLICIT=1
            shift
            ;;
    esac
done

if [ ! -d "$INSTANCE" ] && [ "$INSTANCE_EXPLICIT" = 0 ] && [ -z "${BS_ARM64_INSTANCE:-}" ]; then
    shopt -s nullglob
    matches=("$HOME"/.local/share/BSManager/BSInstances/1.44.1*)
    shopt -u nullglob
    [ ${#matches[@]} -eq 1 ] && INSTANCE=${matches[0]}
fi
[ -d "$INSTANCE" ] || die "Beat Saber instance not found: $INSTANCE"

for tool in curl sha256sum tar; do
    command -v "$tool" >/dev/null || die "$tool is required"
done
if command -v python3 >/dev/null && python3 -c '' >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null && python -c '' >/dev/null 2>&1; then
    PYTHON=python
else
    die "python3 is required"
fi
if [ "${BS_ARM64_DRY_RUN:-0}" != 1 ] && [ "$(uname -m)" != aarch64 ]; then
    die "this installer is for the ARM64 Steam Frame"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "finding the latest $REPO release"
read -r archive archive_url checksum_url < <(
    curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | "$PYTHON" -c '
import json, sys
assets = json.load(sys.stdin).get("assets", [])
archives = [a for a in assets if a["name"].startswith("bs-arm64-") and a["name"].endswith(".tar.gz")]
if len(archives) != 1:
    sys.exit("latest release must contain exactly one bs-arm64 tarball")
name = archives[0]["name"]
checksums = [a for a in assets if a["name"] == name + ".sha256"]
if len(checksums) != 1:
    sys.exit("latest release has no matching checksum")
print(name, archives[0]["browser_download_url"], checksums[0]["browser_download_url"])
'
)
checksum_url=${checksum_url%$'\r'}
[ -n "${archive:-}" ] || die "could not find the latest release archive"

log "downloading $archive"
curl -fL --progress-bar -o "$TMP/$archive" "$archive_url"
curl -fsSL -o "$TMP/$archive.sha256" "$checksum_url"
(cd "$TMP" && sha256sum -c "$archive.sha256")

tar xzf "$TMP/$archive" -C "$TMP"
release_dir=$TMP/${archive%.tar.gz}
[ -x "$release_dir/bs-arm64.sh" ] || die "release archive does not contain bs-arm64.sh"

if [ "${BS_ARM64_DRY_RUN:-0}" = 1 ]; then
    log "dry run passed; would install into $INSTANCE"
    exit 0
fi

log "installing into $INSTANCE"
"$release_dir/bs-arm64.sh" install "$INSTANCE" "${INSTALL_ARGS[@]}"
