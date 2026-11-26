#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# != 1 || "$1" != /*.app ]]; then
    printf 'Usage: %s /absolute/staging/path/SmartRead.app\n' "$0" >&2
    exit 64
fi
app="$1"

Scripts/bootstrap-vlckit.sh
swift build -c release
build_path="$(swift build -c release --show-bin-path)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
install -m 755 "$build_path/SmartRead" "$app/Contents/MacOS/SmartRead"
install -m 644 Scripts/Info.plist "$app/Contents/Info.plist"
install -m 644 Sources/SmartRead/Resources/SmartRead.icns "$app/Contents/Resources/SmartRead.icns"
ditto "$build_path/SmartRead_SmartRead.bundle" "$app/Contents/Resources/SmartRead_SmartRead.bundle"
vlc_root=".build/dependencies/vlckit-3.7.3"
ditto "$vlc_root/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$app/Contents/Frameworks/VLCKit.framework"
install -m 644 "$vlc_root/COPYING.txt" "$app/Contents/Resources/VLCKit-LICENSE.txt"
codesign --force --sign - "$app/Contents/Frameworks/VLCKit.framework"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
# Update the bundle timestamp so macOS reloads its icon after an in-place build.
touch "$app"
printf '%s\n' "$app"
