defmodule Blazie.Package do
  @moduledoc """
  A package is a fact — the shared library, content-addressed and versioned.

  Vendored/approved Lua libraries live as facts in ONE library world
  (`{:"$library"}`), which — like the Graph — no tenant names and everyone
  reads. Publishing is an append: `{name@version, ...}` carrying the source,
  a content hash, and the provenance of who vetted it (the `by` on the fact).
  Resolution is by name to the newest version (semver-ordered), or
  name@version exact; an unknown name refuses with the shelf of what exists.

  A version is immutable once it means something: republishing the same
  name@version with the same bytes is idempotent, with *different* bytes is
  refused — so a `require "json@1.0.0"` means one thing forever, which is the
  whole point of pinning.

  This is the prelude shelf generalized from a fixed file list to a queryable
  registry, and the mechanism `require()` (the capability) resolves against.
  """

  alias Blazie.{Attribute, Snapshot, World}

  @type refusal :: %{problem: atom(), repair: String.t()}

  @seed Attribute.define("name", answers: "name", cardinality: "many") ++
          Attribute.define("version", answers: "name", cardinality: "many") ++
          Attribute.define("source", answers: "any", cardinality: "many") ++
          Attribute.define("hash", answers: "name", cardinality: "many") ++
          Attribute.define("license", answers: "name", cardinality: "many")

  @doc "The one shared library world — no tenant names it."
  @spec world() :: World.name()
  def world, do: :"$library"

  @doc """
  Publish a package version. Returns `{:ok, "name@version"}`.

  Idempotent for identical bytes; refuses different bytes under a version that
  already exists (`:version_immutable`).
  """
  @spec publish(String.t(), String.t(), binary(), keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def publish(name, version, source, opts \\ []) do
    id = "#{name}@#{version}"
    hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    {:ok, w} = open(opts)
    snapshot = Snapshot.open([w])

    case Snapshot.value(snapshot, id, "hash") do
      nil ->
        facts =
          [
            {id, "is", "package"},
            {id, "name", name},
            {id, "version", version},
            {id, "source", source, Keyword.get(opts, :by, "operator")},
            {id, "hash", hash}
          ] ++ maybe_license(id, opts)

        {:ok, _} = World.append(w, facts)
        {:ok, id}

      ^hash ->
        {:ok, id}

      _other ->
        {:error,
         %{
           problem: :version_immutable,
           repair:
             "#{id} already exists with different bytes. A version is immutable once it means " <>
               "something — publish #{name}@<a new version> instead."
         }}
    end
  end

  @doc """
  Resolve a package name (newest version) or `name@version` (exact) to its
  source. Refuses an unknown name with the catalog.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t(), binary()} | {:error, refusal()}
  def resolve(request, opts \\ []) do
    {:ok, w} = open(opts)
    snapshot = Snapshot.open([w])

    case String.split(request, "@", parts: 2) do
      [name, version] ->
        id = "#{name}@#{version}"

        case Snapshot.value(snapshot, id, "source") do
          nil -> {:error, unknown(request, snapshot)}
          source -> {:ok, id, source}
        end

      [name] ->
        case newest(snapshot, name) do
          nil ->
            {:error, unknown(name, snapshot)}

          version ->
            {:ok, "#{name}@#{version}", Snapshot.value(snapshot, "#{name}@#{version}", "source")}
        end
    end
  end

  @doc "Every package name and its versions, semver-sorted."
  @spec catalog(keyword()) :: %{String.t() => [String.t()]}
  def catalog(opts \\ []) do
    {:ok, w} = open(opts)
    snapshot = Snapshot.open([w])

    snapshot
    |> Snapshot.find(attribute: "is", value: "package")
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.group_by(
      &Snapshot.value(snapshot, &1, "name"),
      &Snapshot.value(snapshot, &1, "version")
    )
    |> Map.new(fn {name, versions} -> {name, Enum.sort(versions, &semver_lte/2)} end)
  end

  # ── the install gate (a judged job) ──────────────────────────────────────────

  @approved_licenses ~w(MIT MIT-0 BSD-2-Clause BSD-3-Clause Apache-2.0 ISC Unlicense CC0-1.0 Zlib)

  # C-extension markers: a pure-Lua library never requires these, and Luerl
  # cannot load a .so anyway — so their presence means the package is not what
  # this library holds.
  @c_markers ~w(ffi cjson lpeg lfs luasocket lsqlite3 luasql posix)

  @doc """
  Vet a package's source — the gate every install passes before landing.

  Three checks, each reported: the license is on the approved list, the
  source names no C-extension module, and it SMOKE-TESTS under Luerl (loads
  and returns without raising — the discipline the vendored shelf uses).
  Returns `{:ok, report}` when all pass, else `{:error, report}` with the
  failing check and a repair.
  """
  @spec vet(String.t(), String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def vet(_name, _version, source, opts \\ []) do
    license = Keyword.get(opts, :license)

    license_check =
      if license in @approved_licenses, do: :ok, else: {:rejected, license}

    c_marker =
      Enum.find(@c_markers, fn m ->
        Regex.match?(~r/require\s*\(?\s*['"]#{m}['"]/, source)
      end)

    no_c = if c_marker, do: {:rejected, c_marker}, else: :ok

    smoke =
      case Blazie.Lua.run(source, as: :formula, deadline: 2_000) do
        {:ok, _} -> :ok
        {:error, refusal} -> {:rejected, refusal.repair}
      end

    report = %{license: license_check, no_c: no_c, smoke: smoke}

    cond do
      license_check != :ok ->
        {:error,
         Map.put(
           report,
           :repair,
           "license #{inspect(license)} is not approved. Allowed: #{Enum.join(@approved_licenses, ", ")}."
         )}

      no_c != :ok ->
        {:error,
         Map.put(
           report,
           :repair,
           "the source requires #{inspect(c_marker)}, a C extension — this library holds pure Lua only, which Luerl can run."
         )}

      smoke != :ok ->
        {:error,
         Map.put(report, :repair, "the package does not run under Luerl: #{elem(smoke, 1)}")}

      true ->
        {:ok, report}
    end
  end

  @doc """
  Install a package from outside — a job's action, never a guest's.

  `fetch:` is the network boundary (in production `http.get` through the
  Secret-plane credential proxy; injected here so the gate is testable
  without a network): `(name) -> {:ok, source, license} | {:error, why}`.
  The fetched source is VETTED, and only a clean package lands as a fact.
  Returns `{:ok, "name@version"}` or `{:error, report}` — a fetch failure or
  a failed check is surfaced, never swallowed.
  """
  @spec install(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def install(name, version, opts) do
    fetch = Keyword.get(opts, :fetch, &default_fetch/1)

    case fetch.(name) do
      {:ok, source, license} ->
        case vet(name, version, source, license: license) do
          {:ok, _report} ->
            publish(name, version, source, Keyword.put(opts, :license, license))

          {:error, report} ->
            {:error, report}
        end

      {:error, why} ->
        {:error, %{fetch: why, repair: "upstream fetch failed: #{why}"}}
    end
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp open(opts) do
    name = Keyword.get(opts, :library, world())

    with {:ok, w} <- World.open(name) do
      if World.tx(w) == 0, do: {:ok, _} = World.append(w, Attribute.seed() ++ @seed)
      {:ok, w}
    end
  end

  defp newest(snapshot, name) do
    snapshot
    |> Snapshot.find(attribute: "name", value: name)
    |> Enum.map(&Snapshot.value(snapshot, &1.id, "version"))
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(&semver_lte/2)
    |> List.last()
  end

  defp unknown(request, snapshot) do
    shelf =
      snapshot
      |> Snapshot.find(attribute: "is", value: "package")
      |> Enum.map(&Snapshot.value(snapshot, &1.id, "name"))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(", ")

    %{
      problem: :no_such_package,
      repair:
        "#{inspect(request)} is not in the library. Available: #{if(shelf == "", do: "(empty)", else: shelf)}."
    }
  end

  # The production fetch boundary: reach the package bytes through the egress
  # door. A source string of "luarocks:name@version" or "git:host/o/r@ref"
  # names where; anything else is a plain URL. Left injectable so the vetting
  # gate is testable without a network (the install tests do exactly that).
  defp default_fetch(name) do
    egress = Application.get_env(:blazie, :egress, [])

    result =
      case String.split(name, ":", parts: 2) do
        ["luarocks", spec] ->
          [n, v] = String.split(spec, "@", parts: 2)
          Blazie.Egress.luarocks(n, v, egress)

        ["git", spec] ->
          [repo, ref] = String.split(spec, "@", parts: 2)
          Blazie.Egress.git(repo, ref, egress)

        _ ->
          Blazie.Egress.webfetch(name, egress)
      end

    case result do
      # A fetched rock/tarball is bytes; the license rides in the package
      # metadata a real fetcher would parse. Absent one, MIT is not assumed —
      # the caller must pass license: or an injected fetch that supplies it.
      {:ok, bytes} -> {:ok, bytes, nil}
      {:error, refusal} -> {:error, refusal.repair}
    end
  end

  defp maybe_license(id, opts) do
    case Keyword.get(opts, :license) do
      nil -> []
      license -> [{id, "license", license}]
    end
  end

  # a <= b by numeric semver components (missing components are 0).
  defp semver_lte(a, b), do: parts(a) <= parts(b)

  defp parts(v) do
    v
    |> String.split(".")
    |> Enum.map(fn s ->
      case Integer.parse(s) do
        {n, _} -> n
        :error -> 0
      end
    end)
  end
end
