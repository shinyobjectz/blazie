defmodule Blazie.CrashRecoveryTest do
  @moduledoc """
  A real operating-system process, killed with SIGKILL mid-write, restarted.

  The torn-tail handling was tested by writing a broken record by hand. This
  kills a node for real, repeatedly, while it is writing — which is the only
  way to know the recovery path faces what actually happens rather than what I
  imagined would happen.

  Slow by nature, so it is tagged and excluded from the ordinary run:

      mix test --include crash
  """
  use ExUnit.Case, async: false

  @moduletag :crash
  @moduletag timeout: 300_000

  setup do
    dir = Path.join(System.tmp_dir!(), "blazie_crash_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A node that writes until killed, recording what it believes it committed.
  defp writer_script(dir, receipts) do
    """
    dir = #{inspect(dir)}
    {:ok, l} = Blazie.World.open("crashy", store: {Blazie.Store.File, dir: dir, sync: true})
    {:ok, io} = File.open(#{inspect(receipts)}, [:append])

    Enum.each(1..100_000, fn n ->
      {:ok, tx} = Blazie.World.append(l, [{n, "n", n}])
      # Written only after append returned, so anything here was committed.
      IO.write(io, "\#{tx}\\n")
      :file.sync(io)
    end)
    """
  end

  defp run_until_killed(dir, receipts, _millis) do
    script = Path.join(dir, "writer.exs")
    File.write!(script, writer_script(dir, receipts))

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: ["-S", "mix", "run", script],
        cd: File.cwd!(),
        env: [{~c"MIX_ENV", ~c"dev"}]
      ])

    # Wait for the writer to actually be writing rather than for a fixed
    # moment. CI found this: a machine that compiles the project first had not
    # started in the two and a half seconds a laptop needed, so the kill landed
    # on a process that had committed nothing and the test read that as loss.
    started_with = length(committed(receipts))
    await_progress(receipts, started_with + 20, 240)

    # SIGKILL: no chance to flush, close, or checkpoint. The worst case.
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-9", to_string(os_pid)])
    System.cmd("pkill", ["-9", "-P", to_string(os_pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      15_000 -> Port.close(port)
    end

    Process.sleep(200)
  end

  defp await_progress(_receipts, _target, 0), do: flunk("the writer never got going")

  defp await_progress(receipts, target, tries) do
    if length(committed(receipts)) >= target do
      :ok
    else
      Process.sleep(250)
      await_progress(receipts, target, tries - 1)
    end
  end

  defp committed(receipts) do
    case File.read(receipts) do
      {:ok, text} ->
        text |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)

      {:error, :enoent} ->
        []
    end
  end

  defp survivors(dir) do
    {:ok, store} = Blazie.Store.File.open("crashy", dir: dir)
    facts = Blazie.Store.File.replay(store)
    Blazie.Store.File.close(store)
    facts
  end

  describe "killed with SIGKILL, mid-write" do
    test "everything the writer was told was committed survives", ctx do
      receipts = Path.join(ctx.dir, "receipts")
      run_until_killed(ctx.dir, receipts, 2_500)

      acknowledged = committed(receipts)
      recovered = survivors(ctx.dir) |> Enum.map(& &1.tx) |> Enum.uniq()

      assert acknowledged != [], "the writer never got going"

      # The whole promise of fsync-on-append: a returned transaction is one
      # that survives the machine being shot.
      missing = acknowledged -- recovered

      assert missing == [],
             "lost #{length(missing)} acknowledged transactions: #{inspect(Enum.take(missing, 10))}"
    end

    test "recovery invents nothing beyond what was acknowledged", ctx do
      receipts = Path.join(ctx.dir, "receipts")
      run_until_killed(ctx.dir, receipts, 2_500)

      acknowledged = committed(receipts)
      recovered = survivors(ctx.dir) |> Enum.map(& &1.tx) |> Enum.uniq() |> Enum.sort()

      # At most one extra: the transaction that was written but whose receipt
      # the writer never got to record. Never more, and never garbage.
      extra = recovered -- acknowledged
      assert length(extra) <= 1, "recovered #{length(extra)} transactions nobody acknowledged"
    end

    test "transactions recover contiguously, with no holes", ctx do
      receipts = Path.join(ctx.dir, "receipts")
      run_until_killed(ctx.dir, receipts, 2_500)

      recovered = survivors(ctx.dir) |> Enum.map(& &1.tx) |> Enum.uniq() |> Enum.sort()

      assert recovered != []
      assert recovered == Enum.to_list(1..length(recovered)//1), "holes in the recovered log"
    end
  end

  describe "killed repeatedly" do
    test "three kills in a row and it still reopens whole", ctx do
      receipts = Path.join(ctx.dir, "receipts")

      for _ <- 1..3, do: run_until_killed(ctx.dir, receipts, 1_500)

      acknowledged = committed(receipts)
      recovered = survivors(ctx.dir) |> Enum.map(& &1.tx) |> Enum.uniq()

      assert acknowledged != []
      assert acknowledged -- recovered == []

      # And it is still a working world, not merely a readable file.
      {:ok, world} =
        Blazie.World.open("crashy-reopened", store: {Blazie.Store.File, dir: ctx.dir})

      assert {:ok, _tx} = Blazie.World.append(world, [{1, "n", 1}])
      Blazie.World.close("crashy-reopened")
    end
  end
end
