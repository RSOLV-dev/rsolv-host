#!/usr/bin/env bash
# Builds a glibc ERTS tarball for Burrito's custom_erts (ADR-077; spike condition 2),
# natively for the machine's own architecture (never under emulation).
#   build-erts.sh <x86_64|aarch64> <out-dir>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "$here/erts-inputs.env"
arch=${1:-} out=${2:-}
case $arch in
  x86_64) platform=linux/amd64 ;;
  aarch64) platform=linux/arm64 ;;
  *) echo "usage: build-erts.sh x86_64|aarch64 <out-dir>" >&2; exit 2 ;;
esac
[ -n "$out" ] || { echo "usage: build-erts.sh x86_64|aarch64 <out-dir>" >&2; exit 2; }
[ "$(uname -m)" = "$arch" ] || { echo "build-erts.sh: $arch must be built on $arch (no emulation)" >&2; exit 2; }
out=$(realpath -m "$out")
mkdir -p "$out"
docker run --rm --network bridge --platform "$platform" \
  -v "$here:/scripts:ro" -v "$out:/out" \
  -v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro \
  -e OTP_VERSION="$OTP_VERSION" -e OTP_SHA256="$OTP_SHA256" \
  -e OPENSSL_VERSION="$OPENSSL_VERSION" -e OPENSSL_SHA256="$OPENSSL_SHA256" \
  -e APT_SNAPSHOT="$APT_SNAPSHOT" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  -e ARCH="$arch" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$BUILD_IMAGE" bash /scripts/build-erts-inside.sh
sha256sum "$out/linux_$arch.tar.gz"
