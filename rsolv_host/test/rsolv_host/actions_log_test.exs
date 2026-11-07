defmodule RsolvHost.ActionsLogTest do
  use ExUnit.Case, async: true

  alias RsolvHost.ActionsLog

  defp capture(fun) do
    {:ok, io} = StringIO.open("")
    fun.(io)
    {:ok, {_in, out}} = StringIO.close(io)
    out
  end

  describe "untrusted/2" do
    test "wraps the text in a stop-commands block with a fresh 32-hex token" do
      text = "::add-mask::x\n::error::y"
      out = capture(&ActionsLog.untrusted(text, &1))

      assert [_, token] = Regex.run(~r/\A::stop-commands::([0-9a-f]{32})\n/, out)
      assert out == "::stop-commands::#{token}\n#{text}\n::#{token}::\n"
      refute String.contains?(text, token)
    end

    test "uses a different token on every call" do
      first = capture(&ActionsLog.untrusted("same", &1))
      second = capture(&ActionsLog.untrusted("same", &1))

      refute first == second
    end
  end

  describe "mask/2" do
    test "writes an add-mask command for the secret" do
      assert capture(&ActionsLog.mask("rsolv_rt_secret", &1)) == "::add-mask::rsolv_rt_secret\n"
    end
  end

  describe "error/3" do
    test "writes one error line with an encoded title and a single-line text" do
      out = capture(&ActionsLog.error("RSOLV a:b,c%", "line one\r\nline two", &1))

      assert out == "::error title=RSOLV a%3Ab%2Cc%25::line one%0D%0Aline two\n"
    end
  end

  describe "set_output/3" do
    @describetag :tmp_dir

    test "appends name=value to the file", %{tmp_dir: dir} do
      path = Path.join(dir, "out")
      File.write!(path, "a=1\n")

      assert ActionsLog.set_output("outcome", "mitigated", path) == :ok
      assert File.read!(path) == "a=1\noutcome=mitigated\n"
    end

    test "when the value holds a newline or carriage return, refuses it", %{tmp_dir: dir} do
      path = Path.join(dir, "out")

      assert ActionsLog.set_output("outcome", "x\nevil=1", path) == {:error, :invalid_output}
      assert ActionsLog.set_output("outcome", "x\revil=1", path) == {:error, :invalid_output}
      refute File.exists?(path)
    end

    test "when the name is not lowercase letters and underscores, refuses it", %{tmp_dir: dir} do
      path = Path.join(dir, "out")

      assert ActionsLog.set_output("Out-come", "x", path) == {:error, :invalid_output}
      assert ActionsLog.set_output("a=b", "x", path) == {:error, :invalid_output}
    end
  end
end
