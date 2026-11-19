defmodule RsolvHost.BaseFactsRailsgoatTest do
  # The Rails base-facts contract fixture (verify base-built plan, H′2; design
  # spec §5.4 protocol). The probe list is the platform's own
  # (rsolv-platform test/fixtures/exported/base_probes.json at 66d4fb2a,
  # `VerifyPlans.probes("rspec", true)`); the repository is railsgoat's real
  # files at arubis/railsgoat-vulnerability-demo e2cd64e9, committed with
  # their real modes. The facts read here are exported for the platform's
  # railsgoat eligibility tests (P2.2, P2.3), which use them unchanged.
  use ExUnit.Case, async: true

  alias RsolvCore.{BaseFacts, ChangeSet}
  alias RsolvHost.{BaseFactsReader, Exec}

  @fixtures Path.expand("../fixtures", __DIR__)
  @exported Path.join(@fixtures, "exported/base_facts_railsgoat.json")
  # railsgoat e2cd64e9's `git ls-files -s` modes: both of these are 100755.
  @files %{
    "Gemfile" => 0o644,
    "Gemfile.lock" => 0o644,
    ".ruby-version" => 0o644,
    ".rspec" => 0o644,
    "config/database.yml" => 0o755,
    "db/schema.rb" => 0o755
  }

  setup do: RsolvHost.VerifyDocker.unique_tmp_dir()

  defp fixture(path), do: File.read!(Path.join([@fixtures, "railsgoat", path]))

  # Fixed identity and dates, so the base SHA, and with it the export, is the
  # same on every run.
  defp git(dir, args) do
    env =
      [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}] ++
        for role <- ~w(AUTHOR COMMITTER),
            {key, value} <- [
              {"NAME", "t"},
              {"EMAIL", "t@example.com"},
              {"DATE", "1700000000 +0000"}
            ],
            do: {"GIT_#{role}_#{key}", value}

    {out, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    String.trim(out)
  end

  defp railsgoat(dir) do
    checkout = Path.join(dir, "railsgoat")

    for {path, mode} <- @files do
      full = Path.join(checkout, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, fixture(path))
      File.chmod!(full, mode)
    end

    git(checkout, ["init", "-q"])
    git(checkout, ["add", "-A"])
    git(checkout, ["commit", "-q", "-m", "railsgoat e2cd64e9"])
    {checkout, git(checkout, ["rev-parse", "HEAD"])}
  end

  defp probes, do: Path.join(@fixtures, "base_probes.json") |> File.read!() |> JSON.decode!()

  # The platform's own pretty JSON (rsolv-platform `Rsolv.ExportedFixture`).
  defp pretty(term),
    do:
      [term |> JSON.encode!() |> :json.decode() |> :json.format(), "\n"] |> IO.iodata_to_binary()

  describe "base facts for a Rails run's probes, on railsgoat" do
    setup %{tmp_dir: dir} do
      {checkout, base} = railsgoat(dir)
      {:ok, facts} = BaseFactsReader.read(checkout, base, probes(), exec: Exec)
      %{facts: facts, paths: facts.paths}
    end

    test "carries each manifest Ruby eligibility reads as a blob of its real bytes and mode",
         %{paths: paths} do
      for {path, mode} <- [
            {"Gemfile", "100644"},
            {"Gemfile.lock", "100644"},
            {".ruby-version", "100644"},
            {"config/database.yml", "100755"}
          ] do
        bytes = fixture(path)

        assert %{type: :blob, mode: ^mode, content: ^bytes} = paths[path], path
        assert paths[path].sha == ChangeSet.blob_sha(bytes), path
      end
    end

    test "has db as a tree, because db/schema.rb is committed, and no test DB in it",
         %{paths: paths} do
      assert paths["db"] == %{type: :tree}
      assert paths["db/test.sqlite3"] == %{type: :missing}
      assert paths["storage/test.sqlite3"] == %{type: :missing}
    end

    test "has every other probe missing, the #355 pytest probes among them", %{paths: paths} do
      present = ~w(Gemfile Gemfile.lock .ruby-version config/database.yml)

      for path <- probes() -- present do
        assert paths[path] == %{type: :missing}, path
      end

      for path <- ~w(requirements.txt pyproject.toml .python-version .tool-versions spec),
          do: assert(path in probes(), path)
    end

    test "covers exactly the probes and their ancestors", %{paths: paths} do
      {:ok, required} = BaseFacts.required_paths(probes())
      assert paths |> Map.keys() |> Enum.sort() == required
    end

    # The platform copies this file; on a difference it's rewritten here and
    # the test fails, so the change is committed deliberately.
    test "is exported as test/fixtures/exported/base_facts_railsgoat.json", %{facts: facts} do
      expected = pretty(BaseFacts.to_json(facts))

      unless File.read(@exported) == {:ok, expected} do
        File.mkdir_p!(Path.dirname(@exported))
        File.write!(@exported, expected)
        flunk("#{@exported} was stale and has been rewritten; review and commit it")
      end
    end
  end
end
