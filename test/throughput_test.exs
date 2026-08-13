defmodule LazyRiver.ThroughputTest do
  @moduledoc """
  What one ledger costs per write, and where that stops working.

  A ledger is a GenServer, so every append to one ledger is serialised through
  one process. That is the design; the question this file answers is what the
  ceiling actually is, in transactions per second, in latency at the tail, and
  in bytes — and which of those three gives out first.

  Not assertions about speed. These print tables; the numbers live in
  `.research/write-throughput.md`. The only assertions here are the ones that
  would mean the measurement itself was broken.

      mix test --include throughput test/throughput_test.exs

  One section at a time, which is how it is meant to be read:

      mix test --include throughput test/throughput_test.exs -k "batch size"
  """
  use ExUnit.Case, async: false

  alias LazyRiver.{Ledger, Store}

  @moduletag :throughput
  @moduletag timeout: 3_600_000

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp tmpdir do
    dir = Path.join(System.tmp_dir!(), "lr_thr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Every ledger here is opened with an explicit store so nothing depends on
  # what the environment happens to be configured with.
  defp open_ledger(:memory, opts) do
    name = {:thr, System.unique_integer([:positive])}
    {:ok, ledger} = Ledger.open(name, [store: {Store.Memory, []}] ++ opts)
    ExUnit.Callbacks.on_exit(fn -> Ledger.close(name) end)
    {name, ledger}
  end

  defp open_ledger(:file, opts) do
    open_ledger({:file, tmpdir()}, opts)
  end

  defp open_ledger({:file, dir}, opts) do
    name = {:thr, System.unique_integer([:positive])}
    {store_opts, opts} = Keyword.split(opts, [:sync, :checkpoint_every])
    store = {Store.File, [dir: dir] ++ store_opts}
    {:ok, ledger} = Ledger.open(name, [store: store] ++ opts)
    ExUnit.Callbacks.on_exit(fn -> Ledger.close(name) end)
    {name, ledger}
  end

  # Ids are unique unless a test wants them not to be. A repeated id is a
  # different shape entirely — see "one hot entity" — because sealing looks a
  # fact's owner up in the by_id list every time.
  defp ids(count), do: for(_ <- 1..count, do: System.unique_integer([:positive]))

  defp assertions(count), do: for(id <- ids(count), do: {id, "height", id})

  defp fill(ledger, count, batch \\ 500) do
    Enum.each(1..ceil(count / batch), fn _ ->
      {:ok, _} = Ledger.append(ledger, assertions(batch))
    end)
  end

  defp now, do: System.monotonic_time(:microsecond)

  defp timed(fun) do
    t0 = now()
    result = fun.()
    {now() - t0, result}
  end

  # A `GenServer.call` that ran out of patience is data, not a crash. The
  # server is still alive and will still process the request — the caller just
  # stopped waiting, which is exactly the failure mode being looked for.
  defp timed_append(ledger, facts, timeout \\ 5_000) do
    t0 = now()

    outcome =
      try do
        case GenServer.call(ledger, {:append, facts}, timeout) do
          {:ok, _tx} -> :ok
          other -> other
        end
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, reason -> {:exit, reason}
      end

    {now() - t0, outcome}
  end

  defp stats([]), do: %{n: 0, p50: 0, p95: 0, p99: 0, max: 0, mean: 0}

  defp stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    at = fn p -> Enum.at(sorted, min(n - 1, trunc(p * n))) end

    %{
      n: n,
      mean: div(Enum.sum(sorted), n),
      p50: at.(0.50),
      p95: at.(0.95),
      p99: at.(0.99),
      max: List.last(sorted)
    }
  end

  defp rate(count, micros) when micros > 0, do: round(count * 1_000_000 / micros)
  defp rate(_count, _micros), do: 0

  defp pid_of(ledger), do: GenServer.whereis(ledger)

  defp process_bytes(ledger) do
    pid = pid_of(ledger)
    :erlang.garbage_collect(pid)
    {:memory, bytes} = Process.info(pid, :memory)
    bytes
  end

  # Runs inside the ledger and hands the answer back, because a term's size is
  # only honest where it lives — sharing does not survive being copied out.
  # The state is returned untouched, so this reads without writing.
  defp inside(pid, fun) do
    me = self()
    tag = make_ref()

    :sys.replace_state(pid, fn state ->
      send(me, {tag, fun.(state)})
      state
    end)

    receive do
      {^tag, answer} -> answer
    after
      60_000 -> raise "the ledger never answered from inside"
    end
  end

  defp sizes_inside(pid) do
    inside(pid, fn state ->
      {:erts_debug.size_shared(state) * 8,
       :erts_debug.size_shared({state.by_id, state.by_attribute, state.by_value}) * 8}
    end)
  end

  defp row(cells), do: IO.puts("| " <> Enum.join(cells, " | ") <> " |")

  defp header(cells) do
    IO.puts("")
    row(cells)
    row(Enum.map(cells, fn _ -> "---" end))
  end

  # ── 1. batch size, and what fsync costs ────────────────────────────────────

  describe "batch size" do
    @tag :throughput
    test "throughput per append, by facts per transaction" do
      # The same 10,000 facts every time, so every configuration walks the
      # ledger through the same range of sizes. Only the number of transactions
      # it takes to get there changes.
      budget = 10_000

      header([
        "store",
        "facts/txn",
        "txns",
        "txn/s",
        "facts/s",
        "p50 us",
        "p95 us",
        "p99 us",
        "max us"
      ])

      for {label, kind, opts} <- [
            {"memory", :memory, []},
            {"file sync:false", :file, [sync: false]}
          ],
          batch <- [1, 10, 100, 1000] do
        {_name, ledger} = open_ledger(kind, opts)

        # Warmup, discarded: the first appends pay for lazily-loaded code and
        # the process's first heap growth.
        Enum.each(1..5, fn _ -> Ledger.append(ledger, assertions(batch)) end)

        txns = div(budget, batch)

        {elapsed, latencies} =
          timed(fn ->
            for _ <- 1..txns do
              {us, :ok} = timed_append(ledger, assertions(batch))
              us
            end
          end)

        s = stats(latencies)

        row([
          label,
          batch,
          txns,
          rate(txns, elapsed),
          rate(txns * batch, elapsed),
          s.p50,
          s.p95,
          s.p99,
          s.max
        ])
      end
    end

    @tag :throughput
    test "what an fsync costs, at the same batch sizes" do
      # Fewer facts here: at batch 1 this is one fsync per fact, and fsync is
      # the whole point of the measurement rather than something to amortise.
      budget = 2_000

      header(["store", "facts/txn", "txns", "txn/s", "facts/s", "p50 us", "p99 us", "max us"])

      results =
        for {label, sync} <- [{"file sync:false", false}, {"file sync:true", true}],
            batch <- [1, 10, 100, 1000] do
          {_name, ledger} = open_ledger(:file, sync: sync)
          Enum.each(1..5, fn _ -> Ledger.append(ledger, assertions(batch)) end)

          txns = div(budget, batch)

          {elapsed, latencies} =
            timed(fn ->
              for _ <- 1..txns do
                {us, :ok} = timed_append(ledger, assertions(batch))
                us
              end
            end)

          s = stats(latencies)

          row([
            label,
            batch,
            txns,
            rate(txns, elapsed),
            rate(txns * batch, elapsed),
            s.p50,
            s.p99,
            s.max
          ])

          {{sync, batch}, rate(txns, elapsed), s.p50}
        end

      header(["facts/txn", "txn/s no sync", "txn/s sync", "fsync cost (ratio)", "p50 delta us"])

      for batch <- [1, 10, 100, 1000] do
        {_, plain_rate, plain_p50} = Enum.find(results, fn {k, _, _} -> k == {false, batch} end)
        {_, sync_rate, sync_p50} = Enum.find(results, fn {k, _, _} -> k == {true, batch} end)

        row([
          batch,
          plain_rate,
          sync_rate,
          Float.round(plain_rate / max(sync_rate, 1), 1),
          sync_p50 - plain_p50
        ])
      end
    end
  end

  # ── 2. what it costs at size ───────────────────────────────────────────────

  describe "growth" do
    @tag :throughput
    test "append cost as the ledger fills" do
      # One append of one fact, measured at each size. One fact so the number
      # is per-transaction overhead — the part that depends on what is already
      # resident — rather than per-fact work.
      sizes = [1_000, 10_000, 100_000]

      header([
        "store",
        "resident facts",
        "txn/s",
        "p50 us",
        "p95 us",
        "p99 us",
        "max us",
        "us per 1k resident"
      ])

      for {label, kind, opts} <- [
            {"memory", :memory, []},
            {"file sync:false", :file, [sync: false]},
            {"file checkpoint:1000", :file, [sync: false, checkpoint_every: 1_000]}
          ] do
        {_name, ledger} = open_ledger(kind, opts)
        filled = 0

        Enum.reduce(sizes, filled, fn size, filled ->
          fill(ledger, size - filled)

          Enum.each(1..50, fn _ -> Ledger.append(ledger, assertions(1)) end)

          {elapsed, latencies} =
            timed(fn ->
              for _ <- 1..300 do
                {us, :ok} = timed_append(ledger, assertions(1), 30_000)
                us
              end
            end)

          s = stats(latencies)

          row([
            label,
            size,
            rate(300, elapsed),
            s.p50,
            s.p95,
            s.p99,
            s.max,
            Float.round(s.p50 / (size / 1_000), 2)
          ])

          size + 350
        end)
      end
    end

    @tag :throughput
    test "one hot entity: the same id written over and over" do
      # Sealing asks who owns a fact's entity, and answers by scanning the
      # by_id list for that id. Unique ids make that list one long. A single
      # entity accumulating facts makes it as long as its history.
      header(["shape", "facts written", "txn/s", "p50 us", "p99 us", "max us"])

      for {label, id_fun} <- [
            {"unique ids", fn _ -> System.unique_integer([:positive]) end},
            {"one id", fn _ -> :hot end}
          ],
          size <- [1_000, 10_000] do
        {_name, ledger} = open_ledger(:memory, [])

        {elapsed, latencies} =
          timed(fn ->
            for n <- 1..size do
              {us, :ok} = timed_append(ledger, [{id_fun.(n), "height", n}], 30_000)
              us
            end
          end)

        s = stats(latencies)
        row([label, size, rate(size, elapsed), s.p50, s.p99, s.max])
      end
    end
  end

  # ── 3. many writers, one ledger ────────────────────────────────────────────

  describe "concurrency" do
    @tag :throughput
    test "N writers against one ledger" do
      # The same total number of appends however many writers there are, so the
      # server does identical work in every row and only the queue in front of
      # it changes.
      total = 2_560

      header([
        "writers",
        "resident before",
        "appends",
        "txn/s",
        "p50 us",
        "p95 us",
        "p99 us",
        "max us",
        "timeouts"
      ])

      for prefill <- [0, 100_000], writers <- [1, 2, 8, 32, 128] do
        {_name, ledger} = open_ledger(:file, sync: false)
        if prefill > 0, do: fill(ledger, prefill)

        each = div(total, writers)
        Enum.each(1..20, fn _ -> Ledger.append(ledger, assertions(1)) end)

        {elapsed, results} =
          timed(fn ->
            1..writers
            |> Task.async_stream(
              fn _ ->
                for _ <- 1..each, do: timed_append(ledger, assertions(1))
              end,
              max_concurrency: writers,
              timeout: :infinity,
              ordered: false
            )
            |> Enum.flat_map(fn {:ok, list} -> list end)
          end)

        latencies = Enum.map(results, &elem(&1, 0))
        timeouts = Enum.count(results, &(elem(&1, 1) == :timeout))
        s = stats(latencies)

        row([
          writers,
          prefill,
          length(results),
          rate(length(results), elapsed),
          s.p50,
          s.p95,
          s.p99,
          s.max,
          timeouts
        ])
      end
    end

    @tag :throughput
    test "where the 5s call timeout actually arrives" do
      # Latency at the back of the queue is queue depth times service time.
      # Service time grows with what is resident, so the pair that breaks is
      # not one number — it is a curve. This measures service time at a size
      # and reports the writer count that would put the last caller past 5s.
      header([
        "resident facts",
        "service time p50 us",
        "p99 us",
        "serial txn/s",
        "process MB",
        "writers before a 5s timeout"
      ])

      {_name, ledger} = open_ledger(:file, sync: false)
      filled = 0

      Enum.reduce(
        [10_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000],
        filled,
        fn size, filled ->
          fill(ledger, size - filled, 5_000)
          Enum.each(1..20, fn _ -> Ledger.append(ledger, assertions(1)) end)

          latencies =
            for _ <- 1..100 do
              {us, :ok} = timed_append(ledger, assertions(1), 60_000)
              us
            end

          s = stats(latencies)

          row([
            size,
            s.p50,
            s.p99,
            rate(1, s.p50),
            Float.round(process_bytes(ledger) / 1_048_576, 1),
            round(5_000_000 / max(s.p50, 1))
          ])

          size + 120
        end
      )
    end
  end

  # ── 4. many ledgers, in parallel ───────────────────────────────────────────

  describe "many ledgers" do
    @tag :throughput
    test "throughput across 1, 8 and 64 ledgers written at once" do
      # One ledger is serial by design. The claim this checks is that the
      # design still scales sideways: N ledgers are N independent processes and
      # should use N cores until there are no more cores.
      per_ledger = 1_000
      batch = 10

      header([
        "ledgers",
        "facts written",
        "wall ms",
        "facts/s total",
        "facts/s per ledger",
        "speedup vs 1"
      ])

      one = nil

      Enum.reduce([1, 2, 4, 8, 16, 64], one, fn count, one ->
        ledgers =
          for _ <- 1..count do
            {_name, ledger} = open_ledger(:memory, [])
            Enum.each(1..5, fn _ -> Ledger.append(ledger, assertions(batch)) end)
            ledger
          end

        {elapsed, _} =
          timed(fn ->
            ledgers
            |> Task.async_stream(
              fn ledger ->
                for _ <- 1..per_ledger, do: {:ok, _} = Ledger.append(ledger, assertions(batch))
              end,
              max_concurrency: count,
              timeout: :infinity,
              ordered: false
            )
            |> Stream.run()
          end)

        facts = count * per_ledger * batch
        total = rate(facts, elapsed)
        one = one || total

        row([
          count,
          facts,
          div(elapsed, 1000),
          total,
          div(total, count),
          Float.round(total / one, 1)
        ])

        one
      end)
    end
  end

  # ── 5. reading while writing ───────────────────────────────────────────────

  describe "read while writing" do
    @tag :throughput
    test "find_at latency under write load, and what a wide read does to writers" do
      # `find_at` is a call on the same process that serves appends. A reader
      # and a writer therefore do not merely contend for a lock — they take
      # turns, and a slow one of either makes the other wait.
      header([
        "read",
        "concurrent writers",
        "read p50 us",
        "read p95 us",
        "read p99 us",
        "read max us"
      ])

      for {read_label, pattern_fun} <- [
            {"by id (1 fact)", fn known -> [id: Enum.random(known)] end},
            {"by attribute (all)", fn _known -> [attribute: "height"] end}
          ],
          writers <- [0, 1, 8, 32] do
        {_name, ledger} = open_ledger(:file, sync: false)
        fill(ledger, 20_000)
        known = for _ <- 1..50, do: hd(ids(1))
        {:ok, _} = Ledger.append(ledger, for(id <- known, do: {id, "height", 1}))
        tx = Ledger.tx(ledger)

        stop = :atomics.new(1, [])

        tasks =
          for _ <- 1..writers//1 do
            Task.async(fn ->
              loop = fn loop, acc ->
                if :atomics.get(stop, 1) == 1 do
                  acc
                else
                  {us, _} = timed_append(ledger, assertions(1), 30_000)
                  loop.(loop, [us | acc])
                end
              end

              loop.(loop, [])
            end)
          end

        Enum.each(1..5, fn _ -> Ledger.find_at(ledger, tx, pattern_fun.(known)) end)

        latencies =
          for _ <- 1..200 do
            {us, _} = timed(fn -> Ledger.find_at(ledger, tx, pattern_fun.(known)) end)
            us
          end

        :atomics.put(stop, 1, 1)
        write_latencies = tasks |> Enum.flat_map(&Task.await(&1, 60_000))

        s = stats(latencies)
        row([read_label, writers, s.p50, s.p95, s.p99, s.max])

        if writers > 0 do
          w = stats(write_latencies)

          row([
            "  ↳ writers during it",
            writers,
            w.p50,
            w.p95,
            w.p99,
            w.max
          ])
        end
      end
    end
  end

  # ── 5b. two cliffs the other tables only hint at ───────────────────────────

  describe "cliffs" do
    @tag :throughput
    test "a checkpoint writes the whole ledger, and the ledger waits for it" do
      # Production configures `checkpoint_every: 1000` whenever `ledger_dir` is
      # set, and a checkpoint serialises every fact ever written. That is a
      # stall inside `handle_call`, so it lands on whichever writer is unlucky
      # and on every writer queued behind it.
      header([
        "resident facts",
        "p50 us",
        "p99 us",
        "max us",
        "stall vs p50",
        "checkpoint KB",
        "KB rewritten per txn"
      ])

      {_name, ledger} = open_ledger(:file, sync: false, checkpoint_every: 1_000)
      filled = 0

      Enum.reduce([10_000, 100_000, 500_000], filled, fn size, filled ->
        fill(ledger, size - filled, 5_000)

        # Enough single-fact appends to cross the checkpoint threshold twice.
        latencies =
          for _ <- 1..2_100 do
            {us, :ok} = timed_append(ledger, assertions(1), 60_000)
            us
          end

        s = stats(latencies)
        path = inside(pid_of(ledger), & &1.store.path)
        checkpoint = File.stat!(path <> ".checkpoint").size

        row([
          size,
          s.p50,
          s.p99,
          s.max,
          "#{round(s.max / max(s.p50, 1))}x",
          div(checkpoint, 1024),
          Float.round(checkpoint / 1_000 / 1024, 1)
        ])

        size + 2_100
      end)
    end

    @tag :throughput
    test "bounding memory unbounds reads" do
      # What a bounded ledger evicted is answered by re-reading the store, and
      # `Store.File.replay/1` hands back everything it ever loaded. So the read
      # that memory bounding was supposed to make affordable is the one it
      # makes O(everything) — and it runs inside the same call as the writes.
      header(["resident bound", "facts", "resident", "find_at by id p50 us", "p99 us", "max us"])

      for bound <- [:unbounded, 1_000] do
        opts = if bound == :unbounded, do: [], else: [resident: bound]
        {_name, ledger} = open_ledger(:file, [sync: false] ++ opts)
        fill(ledger, 100_000, 5_000)

        known = hd(ids(1))
        {:ok, _} = Ledger.append(ledger, [{known, "height", 1}])
        tx = Ledger.tx(ledger)

        Enum.each(1..3, fn _ -> Ledger.find_at(ledger, tx, id: known) end)

        latencies =
          for _ <- 1..30 do
            {us, _} = timed(fn -> Ledger.find_at(ledger, tx, id: known) end)
            us
          end

        s = stats(latencies)
        row([inspect(bound), 100_000, Ledger.resident(ledger), s.p50, s.p99, s.max])
      end
    end

    @tag :throughput
    test "a wide read costs the write budget, and grows with the ledger" do
      header(["facts in ledger", "find_at attribute p50 us", "p99 us", "appends it displaces"])

      {_name, ledger} = open_ledger(:file, sync: false)
      filled = 0

      Enum.reduce([10_000, 100_000, 500_000], filled, fn size, filled ->
        fill(ledger, size - filled, 5_000)
        tx = Ledger.tx(ledger)

        Enum.each(1..2, fn _ -> Ledger.find_at(ledger, tx, attribute: "height") end)

        read =
          for _ <- 1..10 do
            {us, _} = timed(fn -> Ledger.find_at(ledger, tx, attribute: "height") end)
            us
          end

        append =
          for _ <- 1..30 do
            {us, :ok} = timed_append(ledger, assertions(1), 60_000)
            us
          end

        r = stats(read)
        a = stats(append)
        row([size, r.p50, r.p99, round(r.p50 / max(a.p50, 1))])
        size + 30
      end)
    end
  end

  # ── 6. what a resident fact costs in bytes ─────────────────────────────────

  describe "memory" do
    @tag :throughput
    test "process heap per resident fact" do
      header(["store", "facts resident", "process bytes", "bytes/fact", "MB", "facts in 3 GB"])

      for {label, kind, opts} <- [
            {"memory", :memory, []},
            {"file sync:false", :file, [sync: false]}
          ] do
        {_name, ledger} = open_ledger(kind, opts)
        empty = process_bytes(ledger)
        row([label, 0, empty, "—", Float.round(empty / 1_048_576, 2), "—"])

        Enum.reduce([1_000, 10_000, 100_000], 0, fn size, filled ->
          fill(ledger, size - filled)
          bytes = process_bytes(ledger)
          per = (bytes - empty) / size

          row([
            label,
            size,
            bytes,
            Float.round(per, 1),
            Float.round(bytes / 1_048_576, 2),
            round(3 * 1_073_741_824 / max(per, 1))
          ])

          size
        end)
      end
    end

    @tag :throughput
    test "live bytes, and which structure is holding them" do
      # Process heap is what the VM reserved, which is not what is live — it
      # grows in steps and a collection does not hand the slack back. The live
      # figure has to be taken *inside* the ledger, because the same five
      # references share one copy of each fact there and `:sys.get_state`
      # copies the state out, which flattens exactly the sharing being counted.
      header([
        "facts",
        "live B in process",
        "live B/fact",
        "3 sort orders B",
        "heap B",
        "heap/live",
        "copied-out B/fact"
      ])

      {_name, ledger} = open_ledger(:file, sync: false)

      Enum.reduce([1_000, 10_000, 100_000], 0, fn size, filled ->
        fill(ledger, size - filled)

        {live, indexes} = sizes_inside(pid_of(ledger))
        heap = process_bytes(ledger)
        copied = :erts_debug.size_shared(:sys.get_state(pid_of(ledger))) * 8

        row([
          size,
          live,
          Float.round(live / size, 1),
          indexes,
          heap,
          Float.round(heap / live, 2),
          Float.round(copied / size, 1)
        ])

        size
      end)

      IO.puts(
        "\n(the last column is what the same state weighs once copied out of the " <>
          "process — five references to one fact become five facts. Every reply " <>
          "a ledger sends pays that.)"
      )
    end

    @tag :throughput
    test "a bounded ledger, for contrast" do
      # `resident:` is the only lever that exists. It costs a rebuild of all
      # three sort orders every time the high-water mark is crossed, and it
      # only saves anything when the facts are durable somewhere else.
      header([
        "resident bound",
        "facts written",
        "ledger list",
        "store list",
        "live MB",
        "live B/fact written",
        "txn/s"
      ])

      for bound <- [:unbounded, 10_000, 1_000] do
        opts = if bound == :unbounded, do: [], else: [resident: bound]
        {_name, ledger} = open_ledger(:file, [sync: false] ++ opts)

        {elapsed, _} = timed(fn -> fill(ledger, 100_000, 100) end)

        # Reaching into the state is the only way to separate what the ledger
        # is holding from what its store is holding, and the difference is the
        # whole point of the row.
        {ledger_list, store_list} =
          inside(pid_of(ledger), fn state ->
            {length(state.facts), length(state.store.facts)}
          end)

        {live, _indexes} = sizes_inside(pid_of(ledger))

        row([
          inspect(bound),
          100_000,
          ledger_list,
          store_list,
          Float.round(live / 1_048_576, 2),
          Float.round(live / 100_000, 1),
          rate(1_000, elapsed)
        ])
      end
    end
  end
end
