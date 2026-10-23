#!/bin/sh
# Disposable GitHub runner only. Official OpenWrt libraries, pinned revisions.
set -eu
root=$(mktemp -d)
prefix="$root/native"
for spec in 'libubox da2d205a5cf3e877c45a2eec488218cbaf452e7d' 'uci 74f6277aabffc943d026f406df57c22595134c42'; do
    set -- $spec
    curl -fLsS "https://codeload.github.com/openwrt/$1/tar.gz/$2" | tar xz -C "$root"
    cmake -S "$root/$1-$2" -B "$root/build-$1" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
    cmake --build "$root/build-$1" -j2
    cmake --install "$root/build-$1"
done
curl -fLsS https://github.com/SagerNet/sing-box/releases/download/v1.12.22/sing-box-1.12.22-linux-amd64.tar.gz -o "$root/sing-box.tar.gz"
printf '50a70a1b71064a7d8ef63737fbef2aa36c991d8dc1c54598b9513c2a15e25e9f  %s/sing-box.tar.gz\n' "$root" | sha256sum -c -
tar xzf "$root/sing-box.tar.gz" -C "$root"
cp "$root/sing-box-1.12.22-linux-amd64/sing-box" "$prefix/bin/"
printf '%s\n' "$prefix/bin" >> "$GITHUB_PATH"
printf 'LD_LIBRARY_PATH=%s/lib\n' "$prefix" >> "$GITHUB_ENV"
