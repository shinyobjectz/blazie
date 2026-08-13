defmodule Blazie.MixProject do
  use Mix.Project

  def project do
    [
      app: :blazie,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: [
        blazie: [
          include_executables_for: [:unix],
          # Everything the release needs to differ by comes from the
          # environment at boot, so one artefact runs anywhere.
          applications: [blazie: :permanent]
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
      mod: {Blazie.Application, []}
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
      {:wasmex, "~> 0.15"},
      {:luerl, "~> 1.5"},
      # CORS is security-relevant and stable; doctrine 18 says a maintained
      # library beats one of ours for exactly this shape of requirement.
      {:cors_plug, "~> 3.0"}
    ]
  end
end
