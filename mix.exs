defmodule Blazie.MixProject do
  use Mix.Project

  def project do
    [
      app: :blazie,
      version: "0.1.0",
      elixir: "~> 1.18",
      name: "blazie",
      description:
        "The backend agents run on: durable memory that records where every fact came " <>
          "from, a graph nobody had to model, sandboxes to run agent code in, and one " <>
          "line that touches the outside world.",
      source_url: "https://github.com/shinyobjectz/blazie",
      homepage_url: "https://blazie.dev",
      package: [
        licenses: ["Apache-2.0"],
        links: %{
          "Home" => "https://blazie.dev",
          "GitHub" => "https://github.com/shinyobjectz/blazie"
        },
        files:
          ~w(lib priv/static/brand .monty/ontology.db mix.exs README.md DESIGN.md LICENSE NOTICE)
      ],
      docs: [
        main: "readme",
        logo: "priv/static/brand/blazie-mark.png",
        extras: ["README.md", "DESIGN.md", "LICENSE"]
      ],
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

  # Two of these are here for what is next rather than for what runs.
  #
  # `wasmex` is the sandbox a JOB will spawn — Lua is the authoring surface for
  # formulas, jobs and queries, and WebAssembly is what an agent image runs in.
  # Nothing calls it yet. That is a plan, and it is written here as one.
  #
  # SlateDB used to be named here as "the destination" for storage, which read
  # like a decision and was never one. What actually ships is `Store.File` on
  # local disk, with `Backup.Target.S3` copying byte ranges into S3-compatible
  # object storage — R2 included, and hand-signed rather than dragging a
  # vendor SDK in. Putting the database ITSELF in object storage is a separate,
  # unmade decision; when it is made it belongs in a commit, not a comment.
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
