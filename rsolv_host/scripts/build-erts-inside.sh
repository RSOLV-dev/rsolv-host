#!/usr/bin/env bash
# Runs inside the build container (build-erts.sh). Output layout, matched to
# Burrito 1.6.0's precompiled ERTS tarballs: one top-level directory holding the
# OTP release, i.e. otp-<v>-linux-<arch>/{erts-<erts_v>/bin,lib/<app>-<v>/priv/lib/*.so,...}.
# Burrito copies erts-*/bin and every */lib/**/*.so from it into the release.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C TZ=UTC
# Every apt operation, from the first update on, uses the Ubuntu archive
# snapshot at $APT_SNAPSHOT (signed metadata fixes every package version). The
# snapshot is HTTPS-only (plain HTTP answers 301) and the image has no CA
# bundle, so build-erts.sh mounts the runner's CA file read-only; nothing comes
# from the live archive. The snapshot's "ubuntu" archive serves every
# architecture, arm64 included (its "ubuntu-ports" path answers 401).
snapshot="https://snapshot.ubuntu.com/ubuntu/$APT_SNAPSHOT/"
sed -i -E "s#https?://(archive|security|ports)\.ubuntu\.com/[a-z-]+/?#$snapshot#" /etc/apt/sources.list
outside=$(grep -rhE '^[[:space:]]*(deb|deb-src|URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null |
  grep -vF " $snapshot " || true)
[ -z "$outside" ] || { echo "apt source outside the snapshot: $outside" >&2; exit 1; }
echo "apt sources: $(grep -chE '^deb ' /etc/apt/sources.list) lines, all $snapshot"
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential autoconf libncurses-dev curl perl >/dev/null
cd /tmp
curl -fsSLo openssl.tgz "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
echo "$OPENSSL_SHA256  openssl.tgz" | sha256sum -c -
tar xzf openssl.tgz
(cd "openssl-$OPENSSL_VERSION" &&
  ./Configure --prefix=/opt/openssl --libdir=lib no-shared no-docs -fPIC >/dev/null &&
  make -s -j"$(nproc)" >/dev/null && make -s install_sw >/dev/null)
curl -fsSLo otp.tgz "https://github.com/erlang/otp/releases/download/OTP-$OTP_VERSION/otp_src_$OTP_VERSION.tar.gz"
echo "$OTP_SHA256  otp.tgz" | sha256sum -c -
tar xzf otp.tgz
cd "otp_src_$OTP_VERSION"
./configure --with-ssl=/opt/openssl --disable-dynamic-ssl-lib --without-javac --without-wx \
  --without-odbc --without-debugger --without-observer --without-et >/dev/null
make -s -j"$(nproc)" >/dev/null
top="otp-$OTP_VERSION-linux-$ARCH"
make -s release RELEASE_ROOT="/opt/$top" >/dev/null
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
  -C /opt -cf - "$top" | gzip -9n >"/out/linux_$ARCH.tar.gz"
chown "$HOST_UID:$HOST_GID" "/out/linux_$ARCH.tar.gz"
