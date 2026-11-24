#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
[[ $# == 0 || ( $# == 1 && $1 == --zig-only ) ]] || { echo 'Usage: install-ci-native.sh [--zig-only]' >&2; exit 2; }
tool_dir="${RUNNER_TEMP:?}/cytoville-tools"
mkdir -p "$tool_dir"
filename=zig-x86_64-linux-0.16.0.tar.xz
# Official community list; every archive must match the existing pinned hash.
mapfile -t mirrors < <(printf '%s\n' https://pkg.hexops.org/zig https://ziglang.freetls.fastly.net https://zig.linus.dev/zig | shuf)
mirrors+=(https://ziglang.org/download/0.16.0)
downloaded=0
for mirror in "${mirrors[@]}"; do
  echo "Downloading pinned Zig from $mirror"
  if curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --connect-timeout 15 --max-time 180 "$mirror/$filename" -o "$tool_dir/zig.tar.xz"; then
    echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  $tool_dir/zig.tar.xz" | sha256sum --check --strict
    downloaded=1
    break
  fi
done
[[ $downloaded == 1 ]] || { echo 'All bounded Zig download attempts failed.' >&2; exit 1; }
echo 'Verified Zig archive; extracting.'
tar -xJf "$tool_dir/zig.tar.xz" -C "$tool_dir"
echo "$tool_dir/zig-x86_64-linux-0.16.0" >> "${GITHUB_PATH:?}"
[[ ${1:-} != --zig-only ]] || exit 0
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libasound2-dev libudev-dev libx11-dev libxrandr-dev libxi-dev libxkbcommon-dev libxkbcommon-x11-0 libwayland-dev libssl-dev openssl chezscheme xvfb xauth xdotool imagemagick libvulkan1 mesa-vulkan-drivers
git init "$tool_dir/Idris2"
git -C "$tool_dir/Idris2" remote add origin https://github.com/idris-lang/Idris2
git -C "$tool_dir/Idris2" fetch --depth=1 origin 15a3e4e70843f7a34100f6470c04b791330788df
git -C "$tool_dir/Idris2" checkout --detach FETCH_HEAD
# Upstream Idris2 bootstrap requires its own Makefile; no game Makefile is used.
make -C "$tool_dir/Idris2" bootstrap SCHEME=scheme PREFIX="$tool_dir/idris2"
make -C "$tool_dir/Idris2" install PREFIX="$tool_dir/idris2"
echo "$tool_dir/idris2/bin" >> "$GITHUB_PATH"
echo "IDRIS2_PREFIX=$tool_dir/idris2" >> "${GITHUB_ENV:?}"
