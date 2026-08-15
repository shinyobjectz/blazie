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
  # Lua on the BEAM (luerl) is the one guest runtime — authoring surface and
  # sandbox both. `wasmex` used to sit beside it as the lane for agent images
  # and WASI python; it was retired 2026-08-15 (docs/storage-plan.md, LT3):
  # one fence, one function answering "may this reach", and nothing
  # memory-unsafe in a guest's path.
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
      {:luerl, "~> 1.5"},
      # The storage engine under Store.SQLite (docs/storage-plan.md). A NIF —
      # the seam above it is the decision that counts.
      {:exqlite, "~> 0.27"},
      # wasm on the BEAM — OUR substrate (workbooks-sh), zero deps, pure
      # Elixir: an interpreter lane (correctness, green everywhere) and an
      # ASM/JIT lane (perf tier; parked on OTP 29 pending an upstream fix).
      # This is not the wasm runtime LT3 deleted: guests are ordinary BEAM
      # code in ordinary processes — Luerl's species, not wasmex's. Pinned
      # by SHA because the substrate under a fence is not a thing that
      # floats (docs/storage-plan.md, the TL track).
      {:tiny_lasers,
       git: "https://github.com/workbooks-sh/tiny-lasers.git",
       # washy v0.1: blocks pipe+redirect onward, bare /work paths, grep -c
       ref: "9be5072"},
      # The Elixir client, tested here against a real HTTP round trip so the
      # SDK and the surface cannot drift apart unnoticed.
      {:blazie_client, path: "clients/elixir", only: :test}
      # CORS is security-relevant and stable; doctrine 18 says a maintained
      # library beats one of ours for exactly this shape of requirement.
    ]
  end
end
