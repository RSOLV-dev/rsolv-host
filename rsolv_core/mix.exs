defmodule RsolvCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :rsolv_core,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      test_ignore_filters: ["test/vectors/gen_patch_vectors.exs"]
    ]
  end

  def application, do: [extra_applications: [:crypto]]

  defp deps do
    [
      {:stream_data, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
