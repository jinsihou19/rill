#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
app_path="$project_root/build/Rill.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/docs"
cp "$binary_directory/Rill" "$app_path/Contents/MacOS/Rill"
cp "$project_root/assets/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_root/README.md" "$app_path/Contents/Resources/README.md"
cp "$project_root/docs/"*.md "$app_path/Contents/Resources/docs/"
swift "$project_root/scripts/make-icon.swift" "$project_root/build/Rill.iconset"
iconutil -c icns "$project_root/build/Rill.iconset" -o "$app_path/Contents/Resources/Rill.icns"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
printf '\nBuilt: %s\n' "$app_path"
if [[ "${1:-}" == "--open" ]]; then open "$app_path"; fi
