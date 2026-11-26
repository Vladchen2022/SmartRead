#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
dependencies_directory="$project_directory/.build/dependencies"
archive_path="$dependencies_directory/VLCKit-3.7.3.tar.xz"
destination_path="$dependencies_directory/vlckit-3.7.3"
framework_path="$destination_path/VLCKit.xcframework"
mac_framework="macos-arm64_x86_64/VLCKit.framework"
install_id='@rpath/VLCKit.framework/Versions/A/VLCKit'
download_url="https://download.videolan.org/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz"
expected_sha256="019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"

prepare_framework() {
    local framework="$1/$mac_framework"
    local binary="$framework/Versions/A/VLCKit"
    if ! otool -D "$binary" | grep -Fqx "$install_id"; then
        install_name_tool -id "$install_id" "$binary"
        codesign --force --sign - "$framework"
    fi
}

if [[ -d "$framework_path" ]]; then
    prepare_framework "$framework_path"
    echo "VLCKit 3.7.3 is ready."
    exit 0
fi

mkdir -p "$dependencies_directory"

if [[ ! -f "$archive_path" ]]; then
    curl --fail --location --show-error \
        "$download_url" \
        --output "$archive_path"
fi

actual_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "VLCKit archive checksum mismatch." >&2
    exit 1
fi

temporary_directory=$(mktemp -d "$dependencies_directory/vlckit.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT
tar -xf "$archive_path" -C "$temporary_directory" --strip-components=1
prepare_framework "$temporary_directory/VLCKit.xcframework"

if [[ -e "$destination_path" ]]; then
    rm -rf "$destination_path"
fi
mv "$temporary_directory" "$destination_path"
trap - EXIT

echo "VLCKit 3.7.3 is ready."
