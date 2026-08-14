defmodule Blazie.ClientPythonTest do
  @moduledoc """
  The Python client, over the same real wire as the Elixir one.

  The script in clients/python/test_client.py does the asserting; this test
  provides the listener and the token, runs it, and believes its exit code.
  One suite drives both SDKs so neither can drift from the surface — or from
  each other — unnoticed.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../clients/python", __DIR__)

  test "the python client claims, runs, caches, flushes, and is refused properly" do
    python = System.find_executable("python3")
    assert python, "python3 is required — both CI images and the dev boxes have it"

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: Blazie.Surface.Endpoint, port: 0, ip: {127, 0, 0, 1}},
          id: :py_wire
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    token = "py-client-#{System.unique_integer([:positive])}"

    {output, status} =
      System.cmd(
        python,
        ["test_client.py", "http://127.0.0.1:#{port}", token],
        cd: @script,
        stderr_to_stdout: true
      )

    assert status == 0, "the python client's own asserts failed:\n#{output}"
    assert String.trim(output) =~ ~r/ok$/
  end
end
