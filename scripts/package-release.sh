#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

# 发布产物必须能对应已提交源码；本脚本只打包和签名，不安装或发布。
if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "Release packaging requires a clean, committed worktree."
    exit 1
fi
version="$(plutil -extract CFBundleShortVersionString raw assets/Info.plist)"
build_number="$(plutil -extract CFBundleVersion raw assets/Info.plist)"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Invalid release version or build number."
    exit 1
fi
notes="$project_root/docs/releases/v$version.md"
[[ -f "$notes" ]] || { print -u2 "Missing release notes: $notes"; exit 1; }
# 构建号单调递增，不能把旧安装包重新作为最新更新发布。
python3 - "$build_number" <<'PY'
import sys
import xml.etree.ElementTree as ET
build = int(sys.argv[1])
versions = ET.parse('appcast.xml').findall('.//{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
if any(int(version.text) >= build for version in versions):
    raise SystemExit('Increase CFBundleVersion beyond every published build before packaging.')
PY

tag="v$version-$build_number"
output="$project_root/build/releases/$tag"
[[ ! -e "$output" ]] || { print -u2 "Release output already exists: $output"; exit 1; }
mkdir -p "$output"
RILL_BUILD_UNIVERSAL=1 "$project_root/scripts/build-app.sh"
app_path="$project_root/build/rill.app"
architectures="$(lipo -archs "$app_path/Contents/MacOS/rill")"
[[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || { print -u2 "Missing Universal architecture slice."; exit 1; }
archive="$output/rill-$version-$build_number-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
cp "$notes" "${archive%.zip}.md"
sparkle_bin="$project_root/.build/artifacts/sparkle/Sparkle/bin"
arguments=(--download-url-prefix "https://github.com/jinsihou19/rill/releases/download/$tag/"
           --link "https://github.com/jinsihou19/rill" --embed-release-notes
           --maximum-versions 1 --maximum-deltas 0 -o "$output/appcast.xml" "$output")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" --ed-key-file - "${arguments[@]}"
else
    "$sparkle_bin/generate_appcast" --account app.rill.redis "${arguments[@]}"
fi
shasum -a 256 "$archive" > "$archive.sha256"
print "Release tag: $tag"
print "Signed artifacts: $output"
