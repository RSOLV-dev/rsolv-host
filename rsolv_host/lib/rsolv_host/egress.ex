defmodule RsolvHost.Egress do
  @moduledoc """
  The sandbox's default-deny egress (RFC-150 §9, ADR-076): a squid proxy that
  allows CONNECT to port 443 of the allowlisted hosts only. `dstdomain -n`
  disables reverse-DNS matching, so an IP literal never matches a name.
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
  )

  @doc "The allowlist file: one host per line (a leading dot allows its subdomains)."
  @spec allowlist() :: String.t()
  def allowlist, do: Enum.map_join(@hosts, &(&1 <> "\n"))

  @doc "The proxy's configuration, the step-1 spike's `squid.conf` byte for byte."
  @spec squid_conf() :: String.t()
  def squid_conf, do: @squid_conf
end
