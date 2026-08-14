defmodule Blazie.OtelTest do
  @moduledoc """
  The span, as a body a collector would accept.

  Written the way the provider tests are written — asserting on what gets SENT,
  because that is the only part a collector sees and the only part that can be
  wrong in a way nothing here would notice. A span nobody validated is an export
  that fails silently in somebody else's dashboard.
  """
  use ExUnit.Case, async: false

  alias Blazie.Otel

  setup do
    held = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

    on_exit(fn ->
      if held,
        do: System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", held),
        else: System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    end)

    System.delete_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
    :ok
  end

  test "nothing is configured, so nothing is sent" do
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    assert Otel.endpoint() == nil
    assert Otel.span("model.converse", "run-1") == :ok
  end

  test "the base endpoint gets the conventional path" do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318/")
    assert Otel.endpoint() == "http://collector:4318/v1/traces"
  end

  test "the ids are the widths the spec requires" do
    %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]} =
      Otel.payload("model.converse", "run-1", [])

    # 16 bytes and 8 bytes, hex. A collector drops a span with the wrong width
    # without telling anybody, which is the failure this asserts against.
    assert String.length(span["traceId"]) == 32
    assert String.length(span["spanId"]) == 16
    assert span["traceId"] =~ ~r/^[0-9a-f]{32}$/
  end

  test "turns of the same run share a trace, and are different spans" do
    one = Otel.payload("model.converse", "run-1", [])
    two = Otel.payload("model.converse", "run-1", [])

    assert trace(one) == trace(two)
    assert span_of(one) != span_of(two)

    # Derived from the run rather than generated, so a run resumed after a
    # restart belongs to the trace it was already part of.
    assert trace(one) != trace(Otel.payload("model.converse", "run-2", []))
  end

  test "attributes carry their type, which is how OTLP reads them" do
    %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]} =
      Otel.payload("model.converse", "run-1",
        attributes: [{"gen_ai.usage.input_tokens", 11}, {"gen_ai.request.model", "gpt-4o-mini"}]
      )

    kinds = Map.new(span["attributes"], &{&1["key"], &1["value"]})

    # An integer sent as a string is not an integer to a collector, and it is
    # the sort of thing that looks right in a dashboard until somebody sums it.
    assert kinds["gen_ai.usage.input_tokens"] == %{"intValue" => "11"}
    assert kinds["gen_ai.request.model"] == %{"stringValue" => "gpt-4o-mini"}
  end

  test "the window is the time the call took" do
    %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]} =
      Otel.payload("model.converse", "run-1", took_ms: 250, ended_at: 1_000_000_000)

    started = String.to_integer(span["startTimeUnixNano"])
    ended = String.to_integer(span["endTimeUnixNano"])

    assert ended - started == 250_000_000
  end

  test "it is json a collector can parse" do
    body = Otel.payload("model.converse", "run-1", attributes: [{"a", 1}])
    assert {:ok, _} = Jason.encode(body)
  end

  defp trace(%{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [s]}]}]}), do: s["traceId"]
  defp span_of(%{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [s]}]}]}), do: s["spanId"]
end
