# Release runbook

Two workflows publish everything this repository releases (ADR-077, amendment of 2026-11-05):

| Workflow | Tag | Assets |
|---|---|---|
| `.github/workflows/host-erts.yml` | `erts-otp-<OTP version>` | `linux_x86_64.tar.gz`, `linux_aarch64.tar.gz`, `SHA256SUMS`, `provenance.sigstore.jsonl` |
| `.github/workflows/host-release.yml` | `host-v<app version>` | `rsolv-host-linux-x86_64`, `rsolv-host-linux-aarch64`, `SHA256SUMS`, `provenance.sigstore.jsonl` |

Both have the same three jobs:
1. **`build`**, once per architecture, natively on `ubuntu-24.04` and `ubuntu-24.04-arm`, with `contents: read` only and no caches. On a tag it first checks that the tagged commit is a first-parent commit of `main` (a merge commit `main` itself passed through, never a commit from inside a merged branch).
2. **`attest`**: build provenance for the assets (`actions/attest-build-provenance`), verified straight away with the flags below. It runs no repository code.
3. **`publish`**, tags only, in the `release` environment, so it waits for the owner's approval. It's the only job with `contents: write`. It re-verifies every asset against the attestation bundle with the same flags (the approval wait can be long, so it doesn't trust the artifact it downloads), then creates a draft release, attaches the assets, then publishes it. With release immutability on, the assets and the tag can't change after that.

A pull request that touches either workflow or anything they build from (`erts.lock`, the build scripts and, for `host-release.yml`, `rsolv_host/mix.exs`, `mix.lock`, `config/`, `rel/`, `patches/` and `rsolv_core/`) runs `build` and `attest` as a dry run. `publish` never runs on a pull request.

Repository settings this relies on (owner setup, plan 3d): tag rulesets (only admins create `host-v*` and `erts-otp-*`; nobody updates or deletes them), the `release` environment (owner as required reviewer, deployments only from those tags), and immutable releases.

## Cutting a release (owner)

Use a clone where `git remote get-url origin` is `RSOLV-dev/rsolv-host`. The `env -u GITHUB_TOKEN` keeps an environment token from shadowing your own `gh` login.

### The ERTS (once per OTP version)

Needed only when `rsolv_host/erts.lock` or `rsolv_host/scripts/erts-inputs.env` changes, and once before the first host release. The build must reproduce the locked SHA-256 exactly, or `build` fails.

```bash
git fetch -q origin
otp=$(git show origin/main:rsolv_host/erts.lock | jq -r .otp)
git tag "erts-otp-$otp" origin/main
env -u GITHUB_TOKEN git push origin "erts-otp-$otp"
```

Watch the run. It takes a few seconds to appear after the push, so wait for it first:

```bash
wf=host-erts.yml tag="erts-otp-$otp"
run=
for i in {1..60}; do
  run=$(env -u GITHUB_TOKEN gh run list --repo RSOLV-dev/rsolv-host --workflow "$wf" --branch "$tag" --event push \
    -L 1 --json databaseId --jq '.[0].databaseId // empty')
  [ -n "$run" ] && break
  sleep 5
done
env -u GITHUB_TOKEN gh run watch --repo RSOLV-dev/rsolv-host --exit-status "${run:?no $wf run for $tag after 5 minutes}"
```

When both `build` jobs and `attest` pass, `publish` waits: open the run, choose **Review deployments**, tick `release`, **Approve and deploy**. Then verify it (below).

### The host

1. Make sure `main` has what you're releasing: `version:` in `rsolv_host/mix.exs` is the new version, and `sandbox_image` in `rsolv_host/config/config.exs` is pinned by a real digest (the build refuses the all-zero placeholder). Both change through a normal pull request.
2. Make sure `erts-otp-<otp>` for `erts.lock`'s OTP is released. The build downloads it and verifies its attestation and its `erts.lock` SHA-256.
3. Tag and push:

   ```bash
   git fetch -q origin
   v=$(git show origin/main:rsolv_host/mix.exs | sed -n 's/^ *version: "\(.*\)",$/\1/p')
   git tag "host-v$v" origin/main
   env -u GITHUB_TOKEN git push origin "host-v$v"
   ```

4. Watch the run: the block above, with `wf=host-release.yml tag="host-v$v"`. Both builds smoke-test their binary (`rsolv_host/scripts/smoke.sh --online`) before uploading it.
5. Approve the `release` environment for `publish`.
6. Verify it (below), then pin it on `rsolv-action` with `scripts/pin-host.sh <version>` in a pull request (see [The pin script's contract](#the-pin-scripts-contract)).

### If a run fails

- **Approval later than 30 days:** the run's artifacts expire after 30 days, so a late `publish` fails at the download. Nothing was released: re-run the **whole** run (`gh run rerun <run id> --repo RSOLV-dev/rsolv-host`, not `--failed`), so `build` and `attest` make fresh artifacts, then approve again.
- **Before `publish`:** nothing was released. If the cause was transient, re-run the failed jobs. If it needs a code change, merge the fix and release a **new version**: the tag can't be moved or deleted.
- **During `publish`:** it may leave a draft release. Drafts aren't immutable: delete it with `env -u GITHUB_TOKEN gh release delete <tag> --repo RSOLV-dev/rsolv-host --yes` (without `--cleanup-tag`), then re-run `publish`.

## Verifying a release (anyone)

You need `gh` 2.102.0 or later, logged in. `gh release verify` arrived in 2.81.0 and `--source-ref`/`--source-digest` in 2.68.0, but before 2.97.0 `--signer-workflow` was an unescaped regex, and before 2.102.0 it matched only a prefix of the signing workflow and `--source-ref` ignored case. Older versions can pass an attestation these flags are meant to reject.

For host `v` (for example `0.1.0`), paste the whole block. It runs in a subshell with `set -euo pipefail`, so it stops at the first failed check, and its last line prints `verified` only if every check passed:

```bash
(
set -euo pipefail
tag=host-v0.1.0
repo=RSOLV-dev/rsolv-host
printf '%s\n' 2.102.0 "$(gh --version | awk 'NR==1{print $3}')" | sort -V -C   # gh is new enough
gh release download "$tag" --repo "$repo" --dir "$tag"
cd "$tag"
sha256sum -c SHA256SUMS
commit=$(gh api "repos/$repo/commits/refs/tags/$tag" --jq .sha)   # refs/tags/: a branch of the same name can't stand in
[[ $(gh api "repos/$repo/compare/$commit...main" --jq .status) =~ ^(ahead|identical)$ ]]   # the commit is on main
for f in rsolv-host-linux-x86_64 rsolv-host-linux-aarch64; do
  gh attestation verify "$f" --repo "$repo" \
    --signer-workflow "$repo/.github/workflows/host-release.yml" \
    --source-ref "refs/tags/$tag" \
    --source-digest "$commit" \
    --deny-self-hosted-runners
done
gh release verify "$tag" --repo "$repo"   # the release itself is immutable and attested
echo verified
)
```

What each flag pins:
- `--repo`: the attestation was made in this repository;
- `--signer-workflow`: by `host-release.yml`, not some other workflow here;
- `--source-ref`: from the release tag. Pull-request dry runs are attested too, from `refs/pull/<n>/merge`, so never verify a release without this flag;
- `--source-digest`: from the commit the tag names;
- `--deny-self-hosted-runners`: on a GitHub-hosted runner.

To verify offline, add `--bundle provenance.sigstore.jsonl` (an asset of the release). `gh` still fetches Sigstore's public trusted root unless you also pass `--custom-trusted-root` (from `gh attestation trusted-root`).

The on-`main` check here is reachability; the `build` job already refused anything but a first-parent commit of `main`, and `--source-digest` ties the binaries to that commit.

For the ERTS, use the same commands with `tag=erts-otp-<otp>`, the files `linux_x86_64.tar.gz` and `linux_aarch64.tar.gz`, and `--signer-workflow "$repo/.github/workflows/host-erts.yml"`. Their SHA-256s must also equal `rsolv_host/erts.lock` at that commit.

## The pin script's contract

`rsolv-action`'s `scripts/pin-host.sh <version>` (its plan, Task 5) doesn't exist yet. When it's written, it must do what the block above does, in a script that fails closed (`set -euo pipefail`) and writes nothing until every check has passed:

1. Refuse a version that doesn't match `^[0-9]+\.[0-9]+\.[0-9]+$`, and a `gh` older than 2.102.0.
2. `gh release download "host-v$version" --repo RSOLV-dev/rsolv-host` into a fresh temporary directory, then `sha256sum -c SHA256SUMS`.
3. Resolve the tag's commit with `gh api repos/RSOLV-dev/rsolv-host/commits/refs/tags/host-v$version --jq .sha`, never the bare tag name.
4. For each of `rsolv-host-linux-x86_64` and `rsolv-host-linux-aarch64`, run exactly:

   ```bash
   gh attestation verify "$f" --repo RSOLV-dev/rsolv-host \
     --signer-workflow RSOLV-dev/rsolv-host/.github/workflows/host-release.yml \
     --source-ref "refs/tags/host-v$version" \
     --source-digest "$commit" \
     --deny-self-hosted-runners
   ```

   `--source-ref` and `--source-digest` are both required: a pull-request dry run is attested by the same `--signer-workflow`, from `refs/pull/<n>/merge`, and only these flags reject it.
5. `gh release verify "host-v$version" --repo RSOLV-dev/rsolv-host`.
6. Only then write the two SHA-256s, taken from the verified `SHA256SUMS`.

An attestation shows where and how a binary was built. It doesn't make a compromised build trustworthy: the SHA-256 pins in RSOLV's workflows, reviewed pin PRs and the platform's workflow-SHA allowlist decide what runs.

## Rollback

Never by moving or deleting a tag (the rulesets refuse both). A bad release stays published; what changes is what points at it:

1. Open a pull request on `rsolv-action` that pins the previous good release's SHA-256s (`scripts/pin-host.sh <previous version>`), or, once it's fixed, a new version's. Merge it, and allowlist the new workflow commit on the platform.
2. Remove the bad release's workflow commit from the platform's `RSOLV_RUNNER_WORKFLOW_SHAS`, staging then production.
3. Say so in the bad release's notes (release title and notes stay editable on an immutable release; its assets and tag don't).
4. Fix forward with a new version (`host-v<next>`).
