defmodule RsolvHost.Egress do
  @moduledoc """
  The sandbox's default-deny egress (RFC-150 §9, ADR-076): a squid proxy that
  allows port 443 of the allowlisted hosts only, by CONNECT or plain HTTP;
  every other port is denied first. `dstdomain -n` disables reverse-DNS
  matching, so an IP literal never matches a name.

  The dependency hosts are the step-1 spike's. The runtime-download hosts let
  the sandbox install the runtime version a repository declares (owner
  decision Q4: `mise.toml`, `.mise.toml`, `.config/mise.toml`,
  `.tool-versions` or a per-language version file). They were measured by
  running `rsolv-sandbox bootstrap` behind a logging proxy on six demo
  repositories and four repositories pinning a version the image doesn't carry
  (3d Task 4, 2026-11-07):

  | Host | Needed by |
  |---|---|
  | `mise-versions.jdx.dev` | every mise runtime install (version index; GitHub attestation lookups) |
  | `nodejs.org` | Node (`mise.toml`, `node = "20.18.0"`) |
  | `mise-java.jdx.dev` | Java (`.tool-versions`, `java temurin-17.0.13+11`; the Gradle demo's Java 11) |
  | `tuf-repo-cdn.sigstore.dev` | Ruby and Python build attestations (`.config/mise.toml`, `ruby = "3.2.6"`; the Rails demo's `.ruby-version`) |
  | `archive.apache.org` | Maven, which a non-root sandbox installs with mise (the Gradle demo) |

  The builds themselves come from `github.com` and `*.githubusercontent.com`,
  and Erlang/Elixir from `builds.hex.pm`, which were already allowed.

  Composer, measured by `composer install` of a one-package project in the
  sandbox image behind this proxy (2026-11-07), needs only hosts already here:
  `repo.packagist.org` for metadata and `api.github.com`/`codeload.github.com`
  for the dist archive (`packagist.org` gets a download-count ping, which may
  fail). The sandbox image carries a SHA-256-pinned `composer.phar`, so
  `getcomposer.org` stays out: what reaches for it is mise's PHP plugin
  fetching the unpinned installer, and the 403 skips that step.
  """

  @external_resource squid_conf = Path.join([__DIR__, "..", "..", "priv", "squid.conf"])
  @squid_conf File.read!(squid_conf)

  # ponytail: union of all six ecosystems; step 5 narrows it per detected ecosystem and adds operator extensions
  @hosts ~w(
    github.com api.github.com codeload.github.com .githubusercontent.com
    registry.npmjs.org
    pypi.org files.pythonhosted.org
    rubygems.org index.rubygems.org
    hex.pm repo.hex.pm builds.hex.pm
    repo.maven.apache.org repo1.maven.org
    packagist.org repo.packagist.org
    mise-versions.jdx.dev nodejs.org mise-java.jdx.dev tuf-repo-cdn.sigstore.dev
    archive.apache.org
  )

  @doc "The allowlist file: one host per line (a leading dot allows its subdomains)."
  @spec allowlist() :: String.t()
  def allowlist, do: Enum.map_join(@hosts, &(&1 <> "\n"))

  @doc "The proxy's configuration: the step-1 spike's `squid.conf`, plus a deny for every port but 443."
  @spec squid_conf() :: String.t()
  def squid_conf, do: @squid_conf
end
