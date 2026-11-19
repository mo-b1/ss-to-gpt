#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$repo_dir/dist/Screenshot to ChatGPT.app"
contents_dir="$app_dir/Contents"

cd "$repo_dir"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/ss-to-gpt-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/ss-to-gpt-swift-cache"
swift build --disable-sandbox -c "$configuration"
binary_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)/ScreenshotToChatGPT"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_path" "$contents_dir/MacOS/ScreenshotToChatGPT"
cp "$repo_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$repo_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
# Keep a stable designated requirement so macOS privacy approval survives rebuilds.
codesign --force --deep --sign - \
  --requirements '=designated => identifier "dev.ss-to-gpt.ScreenshotToChatGPT"' \
  "$app_dir"
print "Built: $app_dir"
