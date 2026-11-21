#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: Scripts/package.sh OUTPUT_DIRECTORY [--arch universal|native|arm64|x86_64] [--dmg]

Builds an ad-hoc signed Branchline.app for local use. Universal is the default.
Use --arch native for a faster local build, and --dmg to also create Branchline.dmg.
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
# SwiftBuild's multi-architecture graph can omit SwiftTerm's build-information plugin.
# Use native SwiftPM to build each architecture and combine them when requested.
build=(swift build --build-system native --package-path "$package_dir" --configuration release --product Branchline)

build_slice() {
    local target_arch=$1
    local output=$2
    local args=(--arch "$target_arch" --scratch-path "$package_dir/.build/package-$target_arch")
    local bin_dir
    "${build[@]}" "${args[@]}"
    bin_dir=$("${build[@]}" "${args[@]}" --show-bin-path)
    install -m 755 "$bin_dir/Branchline" "$output"
}

mkdir -p -- "$stage/disk"
app="$stage/disk/Branchline.app"
mkdir -p -- "$app/Contents/MacOS" "$app/Contents/Resources"
executable="$app/Contents/MacOS/Branchline"

if [[ $architecture == universal ]]; then
    build_slice arm64 "$stage/Branchline-arm64"
    build_slice x86_64 "$stage/Branchline-x86_64"
    xcrun lipo -create "$stage/Branchline-arm64" "$stage/Branchline-x86_64" -output "$executable"
    chmod 755 "$executable"
    expected_slices=(arm64 x86_64)
else
    build_slice "$architecture" "$executable"
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
install -m 644 "$script_dir/Info.plist" "$app/Contents/Info.plist"
install -m 644 "$package_dir/ThirdParty/SwiftTerm-LICENSE.txt" "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
install -m 644 "$package_dir/ThirdParty/JetBrainsMonoNL-Regular.ttf" "$app/Contents/Resources/JetBrainsMonoNL-Regular.ttf"
install -m 644 "$package_dir/ThirdParty/JetBrainsMono-OFL.txt" "$app/Contents/Resources/JetBrainsMono-OFL.txt"
swiftc -parse-as-library -O "$script_dir/MakeIcon.swift" -o "$stage/make-icon"
"$stage/make-icon" "$stage/Branchline.iconset"
iconutil --convert icns --output "$app/Contents/Resources/Branchline.icns" "$stage/Branchline.iconset"

codesign --force --sign - --timestamp=none "$app"
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
