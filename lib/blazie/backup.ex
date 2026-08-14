defmodule Blazie.Backup do
  @moduledoc """
  Copying the facts somewhere else, which is a **job** — it reaches outside.

  Being a job is not a technicality. It means a backup has a cadence, records
  what it copied as ordinary facts, records a failure as an ordinary fact, and
  is asked "when did this last succeed" with `Job.last_run/2` like anything
  else. None of that had to be built: the world already is the scheduler, the
  history, and the alerting surface.

  ## Only what changed crosses the wire

  A world is append-only, so a copy is a range of bytes and the next copy
  starts where the last one stopped. Segments are named for the range they
  hold, so a restore is a sort and a concatenation, and the remote never needs
  to support appending. The cost of a backup is what changed, not what exists —
  which is the property that lets a cadence be minutes rather than nightly.

  ## A copy stops at the last complete record

  The tail of a live log may be half-written, and half a record is not a fact.
  So each run copies only the prefix that scans cleanly, and the next run picks
  up from that boundary. This is the same rule `Store.File` replays by, for the
  same reason, which is why a restored log answers exactly what the original
  answers — including when the original has a torn tail.

  ## What is not copied

  **Checkpoints**, because they are derived: opening without one is correct and
  merely slower, so copying them would be paying to move something we can
  rebuild. Nothing else is skipped.

  **Keys are copied**, whole, every run. Facts without them are noise, and the
  local key store is already encrypted under a master the KMS holds — so what
  lands in the bucket is unopenable by whoever owns the bucket. A restore of an
  old key store cannot resurrect an erased subject either: the keyring
  reconciles against erasure tombstones every time it opens, and those are
  facts, so they are in the backup too.

  ## The backup's own world is always one transaction behind

  A run copies, and then `Job.run/4` writes what it copied — so the facts
  describing a run land after the copy that would have carried them, and
  `verify/1` called between runs always names `$backup` itself. The next run
  catches it up and creates the same lag again.

  This is stated rather than special-cased. Teaching `verify` to ignore one
  world would be teaching it to ignore the one that says whether backups are
  happening, and a check with an exception in it is a check nobody trusts.
  Anything else in that list is real.

  ## What this is not

  It is not replication and it is not a second node. It is the thing that means
  losing the disk costs whatever has happened since the last run, and nothing
  before it.

  Nor is it protection from a target that erases. No target here can delete,
  but the credentials a deployment holds usually can — so versioning and a
  retention window belong on the bucket, where a node that has been taken over
  cannot reach them.
  """

  alias Blazie.{Attribute, Job, World, Store}

  @id "backup"
  @world "$backup"
  # Still `ledgers/` after the rename to `world`: every segment already in the
  # bucket lives under this prefix, so moving it would strand every backup
  # anybody has taken. A key prefix is storage layout, not vocabulary.
  @ledgers_prefix "ledgers/"
  @keys_prefix "keys/"

  @doc "Where segments live in the bucket. Pinned by a test: objects exist under it."
  @spec ledgers_prefix() :: String.t()
  def ledgers_prefix, do: @ledgers_prefix

  @type report :: %{
          ledgers: non_neg_integer(),
          copied_bytes: non_neg_integer(),
          copied_segments: non_neg_integer(),
          keys: non_neg_integer(),
          held_bytes: non_neg_integer()
        }

  @doc "The attributes a run describes itself with."
  @spec seed() :: [{String.t(), String.t(), term()}]
  def seed do
    Attribute.define("copied_bytes", answers: "integer", cardinality: "many") ++
      Attribute.define("copied_segments", answers: "integer", cardinality: "many") ++
      Attribute.define("copied_keys", answers: "integer", cardinality: "many") ++
      Attribute.define("held_ledgers", answers: "integer", cardinality: "many") ++
      Attribute.define("held_bytes", answers: "integer", cardinality: "many")
  end

  @doc "The world a backup's own history is written to."
  @spec world() :: String.t()
  def world, do: @world

  @doc "Declare the backup as a job, with how often to run."
  @spec declare(keyword()) :: [tuple()]
  def declare(opts \\ []), do: Job.declare(@id, opts)

  @doc """
  The job. Its answer is what this run copied, which is why it is one.

  A refusal from the target is raised rather than returned, because `Job.run/4`
  turns a raise into a `failed` fact — so a target that is unreachable becomes
  a question the world can answer instead of a line in a log.
  """
  @spec job(keyword()) :: Job.t()
  def job(opts \\ []) do
    Job.new(@id, fn _snapshot ->
      case run(opts) do
        {:ok, report} ->
          [
            {@id, "copied_bytes", report.copied_bytes},
            {@id, "copied_segments", report.copied_segments},
            {@id, "copied_keys", report.keys},
            {@id, "held_ledgers", report.ledgers},
            {@id, "held_bytes", report.held_bytes}
          ]

        {:error, refusal} ->
          raise "backup could not copy: #{inspect(refusal)}"
      end
    end)
  end

  @doc """
  Copy everything not yet copied. Returns what this run did.

      run(ledger_dir: "/data/ledgers", key_dir: "/data/keys",
          target: {Target.S3, bucket: "blazie", ...})
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, map()}
  def run(opts \\ []) do
    {target, topts} = target(opts)

    with {:ok, held} <- held_map(target, topts),
         {:ok, copied} <- copy_ledgers(target, topts, ledger_dir(opts), held),
         {:ok, keys} <- copy_keys(target, topts, key_dir(opts)) do
      {:ok,
       %{
         ledgers: length(ledger_files(ledger_dir(opts))),
         copied_bytes: copied.bytes,
         copied_segments: copied.segments,
         keys: keys,
         held_bytes: copied.held_after
       }}
    end
  end

  @doc """
  Pull the copies back down.

  Refuses rather than overwrites. A restore that lands on top of live facts is
  how a partial outage becomes a total one, so this insists on somewhere empty
  and says which files are in the way.

  Pass `only: :keys` or `only: :ledgers` to restore one half — losing a key
  store while the facts are fine is a real thing that happens, and it is not
  the same operation as restoring a machine.
  """
  @spec restore(keyword()) :: {:ok, map()} | {:error, map()}
  def restore(opts \\ []) do
    {target, topts} = target(opts)
    only = Keyword.get(opts, :only, :all)

    with :ok <- nothing_in_the_way(opts, only),
         {:ok, ledgers} <- restore_ledgers(target, topts, ledger_dir(opts), only),
         {:ok, keys} <- restore_keys(target, topts, key_dir(opts), only) do
      {:ok,
       %{
         ledgers: ledgers.count,
         bytes: ledgers.bytes,
         keys: keys,
         incomplete: Enum.sort(ledgers.incomplete)
       }}
    end
  end

  @doc """
  Compare what is held against what is here, and name what has fallen behind.

  A copy nobody checked is a hope. This compares the *readable* local bytes,
  not the file size, so a torn tail is not reported as divergence — nothing
  recoverable is missing.
  """
  @spec verify(keyword()) :: {:ok, map()} | {:error, map()}
  def verify(opts \\ []) do
    {target, topts} = target(opts)
    dir = ledger_dir(opts)

    with {:ok, held} <- held_map(target, topts) do
      files = ledger_files(dir)

      divergent =
        files
        |> Enum.map(fn file ->
          at = Map.get(held, file, 0)
          %{world: file, local: at + Store.File.readable(Path.join(dir, file), at), held: at}
        end)
        |> Enum.reject(&(&1.local == &1.held))

      {:ok, %{ledgers: length(files), divergent: divergent}}
    end
  end

  @doc "How many bytes of this world the target holds."
  @spec held(keyword(), term()) :: non_neg_integer()
  def held(opts, name) do
    {target, topts} = target(opts)
    {:ok, map} = held_map(target, topts)
    Map.get(map, Store.File.filename(name), 0)
  end

  # ── started, not merely built ──────────────────────────────────────────────
  #
  # The deployment kept proving that a component written, tested and configured
  # but never started is the same as one that does not exist. So this is what
  # the supervision tree runs, rather than a module somebody has to remember.

  @doc "Start the backup job under a runner, seeding its world if it is new."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_runner, [opts]}, type: :worker}
  end

  @doc false
  def start_runner(opts) do
    every = Keyword.get(opts, :every, 900)
    {:ok, world} = World.open(@world)

    if World.tx(world) == 0 do
      World.append(world, Attribute.seed() ++ Job.seed() ++ seed() ++ declare(every: every))
    end

    Job.Runner.start_link(
      world: world,
      jobs: [job(opts)],
      every: :timer.seconds(every),
      name: __MODULE__.Runner
    )
  end

  # ── copying ────────────────────────────────────────────────────────────────

  defp copy_ledgers(target, topts, dir, held) do
    dir
    |> ledger_files()
    |> Enum.reduce_while({:ok, %{bytes: 0, segments: 0, held_after: 0}}, fn file, {:ok, acc} ->
      from = Map.get(held, file, 0)
      # The store says how far the file is whole records — the format is its,
      # and a second copy of its scan here went stale the day the format
      # changed and silently found nothing readable (measured: 39 tests).
      size = Blazie.Store.File.readable(Path.join(dir, file), from)
      chunk = tail(Path.join(dir, file), from)

      cond do
        size == 0 ->
          {:cont, {:ok, %{acc | held_after: acc.held_after + from}}}

        true ->
          key = "#{@ledgers_prefix}#{file}/#{from}-#{from + size}.segment"

          case target.put(topts, key, binary_part(chunk, 0, size)) do
            :ok ->
              {:cont,
               {:ok,
                %{
                  bytes: acc.bytes + size,
                  segments: acc.segments + 1,
                  held_after: acc.held_after + from + size
                }}}

            {:error, why} ->
              {:halt, {:error, %{problem: :put_refused, key: key, why: why}}}
          end
      end
    end)
  end

  defp copy_keys(target, topts, dir) do
    dir
    |> key_files()
    |> Enum.reduce_while({:ok, 0}, fn file, {:ok, n} ->
      case target.put(topts, @keys_prefix <> file, File.read!(Path.join(dir, file))) do
        :ok -> {:cont, {:ok, n + 1}}
        {:error, why} -> {:halt, {:error, %{problem: :put_refused, key: file, why: why}}}
      end
    end)
  end

  # ── restoring ──────────────────────────────────────────────────────────────

  defp restore_ledgers(_target, _topts, _dir, :keys),
    do: {:ok, %{count: 0, bytes: 0, incomplete: []}}

  defp restore_ledgers(target, topts, dir, _only) do
    with {:ok, keys} <- target.list(topts, @ledgers_prefix) do
      File.mkdir_p!(dir)

      keys
      |> Enum.group_by(&segment_file/1)
      |> Enum.reduce_while({:ok, %{count: 0, bytes: 0, incomplete: []}}, fn {file, segments},
                                                                            {:ok, acc} ->
        case fetch_segments(target, topts, segments) do
          {:ok, bytes} ->
            placed(Path.join(dir, file), bytes)

            # A hole in the segments means what came back stops short of what
            # the target nominally holds. Said out loud, because a restore that
            # quietly returns less than it could is the failure this whole
            # module exists to prevent.
            incomplete =
              if byte_size(bytes) < furthest(segments),
                do: [file | acc.incomplete],
                else: acc.incomplete

            {:cont,
             {:ok,
              %{
                count: acc.count + 1,
                bytes: acc.bytes + byte_size(bytes),
                incomplete: incomplete
              }}}

          {:error, why} ->
            {:halt, {:error, why}}
        end
      end)
    end
  end

  # Sorted by where they start, so they concatenate back into the file they
  # were cut from. Sorting the keys as strings would put 1000 before 999.
  #
  # Stops at a hole rather than concatenating across one. Bytes after a gap are
  # unreachable anyway — a scan cannot read past the garbage where the missing
  # segment should be — so taking the contiguous prefix loses nothing that was
  # recoverable, and gluing the pieces together would produce a file that looks
  # whole and is not.
  defp fetch_segments(target, topts, segments) do
    segments
    |> Enum.sort_by(&range/1)
    |> Enum.reduce_while({:ok, <<>>, 0}, fn key, {:ok, acc, at} ->
      {from, to} = range(key)

      cond do
        from > at ->
          {:halt, {:ok, acc, at}}

        # A segment already covered: a duplicate upload, not a hole.
        to <= at ->
          {:cont, {:ok, acc, at}}

        true ->
          case target.get(topts, key) do
            {:ok, bytes} when byte_size(bytes) == to - from ->
              # Only the bytes past what is already assembled. A segment that
              # starts before `at` is the ordinary crash — a run that copied,
              # died before recording, and re-copied a longer range from the
              # same offset. Concatenating it WHOLE duplicated the overlap,
              # shifted every later record out of frame, and the ledger then
              # opened clean having silently lost everything after the
              # overlap (C8, reproduced). The slice restores exactly the
              # contiguous bytes; if anything hostile hid in the overlap, the
              # ledger's own offset-bound CRC refuses it at open.
              {:cont, {:ok, acc <> binary_part(bytes, at - from, to - at), to}}

            {:ok, bytes} ->
              # A segment whose bytes are not its name is not a segment.
              {:halt,
               {:error,
                %{
                  problem: :segment_lying,
                  key: key,
                  why:
                    "#{key} names #{to - from} bytes and holds #{byte_size(bytes)}. " <>
                      "Nothing restored from it can be placed, so nothing was."
                }}}

            {:error, why} ->
              {:halt, {:error, %{problem: :segment_missing, key: key, why: why}}}
          end
      end
    end)
    |> case do
      {:ok, bytes, _at} -> {:ok, bytes}
      {:error, why} -> {:error, why}
    end
  end

  # Written beside and renamed in, the same move the checkpoint makes. A crash
  # mid-restore then leaves either no file or a whole one — never a short file
  # that opens cleanly as a shorter history, which is a partial restore
  # indistinguishable from a successful one.
  defp placed(path, bytes) do
    tmp = path <> ".restoring"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end

  defp restore_keys(_target, _topts, _dir, :ledgers), do: {:ok, 0}

  defp restore_keys(target, topts, dir, _only) do
    with {:ok, keys} <- target.list(topts, @keys_prefix) do
      File.mkdir_p!(dir)

      Enum.reduce_while(keys, {:ok, 0}, fn key, {:ok, n} ->
        case target.get(topts, key) do
          {:ok, bytes} ->
            placed(Path.join(dir, Path.basename(key)), bytes)
            {:cont, {:ok, n + 1}}

          {:error, why} ->
            {:halt, {:error, %{problem: :key_missing, key: key, why: why}}}
        end
      end)
    end
  end

  defp nothing_in_the_way(opts, only) do
    in_the_way =
      if(only in [:all, :ledgers], do: ledger_files(ledger_dir(opts)), else: []) ++
        if(only in [:all, :keys], do: key_files(key_dir(opts)), else: [])

    if in_the_way == [] do
      :ok
    else
      {:error,
       %{
         problem: :would_overwrite,
         found: in_the_way,
         repair:
           "Restore into an empty directory. #{length(in_the_way)} file(s) are already there, " <>
             "and a restore on top of live facts turns one outage into two. Move them aside, " <>
             "or pass only: :keys / only: :ledgers to restore just one half."
       }}
    end
  end

  # ── what the target already holds ──────────────────────────────────────────

  defp held_map(target, topts) do
    with {:ok, keys} <- target.list(topts, @ledgers_prefix) do
      {:ok,
       keys
       |> Enum.group_by(&segment_file/1)
       |> Map.new(fn {file, segments} -> {file, reach(segments)} end)}
    end
  end

  @doc false
  # How far a set of segments actually reaches — the contiguous run from zero,
  # not the highest boundary.
  #
  # These are the same number right up until they are not: a put that failed
  # after a later one succeeded, or a lifecycle rule that expired an old
  # segment, leaves a hole. Answering with the highest boundary would claim
  # bytes that cannot be restored, and would claim them in the one direction
  # that matters — a backup reporting more than it can give back. Stopping at
  # the hole costs a re-upload and heals it, because the next run copies from
  # the reach and fills the gap.
  def reach(segments) do
    segments
    |> Enum.map(&range/1)
    |> Enum.sort()
    |> Enum.reduce(0, fn {from, to}, reach -> if from == reach, do: to, else: reach end)
  end

  defp segment_file(key) do
    key |> String.trim_leading(@ledgers_prefix) |> Path.dirname()
  end

  # The highest boundary any segment claims, which is what `reach/1` would have
  # answered if there were no holes.
  defp furthest(segments),
    do: segments |> Enum.map(&(&1 |> range() |> elem(1))) |> Enum.max(fn -> 0 end)

  defp range(key) do
    [from, to] =
      key
      |> Path.basename(".segment")
      |> String.split("-")
      |> Enum.map(&String.to_integer/1)

    {from, to}
  end

  # ── reading the local side ─────────────────────────────────────────────────

  defp ledger_files(dir) do
    case File.ls(dir) do
      # `.ledger`: this reads the same files `Store.File.filename/1` writes, and
      # a backup that scanned for a suffix nothing is written under would copy
      # an empty list and report success.
      {:ok, entries} -> entries |> Enum.filter(&String.ends_with?(&1, ".ledger")) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp key_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.ends_with?(&1, ".writing"))
        |> Enum.filter(&File.regular?(Path.join(dir, &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # Everything after `from`, or nothing if the file does not reach that far —
  # which happens when the target holds more than this disk does, and asking
  # for a negative length would be an error rather than an empty answer.
  defp tail(path, from) do
    with want when want > 0 <- size(path) - from,
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      bytes =
        case :file.pread(io, from, want) do
          {:ok, data} -> data
          _ -> <<>>
        end

      :file.close(io)
      bytes
    else
      _ -> <<>>
    end
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _} -> 0
    end
  end

  # ── configuration ──────────────────────────────────────────────────────────

  defp target(opts) do
    case Keyword.get(opts, :target) || Application.get_env(:blazie, :backup_target) do
      {module, topts} -> {module, topts}
      nil -> raise "No backup target configured. Set :backup_target or pass target:."
    end
  end

  defp ledger_dir(opts) do
    Keyword.get(opts, :ledger_dir) ||
      Application.get_env(:blazie, :ledger_dir) ||
      raise "No ledger_dir to back up. A world in memory has nothing on disk to copy."
  end

  defp key_dir(opts) do
    Keyword.get(opts, :key_dir) || Application.get_env(:blazie, :key_dir) || "priv/keys"
  end
end
