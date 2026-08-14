defmodule Blazie.Otel do
  @moduledoc """
  The same turn, said again in somebody else's language.

  A turn is already a fact in the world it acted on, which is the account that
  survives — queryable at an old snapshot name, joined to the data rather than
  beside it. This is the other half: the same turn as an OTLP span, so a run
  shows up next to the http requests and database calls in whatever the operator
  already watches.

  Both, deliberately, and they are not redundant. Facts answer "what did this
  agent believe on Tuesday and what changed its mind" — a question a tracing
  backend cannot answer at all, because it drops spans after a fortnight and has
  no idea what a world is. Spans answer "why was this request slow" beside
  everything else that was happening, which facts in one world cannot.

  ## Why there is no opentelemetry dependency

  The same bet as `Blazie.Model`: no SDK. OTLP over http/json is a POST with a
  documented body, and this tree already signs SigV4 and parses OAuth by hand
  rather than take a release cadence it does not control. Three packages, an
  application to start, a supervision tree to own, and a sampler to configure is
  a large amount of machinery to emit one span per model call.

  What that costs, said plainly: no context propagation from an incoming
  request, no automatic instrumentation of anything else, and no baggage. A
  cluster that wants those wants the real SDK, and can have it — this writes
  spans, it does not stop anybody adding more.

  ## Nothing here may fail the work

  A span is a description of work that already happened. Exporting is spawned
  and its result ignored: an observability backend being down must never be a
  reason a run fails, and a queue that grows because a collector is unreachable
  is a memory leak wearing a monitoring badge.

  ## Where it goes

  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` if set, otherwise
  `OTEL_EXPORTER_OTLP_ENDPOINT` with `/v1/traces` appended — the conventional
  pair, so an operator who has configured any other otel component here has
  configured this one. Unset, nothing is sent and nothing is built.
  """

  @service "blazie"

  @doc """
  Send one span, if there is anywhere to send it.

  `run` is what ties turns together: every span for the same run shares a trace
  id, derived from it, so a trajectory is one trace rather than a scatter of
  unrelated calls. Derived rather than generated because it has to be the same
  id next time without anything remembering it — a run resumed after a restart
  belongs to the trace it was already part of.
  """
  @spec span(String.t(), term(), keyword()) :: :ok
  def span(name, run, opts \\ []) do
    case endpoint() do
      nil ->
        :ok

      where ->
        body = payload(name, run, opts)

        # Spawned, and the result is not awaited. See the moduledoc: a collector
        # being down is not a reason for a model call to have failed.
        spawn(fn -> post(where, body) end)
        :ok
    end
  end

  @doc "Where spans go, or `nil` when nothing is configured."
  @spec endpoint() :: String.t() | nil
  def endpoint do
    case System.get_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") do
      exact when is_binary(exact) and exact != "" ->
        exact

      _ ->
        case System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
          base when is_binary(base) and base != "" ->
            String.trim_trailing(base, "/") <> "/v1/traces"

          _ ->
            nil
        end
    end
  end

  @doc false
  @spec payload(String.t(), term(), keyword()) :: map()
  def payload(name, run, opts) do
    ended = Keyword.get(opts, :ended_at, System.system_time(:nanosecond))
    took = Keyword.get(opts, :took_ms, 0) * 1_000_000

    %{
      "resourceSpans" => [
        %{
          "resource" => %{"attributes" => [attribute("service.name", @service)]},
          "scopeSpans" => [
            %{
              "scope" => %{"name" => @service},
              "spans" => [
                %{
                  "traceId" => trace_id(run),
                  "spanId" => span_id(),
                  "name" => name,
                  # 3 is CLIENT: this process called somebody else's service,
                  # which is what every span here describes.
                  "kind" => 3,
                  "startTimeUnixNano" => to_string(ended - took),
                  "endTimeUnixNano" => to_string(ended),
                  "attributes" => Enum.map(Keyword.get(opts, :attributes, []), &attribute/1)
                }
              ]
            }
          ]
        }
      ]
    }
  end

  # Sixteen bytes for a trace and eight for a span, hex, per the spec. The trace
  # is a digest of the run so it is stable; the span is random because two turns
  # of the same run are two spans.
  defp trace_id(run) do
    :crypto.hash(:sha256, to_string(run))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp span_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp attribute({key, value}), do: attribute(to_string(key), value)

  defp attribute(key, value) when is_integer(value),
    do: %{"key" => key, "value" => %{"intValue" => to_string(value)}}

  defp attribute(key, value) when is_boolean(value),
    do: %{"key" => key, "value" => %{"boolValue" => value}}

  defp attribute(key, value),
    do: %{"key" => key, "value" => %{"stringValue" => to_string(value)}}

  defp post(where, body) do
    :httpc.request(
      :post,
      {String.to_charlist(where), headers(), ~c"application/json", Jason.encode!(body)},
      [{:timeout, 5_000}, {:connect_timeout, 2_000}],
      []
    )
  catch
    _, _ -> :ok
  end

  # `OTEL_EXPORTER_OTLP_HEADERS` is the conventional way an operator passes an
  # api key to a hosted collector, and it is comma-separated `k=v`.
  defp headers do
    System.get_env("OTEL_EXPORTER_OTLP_HEADERS", "")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          [{String.to_charlist(String.trim(key)), String.to_charlist(String.trim(value))}]

        _ ->
          []
      end
    end)
  end
end
