defmodule LazyRiver.MixProject do
  use Mix.Project

  def project do
    [
      app: :lazy_river,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: [
        lazy_river: [
          include_executables_for: [:unix],
          # Everything the release needs to differ by comes from the
          # environment at boot, so one artefact runs anywhere.
          applications: [lazy_river: :permanent]
        ]
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {LazyRiver.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Dependencies arrive in a deliberate order, and the order they arrive in is deliberate: storage
  # (SlateDB via Rustler), then the surface (Phoenix), then sandboxing (Wasmex)
  # when tenant code actually exists. The reasoning rides in the commits
  # that add each one.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:wasmex, "~> 0.15"}
    ]
  end
end
