defmodule Blazie.Backup.Target do
  @moduledoc """
  Where copies go. Three functions, because a backup needs no more.

  This is the same seam `Blazie.Store` is: nothing above it knows whether
  bytes are landing in a directory or in object storage, so the destination is
  a configuration line rather than a rewrite. It is deliberately not a word —
  doctrine 12 — because the engine manages it and nobody writing facts ever
  names one.

  A target does not have to be able to delete, and none of them do. A backup
  that can erase its own history is one bad tick away from being no backup, and
  retention belongs to the bucket's own lifecycle rules where an attacker who
  has the node's credentials still cannot reach it.
  """

  @type opts :: keyword()
  @type key :: String.t()

  @doc "Put bytes at a key, replacing whatever was there."
  @callback put(opts(), key(), binary()) :: :ok | {:error, term()}

  @doc "Get the bytes at a key."
  @callback get(opts(), key()) :: {:ok, binary()} | {:error, :missing | term()}

  @doc "Every key under a prefix."
  @callback list(opts(), prefix :: String.t()) :: {:ok, [key()]} | {:error, term()}
end

defmodule Blazie.Backup.Target.Directory do
  @moduledoc """
  Copies into a directory.

  Right for a test, and right for a second disk or a mounted volume. Wrong as
  the only copy on the machine being backed up, which is not a thing this
  module can prevent and is worth saying out loud.
  """

  @behaviour Blazie.Backup.Target

  @impl true
  def put(opts, key, bytes) do
    path = path(opts, key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         # Written beside and renamed, so an interrupted put leaves the previous
         # copy rather than a truncated one.
         tmp = path <> ".writing",
         :ok <- File.write(tmp, bytes) do
      File.rename(tmp, path)
    end
  end

  @impl true
  def get(opts, key) do
    case File.read(path(opts, key)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :missing}
      other -> other
    end
  end

  @impl true
  def list(opts, prefix) do
    root = root(opts)

    case File.stat(root) do
      {:ok, _} ->
        {:ok,
         root
         |> walk()
         |> Enum.map(&Path.relative_to(&1, root))
         |> Enum.filter(&String.starts_with?(&1, prefix))
         |> Enum.reject(&String.ends_with?(&1, ".writing"))
         |> Enum.sort()}

      {:error, :enoent} ->
        {:ok, []}

      {:error, why} ->
        {:error, why}
    end
  end

  defp walk(path) do
    case File.ls(path) do
      {:ok, entries} -> Enum.flat_map(entries, &walk(Path.join(path, &1)))
      {:error, :enotdir} -> [path]
      {:error, _} -> []
    end
  end

  defp path(opts, key), do: Path.join(root(opts), key)

  defp root(opts), do: Keyword.fetch!(opts, :root)
end
