#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
support_dir="$HOME/Library/Application Support/快捷录屏/Chrome"
extension_dir="$support_dir/Extension"
host_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
host_name="com.kongdexi.quick_region_recorder"
host="$support_dir/QuickRegionChromeHost"

mkdir -p "$extension_dir" "$host_dir"
staged_host="$(mktemp "$support_dir/.host.XXXXXXXX")"
trap 'if [ -f "$staged_host" ]; then unlink "$staged_host"; fi' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -O \
    -target "$(uname -m)-apple-macosx15.0" \
    "$project_dir/ChromeHost/ChromeHost.swift" "$project_dir/Sources/RecorderCommand.swift" \
    -o "$staged_host"
codesign --force --sign - "$staged_host"
codesign --verify --strict "$staged_host"
mv -f -- "$staged_host" "$host"
cp "$project_dir/ChromeExtension/manifest.json" "$project_dir/ChromeExtension/background.js" "$extension_dir/"

python3 - "$host_name" "$host" "$host_dir" "$extension_dir/manifest.json" <<'PY'
import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile

name, host, directory, extension_manifest = sys.argv[1:]
key = json.loads(Path(extension_manifest).read_text())["key"]
digest = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32]
extension_id = digest.translate(str.maketrans("0123456789abcdef", "abcdefghijklmnop"))
manifest = {
    "name": name,
    "description": "快捷录屏",
    "path": host,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension_id}/"],
}
with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory, delete=False) as file:
    json.dump(manifest, file, ensure_ascii=False, indent=2)
    file.write("\n")
Path(file.name).replace(Path(directory) / f"{name}.json")
PY

printf '%s\n' "$extension_dir"
