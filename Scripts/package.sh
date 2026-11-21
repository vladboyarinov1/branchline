#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: Scripts/package.sh OUTPUT_DIRECTORY [--arch universal|native|arm64|x86_64] [--dmg | --release]

Builds Branchline.app. Universal and ad-hoc signing are the defaults.
Use --arch native for a faster local build, and --dmg to also create Branchline.dmg.
Use --release to build the Developer ID-signed app for Scripts/release.sh.
Release mode requires BRANCHLINE_SIGNING_IDENTITY, BRANCHLINE_UPDATE_FEED_URL,
and BRANCHLINE_SPARKLE_PUBLIC_KEY.
The output directory must not already contain the requested artifacts.
HELP
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
if [[ $# -eq 0 || $1 == -* ]]; then
    usage >&2
    exit 64
fi

output_dir=$1
shift
architecture=universal
create_dmg=false
release=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            architecture=${2:-}
            case "$architecture" in
                universal|native|arm64|x86_64) ;;
                *) usage >&2; exit 64 ;;
            esac
            shift 2
            ;;
        --dmg)
            create_dmg=true
            shift
            ;;
        --release)
            release=true
            shift
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

if [[ $(uname -s) != Darwin ]]; then
    printf '%s\n' 'Branchline can only be packaged on macOS.' >&2
    exit 69
fi

if $release; then
    if $create_dmg || [[ $architecture != universal ]]; then
        printf '%s\n' 'Release mode builds a universal app. Scripts/release.sh creates and notarizes the release DMG.' >&2
        exit 64
    fi
    : "${BRANCHLINE_SIGNING_IDENTITY:?Set a Developer ID Application identity.}"
    : "${BRANCHLINE_UPDATE_FEED_URL:?Set the HTTPS Sparkle feed URL.}"
    : "${BRANCHLINE_SPARKLE_PUBLIC_KEY:?Set the Sparkle EdDSA public key.}"
    if [[ ! $BRANCHLINE_UPDATE_FEED_URL =~ ^https://[^[:space:]]+/appcast\.xml$ ]] ||
       [[ ! $BRANCHLINE_SPARKLE_PUBLIC_KEY =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        printf '%s\n' 'Release mode requires an HTTPS appcast.xml URL and a base64 EdDSA public key.' >&2
        exit 64
    fi
fi

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
package_dir=$(cd -- "$script_dir/.." && pwd -P)
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
final_app="$output_dir/Branchline.app"
final_dmg="$output_dir/Branchline.dmg"
if [[ -e $final_app || -L $final_app ]] ||
   { $create_dmg && [[ -e $final_dmg || -L $final_dmg ]]; }; then
    printf 'An artifact already exists in %s. Choose another output directory.\n' "$output_dir" >&2
    exit 73
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/branchline-package.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT

if [[ $architecture == native ]]; then architecture=$(uname -m); fi
build=(swift build --package-path "$package_dir" --configuration release --product Branchline)

sparkle_distribution() {
    printf '%s/artifacts/sparkle/Sparkle\n' "$1"
}

build_executable() {
    "${build[@]}" "$@" >&2 || return
    local bin_dir
    bin_dir=$("${build[@]}" "$@" --show-bin-path) || return
    printf '%s/Branchline\n' "$bin_dir"
}

mkdir -p -- "$stage/disk"
app="$stage/disk/Branchline.app"
mkdir -p -- "$app/Contents/MacOS" "$app/Contents/Resources"
executable="$app/Contents/MacOS/Branchline"

if [[ $architecture == universal ]]; then
    if xcodebuild -version >/dev/null 2>&1; then
        scratch_path="$package_dir/.build/package-universal"
        binary=$(build_executable --arch arm64 --arch x86_64 --scratch-path "$scratch_path")
        install -m 755 "$binary" "$executable"
    else
        scratch_path="$package_dir/.build/package-arm64"
        arm=$(build_executable --arch arm64 --scratch-path "$package_dir/.build/package-arm64")
        intel=$(build_executable --arch x86_64 --scratch-path "$package_dir/.build/package-x86_64")
        xcrun lipo -create "$arm" "$intel" -output "$executable"
        chmod 755 "$executable"
    fi
    expected_slices=(arm64 x86_64)
else
    scratch_path="$package_dir/.build/package-$architecture"
    binary=$(build_executable --arch "$architecture" --scratch-path "$scratch_path")
    install -m 755 "$binary" "$executable"
    expected_slices=("$architecture")
fi

slices=$(xcrun lipo -archs "$executable")
for slice in "${expected_slices[@]}"; do
    if [[ " $slices " != *" $slice "* ]]; then
        printf 'Missing required architecture %s (built: %s).\n' "$slice" "$slices" >&2
        exit 65
    fi
done

plutil -lint "$script_dir/Info.plist"
info="$app/Contents/Info.plist"
install -m 644 "$script_dir/Info.plist" "$info"
if $release; then
    plutil -insert SUFeedURL -string "$BRANCHLINE_UPDATE_FEED_URL" "$info"
    plutil -insert SUPublicEDKey -string "$BRANCHLINE_SPARKLE_PUBLIC_KEY" "$info"
    plutil -insert SUEnableAutomaticChecks -bool true "$info"
    plutil -insert SUAllowsAutomaticUpdates -bool false "$info"
    plutil -insert SUAutomaticallyUpdate -bool false "$info"
    plutil -insert SUEnableSystemProfiling -bool false "$info"
    plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$info"
    plutil -insert SURequireSignedFeed -bool true "$info"
    plutil -insert SUSignedFeedFailureExpirationInterval -integer 0 "$info"
fi
install -m 644 "$package_dir/ThirdParty/SwiftTerm-LICENSE.txt" "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
install -m 644 "$package_dir/ThirdParty/JetBrainsMonoNL-Regular.ttf" "$app/Contents/Resources/JetBrainsMonoNL-Regular.ttf"
install -m 644 "$package_dir/ThirdParty/JetBrainsMono-OFL.txt" "$app/Contents/Resources/JetBrainsMono-OFL.txt"
swiftc -parse-as-library -O "$script_dir/MakeIcon.swift" -o "$stage/make-icon"
"$stage/make-icon" "$stage/Branchline.iconset"
iconutil --convert icns --output "$app/Contents/Resources/Branchline.icns" "$stage/Branchline.iconset"

sparkle=$(sparkle_distribution "$scratch_path")
framework="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
install -m 644 "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"

rpaths=$(otool -arch all -l "$executable" | awk '/cmd LC_RPATH/ {
    getline
    getline
    sub(/^[[:space:]]*path /, "")
    sub(/ \(offset [0-9]+\)$/, "")
    print
}' | sort -u)
app_rpath='@executable_path/../Frameworks'
if ! grep -Fxq "$app_rpath" <<< "$rpaths"; then
    install_name_tool -add_rpath "$app_rpath" "$executable"
fi
while IFS= read -r rpath; do
    case "$rpath" in
        ''|"$app_rpath"|/usr/lib/swift) ;;
        /*) install_name_tool -delete_rpath "$rpath" "$executable" ;;
    esac
done <<< "$rpaths"
if ! otool -L "$executable" | grep -Fq '@rpath/Sparkle.framework/Versions/'; then
    printf '%s\n' 'Branchline is missing its Sparkle framework link.' >&2
    exit 65
fi

if $release; then
    signing=(--force --sign "$BRANCHLINE_SIGNING_IDENTITY" --timestamp --options runtime)
    if [[ -n ${BRANCHLINE_SIGNING_KEYCHAIN:-} ]]; then
        signing+=(--keychain "$BRANCHLINE_SIGNING_KEYCHAIN")
    fi
    version_dir="$framework/Versions/$(readlink "$framework/Versions/Current")"
    for component in "$version_dir/Autoupdate" "$version_dir/Updater.app" "$version_dir/XPCServices/"*.xpc; do
        codesign "${signing[@]}" "$component"
    done
    codesign "${signing[@]}" "$framework"
    codesign "${signing[@]}" "$app"
    signature=$(codesign -dv --verbose=4 "$app" 2>&1)
    if ! grep -q '^Authority=Developer ID Application:' <<< "$signature"; then
        printf '%s\n' 'Release mode must use a Developer ID Application certificate.' >&2
        exit 65
    fi
else
    codesign --force --sign - --timestamp=none "$app"
fi
codesign --verify --deep --strict "$app"

if $create_dmg; then
    ln -s /Applications "$stage/disk/Applications"
    hdiutil create -quiet -volname Branchline -srcfolder "$stage/disk" -format UDZO "$stage/Branchline.dmg"
    hdiutil verify -quiet "$stage/Branchline.dmg"
fi

mv -n -- "$app" "$output_dir"
if [[ -e $app ]]; then
    printf 'An app already exists at %s.\n' "$final_app" >&2
    exit 73
fi
printf '%s\n' "$final_app"
if $create_dmg; then
    mv -n -- "$stage/Branchline.dmg" "$output_dir"
    if [[ -e $stage/Branchline.dmg ]]; then
        printf 'A disk image already exists at %s.\n' "$final_dmg" >&2
        exit 73
    fi
    printf '%s\n' "$final_dmg"
fi
