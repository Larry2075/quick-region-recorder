#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 || "${1:-}" == --help ]]; then
    printf '用法：./install.sh [--chrome]\n'
    exit "$(( $# > 1 ))"
fi
case "${1:-}" in
    ""|--chrome) ;;
    *) printf '用法：./install.sh [--chrome]\n' >&2; exit 1 ;;
esac

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
macos_major="$(sw_vers -productVersion | cut -d . -f 1)"
if (( macos_major < 15 )); then
    printf '快捷录屏需要 macOS 15 或更新版本。\n' >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    printf '请先运行 xcode-select --install，安装完成后再运行本脚本。\n' >&2
    exit 1
fi
if pgrep -f '/快捷录屏\.app/Contents/MacOS/QuickRegionRecorder$' >/dev/null; then
    printf '请结束正在进行的录制，并从菜单栏退出快捷录屏后再更新。\n' >&2
    exit 1
fi

app_name='快捷录屏.app'
app_dir="$HOME/Applications"
if [[ -d "/Applications/$app_name" && ! -e "$app_dir/$app_name" ]]; then
    app_dir=/Applications
fi
installed="$app_dir/$app_name"
if [[ -e "$installed" ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installed/Contents/Info.plist")"
    if [[ "$bundle_id" != com.kongdexi.quick-region-recorder ]]; then
        printf '目标位置已有别的应用：%s\n' "$installed" >&2
        exit 1
    fi
fi

mkdir -p "$app_dir"
stage="$(mktemp -d "$app_dir/.quick-region-install.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
"$project_dir/build.sh" "$stage/$app_name"

register_app() {
    local registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$registrar" -f "$installed" &&
        pluginkit -a "$installed/Contents/PlugIns/QuickRegionFinderExtension.appex" &&
        pluginkit -e use -i com.kongdexi.quick-region-recorder.finder
}

backup="$stage/previous.app"
if [[ -e "$installed" ]]; then
    mv -- "$installed" "$backup"
fi
if ! mv -- "$stage/$app_name" "$installed" || ! register_app; then
    if [[ -e "$installed" ]]; then
        mv -- "$installed" "$stage/failed.app"
    fi
    if [[ -d "$backup" ]]; then
        mv -- "$backup" "$installed"
        register_app || true
    fi
    printf '未能安装快捷录屏。\n' >&2
    exit 1
fi

printf '已安装：%s\n' "$installed"
if [[ "${1:-}" == --chrome ]]; then
    "$project_dir/install-chrome.sh"
fi
