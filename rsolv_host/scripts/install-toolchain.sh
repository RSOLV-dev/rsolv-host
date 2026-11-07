#!/usr/bin/env bash
# Installs the toolchain that compiles the release, every input checked against
# a SHA-256 committed here or in erts.lock (never setup-beam's unchecked
# downloads, or Hex and rebar3 fetched by `mix local.*`):
#   - OTP: the self-built ERTS tarball (build-erts.sh, from the pinned OTP
#     source) is a full OTP release; checked against erts.lock and installed,
#     so the OTP library BEAMs in the binary come from that source too;
#   - Elixir 1.20.2 precompiled for OTP 29 (elixir-otp-29.zip.sha256sum on the
#     v1.20.2 release);
#   - Hex 2.7.0 and rebar3 3.28.0 built for OTP 29, the files `mix local.hex`
#     and `mix local.rebar` pick for Elixir 1.20.2 on OTP 29 (their SHA-512s
#     in builds.hex.pm/installs/hex.csv and rebar.csv matched; checked
#     2026-11-06).
#   install-toolchain.sh <erts-dir> <dir>
# then put <dir>/otp/bin and <dir>/elixir/bin on PATH and set MIX_HOME=<dir>/mix.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
erts=${1:?usage: install-toolchain.sh <erts-dir> <dir>} dir=${2:?usage: install-toolchain.sh <erts-dir> <dir>}
arch=$(uname -m)
mkdir -p "$dir"
dir=$(realpath "$dir")

# fetch <url> <sha256> <file>: downloads, then fails unless the file matches.
fetch() {
  curl -fsSLo "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

tarball="$erts/linux_$arch.tar.gz"
want=$(jq -er --arg t "linux_$arch" '.targets[$t].sha256' "$here/../erts.lock")
echo "$want  $tarball" | sha256sum -c -
tar -xzf "$tarball" -C "$dir"
mv "$dir"/otp-*-linux-"$arch" "$dir/otp"
(cd "$dir/otp" && ./Install -minimal "$dir/otp" >/dev/null)

fetch https://github.com/elixir-lang/elixir/releases/download/v1.20.2/elixir-otp-29.zip \
  a9e88cd41fbbba7da6f6dc237a49dd2ed4e70457121035cc7fc56ad05582f394 "$dir/elixir-otp-29.zip"
unzip -q "$dir/elixir-otp-29.zip" -d "$dir/elixir"
fetch https://builds.hex.pm/installs/1.20.0/hex-2.7.0-otp-29.ez \
  6de1e1fef70462e2d77a5e7206e2c58fb7b8863161dae545080e87dc324861e3 "$dir/hex-2.7.0-otp-29.ez"
fetch https://builds.hex.pm/installs/1.18.4/rebar3-3.28.0-otp-29 \
  4df37f2f7570e0b5af15b5dcbad6b7a864202575d94e1d8663166c7643ee3a09 "$dir/rebar3"

export PATH="$dir/otp/bin:$dir/elixir/bin:$PATH" MIX_HOME="$dir/mix"
mix archive.install --force "$dir/hex-2.7.0-otp-29.ez" >/dev/null
mix local.rebar --force rebar3 "$dir/rebar3" >/dev/null
echo "OTP root: $(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')"
elixir --version | tail -1
mix hex.info | grep "^Hex:"
