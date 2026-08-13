defmodule Blazie.Surface.WatchChannel do
  @moduledoc """
  `watch` — a run, kept.

  Joining names a ledger and the Lua to keep answering. Every time something
  lands inside what that chunk read, it runs again and the value is pushed with
  the snapshot name it was answered at — so a client caches on that name, and
  running the same source at it later gives the same answer.

      channel.join("watch:heights", {
        ledger: "tenant-7",
        source: "local n = 0 for p in each { height = true } do n = n + 1 end return n"
      })

  This was the last fact-shaped surface blazie had. It took a `pattern` and
  pushed `facts`, which meant a client of the websocket still had to know what a
  fact is and what a pattern is even though nothing else did. It is the same
  chunk you would send to `run`, and what comes back is what the chunk returned.

  Authorization happens here rather than only at connect, because naming is what
  is authorized and a join is where naming happens. A caller may hold a socket
  and still be refused a ledger.

  The subscription is owned by the channel process, so it dies when the client
  goes — there is nothing to clean up and nothing left pushing into the void.
  """

  use Phoenix.Channel

  alias Blazie.{Authority, Ledger, Subscription}

  @impl true
  def join("watch:" <> _name, params, socket) do
    with {:ok, ledgers} <- ledgers(params),
         {:ok, source} <- source(params),
         :ok <- may_name_all(socket.assigns.caller, ledgers),
         {:ok, opened} <- open_all(ledgers) do
      {:ok, ref} = Subscription.watch(opened, {:lua, source})

      {:ok, %{"watching" => ledgers}, assign(socket, :ref, ref)}
    else
      {:error, refusal} -> {:error, refusal_payload(refusal)}
    end
  end

  @impl true
  # An answer from the subscription, on its way to the client.
  def handle_info({:blazie, ref, answer}, %{assigns: %{ref: ref}} = socket) do
    # "answer", not "value": what is pushed is the answer to the question this
    # socket asked, and the name it was answered at is half of it.
    push(socket, "answer", %{"name" => answer.name, "value" => answer.facts})

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if ref = socket.assigns[:ref], do: Subscription.unwatch(ref)
    :ok
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  # `ledger` for one, `ledgers` for several — the same two spellings `run` takes,
  # because a client that learned one should not discover the socket wants the
  # other.
  defp ledgers(%{"ledger" => name}) when is_binary(name), do: {:ok, [name]}

  defp ledgers(%{"ledgers" => names}) when is_list(names) and names != [], do: {:ok, names}

  defp ledgers(_params),
    do:
      {:error,
       %{
         problem: :no_ledgers,
         repair: "Name the ledger to watch. Watching none is not watching everything."
       }}

  defp source(%{"source" => source}) when is_binary(source) and source != "", do: {:ok, source}

  defp source(_params),
    do:
      {:error,
       %{
         problem: :no_source,
         repair:
           "Watching needs `source`: the lua to keep answering. It is the same chunk you " <>
             "would send to run."
       }}

  defp may_name_all(caller, ledgers) do
    case Enum.reject(ledgers, &Authority.may_name?(caller, &1)) do
      [] ->
        :ok

      [refused | _] ->
        {:error,
         %{
           problem: :not_granted,
           repair: "This caller may not name #{inspect(refused)}."
         }}
    end
  end

  defp open_all(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Ledger.open(name) do
        {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
        {:error, refusal} -> {:halt, {:error, refusal}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  defp refusal_payload(refusal) do
    %{"problem" => to_string(refusal.problem), "repair" => Map.get(refusal, :repair, "")}
  end
end
