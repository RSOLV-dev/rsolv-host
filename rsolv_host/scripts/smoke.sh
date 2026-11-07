#!/usr/bin/env bash
# Smoke test of the real Burrito binary (plan Task 27 Step 7). Fails on the
# first broken expectation; prints what it observed for the PR record.
#   smoke.sh <binary> [--online]
set -euo pipefail
bin=$(realpath "${1:?usage: smoke.sh <binary> [--online]}")
online=${2:-}
work=$(mktemp -d)
export RUNNER_TEMP="$work/runner-temp"
mkdir -p "$RUNNER_TEMP"
case $(uname -m) in
  x86_64) interp=/lib64/ld-linux-x86-64.so.2 musl=71c35316aff45bbfd243d8eb9bfc4a58b6eb97cee09514cd2030e145b68107fb ;;
  aarch64) interp=/lib/ld-linux-aarch64.so.1 musl=6b558025200a5ed1308e2ce2675217afec71b6c5a9d561e52262ca948d59905e ;;
esac
loader=/tmp/libc-musl-$musl.so

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
# run <install-dir> <args...>: runs the binary from a scratch cwd, prints its exit code
run() {
  local dir=$1; shift
  (cd "$work" && RSOLV_HOST_INSTALL_DIR=$dir "$bin" "$@" >"$work/out" 2>&1) && echo 0 || echo $?
}
tree_digest() { (cd "$1" && find . -type f ! -name _metadata.json -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1); }

echo "binary: $bin ($(stat -c %s "$bin") bytes, sha256 $(sha256sum "$bin" | cut -d' ' -f1))"
if readelf -l "$bin" | grep -q 'Requesting program interpreter'; then
  echo "wrapper interpreter: $(readelf -l "$bin" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')"
else
  echo "wrapper: static (no ELF interpreter)"
fi

# 1. The musl loader hole: plant a non-ELF file where Burrito's precompiled ERTS
#    would look for its loader (moving any real one aside until the end). A
#    binary that used it couldn't start.
[ -e "$loader" ] && mv "$loader" "$work/loader.orig"
trap 'rm -f "$loader"; [ -e "$work/loader.orig" ] && mv "$work/loader.orig" "$loader"; rm -rf "$work"' EXIT
printf 'not a loader\n' >"$loader"
planted=$(sha256sum "$loader" | cut -d' ' -f1)
install="$RUNNER_TEMP/rsolv-host"
start=$(date +%s%N)
[ "$(run "$install" version)" = 0 ] || { cat "$work/out"; fail "cold version"; }
echo "cold start (version): $(( ($(date +%s%N) - start) / 1000000 )) ms"
version=$(grep -x 'rsolv-host [0-9.]*' "$work/out") || fail "version output: $(cat "$work/out")"
ok "version: $version"
[ "$(sha256sum "$loader" | cut -d' ' -f1)" = "$planted" ] || fail "the planted loader was replaced"
ok "a non-ELF file planted at $loader was ignored, and left as planted"

# 2. Every ELF in the extraction asks for the glibc loader, never musl or /tmp.
erts_root=$(find "$install/.burrito" -mindepth 1 -maxdepth 1 -type d -print -quit)
interps=$(find "$erts_root" -type f -exec sh -c 'readelf -l "$1" 2>/dev/null | sed -n "s/.*Requesting program interpreter: \(.*\)]/\1/p"' _ {} \; | sort | uniq -c)
echo "ELF interpreters in the extraction:"; echo "$interps"
echo "$interps" | grep -v "$interp" | grep -q . && fail "an ELF asks for another loader"
readelf -l "$erts_root"/erts-*/bin/beam.smp | grep -q "interpreter: $interp" || fail "beam.smp interpreter"
ok "beam.smp interpreter: $interp"
crypto=$(find "$erts_root" -name crypto.so -print -quit)
needed=$(readelf -d "$crypto" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')
case $needed in *libcrypto* | *libssl*) fail "crypto.so links a system OpenSSL: $needed" ;; esac
ok "crypto.so needs only: $needed(OpenSSL is static)"

# 3. Preflight: an install dir outside $RUNNER_TEMP is refused (exit 2).
outside=$(mktemp -d)
rc=$(run "$outside" version); rm -rf "$outside"
[ "$rc" = 2 ] || fail "install dir outside RUNNER_TEMP: exit $rc"
ok "install dir outside RUNNER_TEMP: exit 2"

# 4. selftest (offline, then online against the allowlisted names).
[ "$(run "$install" selftest)" = 0 ] || { cat "$work/out"; fail "selftest"; }
ok "selftest: $(grep '^selftest:' "$work/out" | tr '\n' ' ')"
if [ "$online" = --online ]; then
  [ "$(run "$install" selftest --online)" = 0 ] || { cat "$work/out"; fail "selftest --online (api.rsolv.ai.)"; }
  ok "selftest --online (api.rsolv.ai.): exit 0"
  [ "$(RSOLV_API_URL=https://api.rsolv.dev. run "$install" selftest --online)" = 0 ] || { cat "$work/out"; fail "selftest --online (api.rsolv.dev.)"; }
  ok "selftest --online (api.rsolv.dev.): exit 0"
  rc=$(RSOLV_API_URL=https://api.rsolv.dev run "$install" selftest --online)
  [ "$rc" = 2 ] || fail "URL without trailing dot: exit $rc"
  ok "selftest --online (https://api.rsolv.dev, no trailing dot): exit 2"
fi

# 5. Crash dumps. A bad kernel parameter makes the VM halt with "Kernel pid
#    terminated", which writes erl_crash.dump unless ERL_CRASH_DUMP_SECONDS=0
#    (rel/vm.args.eex, passed by Burrito's launcher as -args_file).
marker="$work/marker"; touch "$marker"
rc=$(ERL_FLAGS='-kernel logger_level bogus' run "$install" version)
[ "$rc" != 0 ] || fail "the crash trigger didn't crash"
# On CI the whole root filesystem is searched; elsewhere, everywhere a dump could
# land: the cwd and RUNNER_TEMP (both under $work), /tmp and $HOME.
if [ "${CI:-}" = true ]; then roots=(/ /tmp "$work"); depth=(); else roots=("$work" /tmp "$HOME"); depth=(-maxdepth 3); fi
dumps=$(find "${roots[@]}" "${depth[@]}" -xdev -name 'erl_crash.dump' -newer "$marker" -print 2>/dev/null || true)
[ -z "$dumps" ] || fail "crash dump written: $dumps"
grep -q 'Kernel pid terminated' "$work/out" || fail "the VM didn't report the crash"
ok "VM crash (exit $rc, 'Kernel pid terminated'): no erl_crash.dump anywhere"
# Control: the same trigger with crash dumps re-enabled does write one.
rc=$(ERL_FLAGS='-env ERL_CRASH_DUMP_SECONDS 10 -kernel logger_level bogus' run "$install" version)
if [ -s "$work/erl_crash.dump" ]; then
  ok "control (ERL_CRASH_DUMP_SECONDS=10 via ERL_FLAGS): erl_crash.dump written ($(stat -c %s "$work/erl_crash.dump") bytes)"
  rm -f "$work/erl_crash.dump"
else
  echo "note: control wrote no dump (exit $rc); vm.args may override ERL_FLAGS -env"
fi

# 6. Concurrent first runs. The reusable workflow serializes the first run;
#    this records what an unserialized race does, and checks it can't leave a
#    corrupt extraction behind for the next (warm) run to trust.
ref=$(tree_digest "$erts_root")
for round in 1 2 3; do
  race="$RUNNER_TEMP/race-$round"
  pids=()
  for i in 1 2 3 4; do
    (
      rc=0
      cd "$work" && RSOLV_HOST_INSTALL_DIR=$race "$bin" version >"$work/race-$round-$i.out" 2>&1 || rc=$?
      echo "$rc" >"$work/race-$round-$i.rc"
    ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  codes=$(cat "$work"/race-"$round"-*.rc | tr '\n' ' ')
  [ "$(run "$race" version)" = 0 ] || fail "warm run after race round $round"
  digest=$(tree_digest "$(find "$race/.burrito" -mindepth 1 -maxdepth 1 -type d -print -quit)")
  [ "$digest" = "$ref" ] || fail "race round $round left a different tree"
  ok "race round $round: 4 concurrent cold runs exited [$codes]; warm run 0; tree identical to a serial extraction"
done
echo "smoke: all checks passed"
