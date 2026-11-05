# rsolv-host

The trusted client that RSOLV's reusable GitHub Actions workflows run on your runner, and the
core library it shares with the RSOLV platform. Apache-2.0.

## Trust model

- **What runs where.** RSOLV's AI model runs on the RSOLV platform. Its tool calls (read a file,
  run the tests) run on your runner, inside a sandbox container that `rsolv-host` starts: no
  runner tokens, no Docker socket, a non-root user, only a copy of your repository mounted, and
  network access only to GitHub and package registries through a filtering proxy.
- **What `rsolv-host` holds.** A short-lived RSOLV run token, obtained from GitHub Actions OIDC
  (no RSOLV secret is configured anywhere), and, in the scan and publish jobs only, the job's own
  `GITHUB_TOKEN`. Neither ever enters the sandbox.
- **What it trusts.** Nothing the sandbox returns: tool output, the patch and test reports are
  size-capped, untrusted bytes. After a sandbox starts, `rsolv-host` never runs git or opens a
  path in the mounted tree.
- **What it writes.** Only in the publish job, and only what a decision signed by the platform
  (Ed25519) allows: two commits (the failing test, then the fix), one branch, one pull request.
- **How you know what runs.** RSOLV's workflows pin each release binary by SHA-256, and the
  platform only accepts workflow commits on its allowlist. Every release is built in this
  repository by GitHub-hosted runners and carries a build-provenance attestation:
  `gh attestation verify <binary> --repo RSOLV-dev/rsolv-host`.

## Protocol

The relay and token-exchange messages between `rsolv-host` and the RSOLV platform carry a
`protocol_version`. `rsolv-host` is the only supported client. The protocol may change in any
release; knowing it grants no access, because every request is bound to a run token issued for
one workflow run, issue and role.

## Layout

- `rsolv_core/`: what the platform and the host must agree on byte for byte: the relay
  protocol types, RFC 8785 canonical JSON, the change set and the signed decision envelope.
  It depends on nothing in the platform.
- `rsolv_host/`: the host client, packaged with Burrito as a self-contained Linux binary.
