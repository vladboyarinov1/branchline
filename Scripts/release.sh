#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: Scripts/release.sh [--dry-run] OUTPUT_DIRECTORY OWNER/REPOSITORY

Builds a universal macOS production release, notarizes its application and disk
image, signs the update archive and appcast, and writes the GitHub release assets.
The destination must not exist. This script does not publish or push anything.
Read RELEASE.md for signing setup. A dry run validates the local version,
destination, and feed configuration without credentials or network writes.
HELP
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

dry_run=false
if [[ ${1:-} == --dry-run ]]; then
    dry_run=true
    shift
fi
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
if [[ $# -ne 2 ]]; then
    usage >&2
    exit 64
fi

output=$1
repository=$2
[[ $repository =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] ||
    fail 'Repository must use the GitHub owner/repository format.'
[[ -n $output && ! -e $output && ! -L $output ]] || fail 'Choose a new output directory.'
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
project_dir=$(cd -- "$script_dir/.." && pwd -P)
version=$(plutil -extract CFBundleShortVersionString raw -o - "$script_dir/Info.plist")
build=$(plutil -extract CFBundleVersion raw -o - "$script_dir/Info.plist")
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Version must use MAJOR.MINOR.PATCH.'
[[ $build =~ ^[1-9][0-9]*$ ]] || fail 'Build number must be a positive integer.'
tag="v$version"
asset_base="https://github.com/$repository/releases/download/$tag"
owner=$(printf '%s' "${repository%%/*}" | tr '[:upper:]' '[:lower:]')
default_site="https://$owner.github.io/${repository#*/}"
site=${BRANCHLINE_PAGES_URL:-$default_site}
export BRANCHLINE_UPDATE_FEED_URL="${site%/}/appcast.xml"
python3 - "$BRANCHLINE_UPDATE_FEED_URL" <<'PY'
import re
import sys
from urllib.parse import urlsplit

url = sys.argv[1]
parts = urlsplit(url)
if (parts.scheme != "https" or not parts.hostname or parts.username is not None
        or parts.query or parts.fragment or re.search(r"\s", url)):
    raise SystemExit("The update feed requires an HTTPS site URL without credentials, query, or fragment.")
PY

zip_name="Branchline-$version.zip"
if $dry_run; then
    printf 'Version %s (build %s), tag %s\nFeed %s\nInstaller %s/Branchline.dmg\n' \
        "$version" "$build" "$tag" "$BRANCHLINE_UPDATE_FEED_URL" "$asset_base"
    exit 0
fi

[[ $(uname -s) == Darwin ]] || fail 'Release packaging requires macOS.'
: "${BRANCHLINE_SIGNING_IDENTITY:?Set a Developer ID Application identity.}"
: "${BRANCHLINE_NOTARY_PROFILE:?Set a notarytool keychain profile.}"
: "${BRANCHLINE_SPARKLE_PUBLIC_KEY:?Set the Sparkle public key.}"
: "${BRANCHLINE_SPARKLE_PRIVATE_KEY:?Set the Sparkle private signing key.}"

stage=$(mktemp -d "${TMPDIR:-/tmp}/branchline-release.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/assets" "$stage/disk" "$stage/update"
"$script_dir/package.sh" "$stage/disk" --release
app="$stage/disk/Branchline.app"

notarize() {
    local path=$1
    local opts=(--keychain-profile "$BRANCHLINE_NOTARY_PROFILE")
    if [[ -n ${BRANCHLINE_SIGNING_KEYCHAIN:-} ]]; then
        opts+=(--keychain "$BRANCHLINE_SIGNING_KEYCHAIN")
    fi
    if ! xcrun notarytool submit "$path" "${opts[@]}" --wait --output-format json > "$stage/notary.json" ||
        ! jq -e '.status == "Accepted"' "$stage/notary.json" >/dev/null; then
        jq -r 'select(.id) | "Notary submission \(.id): \(.status // "Unknown")"' "$stage/notary.json" >&2
        fail 'Apple did not accept the notarization submission.'
    fi
}

# The app ticket must be stapled before it is included in either downloadable archive.
ditto -c -k --keepParent "$app" "$stage/notarization.zip"
notarize "$stage/notarization.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute "$app"

ln -s /Applications "$stage/disk/Applications"
dmg="$stage/assets/Branchline.dmg"
hdiutil create -quiet -volname Branchline -srcfolder "$stage/disk" -format UDZO "$dmg"
signing=(--force --sign "$BRANCHLINE_SIGNING_IDENTITY" --timestamp)
if [[ -n ${BRANCHLINE_SIGNING_KEYCHAIN:-} ]]; then
    signing+=(--keychain "$BRANCHLINE_SIGNING_KEYCHAIN")
fi
codesign "${signing[@]}" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
hdiutil verify -quiet "$dmg"

ditto -c -k --keepParent "$app" "$stage/update/$zip_name"
sparkle_tools="$project_dir/.build/package-universal/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$sparkle_tools/generate_appcast" ]]; then
    sparkle_tools="$project_dir/.build/package-arm64/artifacts/sparkle/Sparkle/bin"
fi
if [[ -f "$project_dir/ReleaseNotes/$version.md" ]]; then
    cp "$project_dir/ReleaseNotes/$version.md" "$stage/update/Branchline-$version.md"
fi
printf '%s\n' "$BRANCHLINE_SPARKLE_PRIVATE_KEY" |
    "$sparkle_tools/generate_appcast" --ed-key-file - --download-url-prefix "$asset_base/" \
        --maximum-deltas 0 --embed-release-notes -o "$stage/update/appcast.xml" "$stage/update"
printf '%s\n' "$BRANCHLINE_SPARKLE_PRIVATE_KEY" |
    "$sparkle_tools/sign_update" --verify --ed-key-file - "$stage/update/appcast.xml"

archive_signature=$(python3 - "$stage/update" "$stage/assets" "$zip_name" "$asset_base" "$version" "$build" <<'PY'
import base64
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

update, assets, name, base, version, build = sys.argv[1:]
update, assets = Path(update), Path(assets)
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(update / "appcast.xml").findall("./channel/item")
if len(items) != 1:
    raise SystemExit("Expected one stable release in the generated feed.")
item = items[0]
enclosure = item.find("enclosure")
if (
    enclosure is None
    or item.findtext(namespace + "version") != build
    or item.findtext(namespace + "shortVersionString") != version
    or enclosure.get("url") != f"{base}/{name}"
    or enclosure.get("length") != str((update / name).stat().st_size)
    or len(base64.b64decode(enclosure.get(namespace + "edSignature", ""), validate=True)) != 64
):
    raise SystemExit("The generated Sparkle feed does not match the signed update asset.")
metadata = dict(version=version, build=int(build),
                downloadUrl=f"{base}/Branchline.dmg", size=(assets / "Branchline.dmg").stat().st_size)
(assets / "release.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
print(enclosure.get(namespace + "edSignature"))
PY
)
printf '%s\n' "$BRANCHLINE_SPARKLE_PRIVATE_KEY" | "$sparkle_tools/sign_update" \
    --verify --ed-key-file - "$stage/update/$zip_name" "$archive_signature"
mv "$stage/update/$zip_name" "$stage/update/appcast.xml" "$stage/assets/"
(cd "$stage/assets" && shasum -a 256 Branchline.dmg "$zip_name" appcast.xml release.json > SHA256SUMS.txt)

mkdir -p -- "$(dirname -- "$output")"
mv -n -- "$stage/assets" "$output"
[[ ! -d "$stage/assets" ]] || fail 'Release assets could not be moved to the output directory.'
printf 'Verified release assets for %s (build %s) at %s\n' "$tag" "$build" "$output"
