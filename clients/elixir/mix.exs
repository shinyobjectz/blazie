defmodule BlazieClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :blazie_client,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    # `:inets` and `:ssl` because the wire is `:httpc` — a client this thin
    # should not make its host choose an HTTP library.
    [extra_applications: [:logger, :inets, :ssl]]
  end

  defp deps do
    [{:jason, "~> 1.4"}]
  end
end
