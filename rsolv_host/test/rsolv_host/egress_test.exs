defmodule RsolvHost.EgressTest do
  use ExUnit.Case, async: true

  alias RsolvHost.Egress

  describe "allowlist/0" do
    test "is the union of the spike's measured hosts, one per line" do
      assert Egress.allowlist() |> String.split("\n", trim: true) |> Enum.sort() ==
               Enum.sort(~w(
                 github.com api.github.com codeload.github.com .githubusercontent.com
                 registry.npmjs.org pypi.org files.pythonhosted.org rubygems.org index.rubygems.org
                 hex.pm repo.hex.pm builds.hex.pm repo.maven.apache.org repo1.maven.org
                 packagist.org repo.packagist.org
               ))
    end

    test "ends with a newline, as squid's file ACL expects" do
      assert String.ends_with?(Egress.allowlist(), "\n")
    end
  end

  describe "squid_conf/0" do
    test "is the spike's default-deny configuration" do
      conf = Egress.squid_conf()

      assert conf =~ ~s(acl allowed dstdomain -n "/etc/squid/allowlist.txt")
      assert conf =~ "http_access deny CONNECT !SSL_ports"
      assert conf =~ ~r/http_access allow allowed\nhttp_access deny all\n/
      assert conf =~ "cache deny all"
    end
  end
end
