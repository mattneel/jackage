#!/bin/sh
# Fetch and verify the pinned Linux Zig toolchain inside a guest environment.
#
# The checkout stays clean: the toolchain is installed under a guest-native
# directory (default `$HOME/jckg/toolchain`), not inside the Windows checkout.
# The version comes from `.zigversion`, so the Windows and Linux environments
# always use the same compiler build. The archive digest is pinned below and
# was recorded from https://ziglang.org/download/index.json.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
version=$(tr -d ' \r\n' < "$script_dir/../.zigversion")

case "$(uname -m)" in
    x86_64)
        archive_name="zig-x86_64-linux-$version.tar.xz"
        pinned_sha256='1061dbb921f62b67765810609a80c17fa69eeced9f21e9a7e0d06b4e0d7a3715'
        ;;
    *)
        echo "no pinned Linux toolchain for architecture $(uname -m)" >&2
        exit 2
        ;;
esac

root=${JCKG_TOOLCHAIN_ROOT:-$HOME/jckg/toolchain}
destination="$root/zig-$version"

if [ -x "$destination/zig" ] && [ "$("$destination/zig" version)" = "$version" ]; then
    echo "pinned Zig $version already installed at $destination"
    exit 0
fi

url="https://ziglang.org/builds/$archive_name"
archive="$root/$archive_name"
mkdir -p "$root"

if [ ! -f "$archive" ]; then
    echo "downloading $url"
    curl -fsSL -o "$archive.partial" "$url"
    mv "$archive.partial" "$archive"
fi

actual_sha256=$(sha256sum "$archive" | cut -d' ' -f1)
if [ "$actual_sha256" != "$pinned_sha256" ]; then
    echo "SHA-256 mismatch for $url" >&2
    echo "  expected: $pinned_sha256" >&2
    echo "  actual:   $actual_sha256" >&2
    exit 3
fi

staging="$destination.staging"
rm -rf "$staging"
mkdir -p "$staging"
tar -xJf "$archive" -C "$staging" --strip-components=1

installed=$("$staging/zig" version)
if [ "$installed" != "$version" ]; then
    echo "extracted Zig reports '$installed', but .zigversion pins '$version'" >&2
    rm -rf "$staging"
    exit 4
fi

rm -rf "$destination"
mv "$staging" "$destination"
echo "Zig $installed installed at $destination"
