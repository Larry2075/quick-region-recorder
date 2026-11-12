#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
destination="${1:-$project_dir/快捷录屏.app}"
if [[ "$destination" != /* || "${destination##*/}" != 快捷录屏.app ]]; then
    printf '请提供以 快捷录屏.app 结尾的绝对路径。\n' >&2
    exit 1
fi
stage_dir="$(mktemp -d "${project_dir}/.build.XXXXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT

bundle="$stage_dir/快捷录屏.app"
extension="$bundle/Contents/PlugIns/QuickRegionFinderExtension.appex"
mkdir -p "$bundle/Contents/MacOS" "$extension/Contents/MacOS"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
cp "$project_dir/FinderExtension/Info.plist" "$extension/Contents/Info.plist"

arch="$(uname -m)"
swift_flags=(-swift-version 6 -warnings-as-errors -O -sdk "$(xcrun --show-sdk-path)" -target "${arch}-apple-macosx15.0")
xcrun swiftc "${swift_flags[@]}" "$project_dir"/Sources/*.swift \
    -o "$bundle/Contents/MacOS/QuickRegionRecorder"
xcrun swiftc "${swift_flags[@]}" -module-name QuickRegionFinderExtension \
    -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
    "$project_dir/FinderExtension/FinderSync.swift" "$project_dir/Sources/RecorderCommand.swift" \
    -o "$extension/Contents/MacOS/QuickRegionFinderExtension"

plutil -lint "$bundle/Contents/Info.plist" "$extension/Contents/Info.plist"
codesign --force --sign - --entitlements "$project_dir/FinderExtension/Extension.entitlements" "$extension"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"

if [[ -e "$destination" ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [[ "$bundle_id" != com.kongdexi.quick-region-recorder ]]; then
        printf '目标位置已有别的应用：%s\n' "$destination" >&2
        exit 1
    fi
    mv -- "$destination" "$stage_dir/previous.app"
fi
if ! mv -- "$bundle" "$destination"; then
    if [[ -d "$stage_dir/previous.app" ]]; then
        mv -- "$stage_dir/previous.app" "$destination"
    fi
    exit 1
fi
printf '%s\n' "$destination"
