defmodule LazyRiver.MixProject do
  use Mix.Project

  def project do
    [
      app: :lazy_river,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LazyRiver.Application, []}
    ]
  end

  # No dependencies yet, and the order they arrive in is deliberate: storage
  # (SlateDB via Rustler), then the surface (Phoenix), then sandboxing (Wasmex)
  # when tenant code actually exists. The reasoning rides in the commits
  # that add each one.
  defp deps do
    []
  end
end
