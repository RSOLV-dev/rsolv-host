defmodule RsolvHost.MixProject do
  use Mix.Project

  @erts_lock "erts.lock" |> File.read!() |> JSON.decode!()

  def project do
    [
      app: :rsolv_host,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [
        {:rsolv_core, path: "../rsolv_core"},
        {:req, "~> 0.6"},
        {:burrito, "1.6.0"},
        {:plug, "~> 1.16", only: :test},
        {:stream_data, "~> 1.1", only: :test},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
      ],
      releases: [
        rsolv_host: [
          steps: [:assemble, &RsolvHost.Release.verify_erts/1, &Burrito.wrap/1],
          burrito: [targets: targets()]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl], mod: {RsolvHost.Application, []}]
  end

  defp targets do
    erts_dir = System.get_env("RSOLV_HOST_ERTS_DIR", "erts")

    for {name, %{"cpu" => cpu}} <- @erts_lock["targets"] do
      {String.to_atom(name),
       [os: :linux, cpu: String.to_atom(cpu), custom_erts: Path.join(erts_dir, "#{name}.tar.gz")]}
    end
  end
end
