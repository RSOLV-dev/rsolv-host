#!/usr/bin/env bash
# Installs Zig 0.16.0, the exact version Burrito 1.6.0 requires, from a pinned
# tarball (SHA-256 from ziglang.org/download/index.json, checked 2026-11-06).
#   install-zig.sh <dir>     then put <dir> on PATH
set -euo pipefail
dir=${1:?usage: install-zig.sh <dir>}
case $(uname -m) in
  x86_64) arch=x86_64 sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
  aarch64) arch=aarch64 sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
  *) echo "install-zig.sh: unsupported machine $(uname -m)" >&2; exit 2 ;;
esac
tarball="zig-$arch-linux-0.16.0.tar.xz"
mkdir -p "$dir"
curl -fsSLo "$dir/$tarball" "https://ziglang.org/download/0.16.0/$tarball"
echo "$sha  $dir/$tarball" | sha256sum -c -
tar -xJf "$dir/$tarball" -C "$dir" --strip-components=1
rm "$dir/$tarball"
"$dir/zig" version
