# rsolv-host

The trusted client that RSOLV's reusable GitHub Actions workflows run on your runner, and the
core library it shares with the RSOLV platform. Apache-2.0.

## Status

This repository is at its first stage: only the shared core library, `rsolv_core/`, is here.
The host client (`rsolv_host/`) and its attested release binaries are planned and land in
later changes. Until they do, the trust model below is the design those changes must meet,
not behaviour you can run today.

## Trust model (planned)

- **What runs where.** RSOLV's AI model runs on the RSOLV platform. Its tool calls (read a file,
  run the tests) run on your runner, inside a sandbox container that `rsolv-host` starts: no
  runner tokens, no Docker socket, a non-root user, only a copy of your repository mounted, and
  network access only to GitHub and package registries through a filtering proxy.
- **Roles.** The scan role is run-wide: its run token covers one workflow run, not one issue.
  The work and publish roles are issue-bound: each run token covers one workflow run, one issue
  and one role.
- **What `rsolv-host` holds.** A short-lived RSOLV run token, obtained from GitHub Actions OIDC
  (no RSOLV secret is configured anywhere), and, in the scan and publish jobs only, the job's own
  `GITHUB_TOKEN`. Neither ever enters the sandbox.
- **What it trusts.** Nothing the sandbox returns: tool output, the patch and test reports are
  size-capped, untrusted bytes. After a sandbox starts, `rsolv-host` never runs git or opens a
  path in the mounted tree.
- **What it writes.**
  - In the scan job: GitHub issues and their labels. The titles and bodies are written inside
    the sandbox, and no signed decision covers them; `rsolv-host` bounds them with fixed caps on
    the number of issues and their size, and an allowlist of labels.
  - In the publish job: only what a decision signed by the platform (Ed25519) allows: two
    commits (the failing test, then the fix), one branch, one pull request, and the labels and
    comments the decision names.
- **How you know what runs.** RSOLV's workflows will pin each release binary by SHA-256, and the
  platform only accepts workflow commits on its allowlist. Every release will be built in this
  repository by GitHub-hosted runners and carry a build-provenance attestation:
  `gh attestation verify <binary> --repo RSOLV-dev/rsolv-host`.

## Protocol

The relay and token-exchange messages between `rsolv-host` and the RSOLV platform carry a
`protocol_version`. `rsolv-host` is the only supported client. The protocol may change in any
release; knowing it grants no access, because every request is bound to a run token issued for
one workflow run and role (and, for every role but scan, one issue).

## Exit codes

`rsolv-host` exits with one of these codes. They are a stable interface; changing one is a
breaking change. `rsolv-work.yml` retries once on 3.

| Code | Meaning | Annotation | Workflow behaviour |
|---|---|---|---|
| 0 | A model outcome was reached (any of them) | `::notice::` for a false positive | none |
| 1 | Bug in the host client | `::error title=RSOLV host client bug::`, asking for an issue on `RSOLV-dev/rsolv-host` with the run URL | none |
| 2 | Configuration, or something the customer can fix | `::error title=RSOLV configuration::` naming the fix (for example "Grant `id-token: write`") | none |
| 3 | Transient platform or network failure | `::error title=RSOLV transient failure::` | `rsolv-work.yml` retries once, only on 3 |
| 4 | Sandbox or runner infrastructure | `::error title=RSOLV sandbox setup::` naming the failed step | none |

The `work` role writes the step outputs `outcome` and `has_patch` (`true` or `false`), and a
job-summary row. `outcome` is one of:

- `mitigated`: a fix was produced and uploaded;
- `mitigation_failed`: the vulnerability was confirmed but no usable fix was produced;
- `false_positive`: VALIDATE found the finding is not a vulnerability;
- `not_validated`: VALIDATE could not confirm the vulnerability;
- `validated`: VALIDATE confirmed it, then the job failed (non-zero exit) before MITIGATE
  reported an outcome.

Annotations and summaries are fixed text plus host-controlled values; text from the sandbox or
an error response never reaches them.

## Layout

- `rsolv_core/`: what the platform and the host must agree on byte for byte: the relay
  protocol types, canonical JSON (RFC 8785, for the subset RSOLV signs, which has no floats),
  the change set and the signed decision envelope. It depends on nothing in the platform.
- `rsolv_host/` (planned): the host client, packaged with Burrito as a self-contained Linux
  binary.
