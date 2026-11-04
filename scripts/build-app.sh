#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
app_path="${RILL_BUILD_APP_PATH:-$project_root/build/rill.app}"
ensure_app_not_in_use() {
    # Replacing a running executable can break its Keychain code identity.
    local executables=("${app_path:A}/Contents/MacOS/"*(N))
    if (( ${#executables} )) && /usr/sbin/lsof -t -- "${executables[@]}" >/dev/null; then
        print -u2 "Cannot replace an app that is in use: $app_path"
        print -u2 "Quit this Rill instance first, or set RILL_BUILD_APP_PATH to a different app path."
        exit 1
    fi
}
ensure_app_not_in_use
build_arguments=(-c release)
if [[ "${RILL_BUILD_UNIVERSAL:-0}" == "1" ]]; then build_arguments+=(--arch arm64 --arch x86_64); fi
swift build "${build_arguments[@]}"
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
mkdir -p "$project_root/build" "$(dirname "$app_path")"
stage="$(mktemp -d "$project_root/build/rill-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
package_path="$stage/rill.app"
mkdir -p "$package_path/Contents/MacOS" "$package_path/Contents/Resources" "$package_path/Contents/Frameworks"
cp "$binary_directory/rill" "$package_path/Contents/MacOS/rill"
cp "$project_root/assets/Info.plist" "$package_path/Contents/Info.plist"
sparkle="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$sparkle" "$package_path/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$package_path/Contents/MacOS/rill"
# Remove local and debug symbols before signing; keep symbols needed at runtime.
xcrun strip -x "$package_path/Contents/MacOS/rill"
swift "$project_root/scripts/make-icon.swift" "$project_root/build/rill.iconset"
iconutil -c icns "$project_root/build/rill.iconset" -o "$package_path/Contents/Resources/rill.icns"
codesign --force --sign - "$package_path"
codesign --verify --deep --strict "$package_path"
ensure_app_not_in_use
if [[ -e "$app_path" ]]; then mv "$app_path" "$stage/previous.app"; fi
if ! mv "$package_path" "$app_path"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app_path"; fi
    exit 1
fi
printf '\nBuilt: %s\n' "$app_path"
if [[ "${1:-}" == "--open" ]]; then open "$app_path"; fi
