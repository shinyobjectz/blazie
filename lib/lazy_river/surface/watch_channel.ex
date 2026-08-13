defmodule LazyRiver.Surface.WatchChannel do
  @moduledoc """
  `watch` — the fourth operation, and the only one that answers more than once.

  Joining names ledgers and a question. Every time a fact lands inside what
  that question read, the answer is pushed with the snapshot name it was
  answered at — so a client can cache on that name, and asking the same
  question again later gives the same answer. A subscription is not a different
  mechanism; it is the same question asked again as the name advances.

      channel.join("watch:heights", {
        ledgers: ["tenant-7"],
        pattern: {attribute: "height"}
      })

  Authorization happens here rather than only at connect, because naming is
  what is authorized and a join is where naming happens. A caller may hold a
  socket and still be refused a ledger.

  The subscription is owned by the channel process, so it dies when the client
  goes — there is nothing to clean up and nothing left pushing into the void.
  """

  use Phoenix.Channel

  alias LazyRiver.{Authority, Ledger, Subscription, Wire}

  @impl true
  def join("watch:" <> _name, params, socket) do
    with {:ok, ledgers} <- ledgers(params),
         :ok <- may_name_all(socket.assigns.caller, ledgers),
         {:ok, pattern} <- Wire.pattern(Map.get(params, "pattern", %{})),
         {:ok, opened} <- open_all(ledgers) do
      {:ok, ref} = Subscription.watch(opened, pattern)

      {:ok, %{"watching" => ledgers}, assign(socket, :ref, ref)}
    else
      {:error, refusal} -> {:error, refusal_payload(refusal)}
    end
  end

  @impl true
  # An answer from the subscription, on its way to the client.
  def handle_info({:lazy_river, ref, answer}, %{assigns: %{ref: ref}} = socket) do
    # "answer", not "value": what is pushed is the answer to the question this
    # socket asked. A value is the third slot of one fact.
    push(socket, "answer", %{
      "name" => answer.name,
      "facts" => Enum.map(answer.facts, &encode/1)
    })

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if ref = socket.assigns[:ref], do: Subscription.unwatch(ref)
    :ok
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp ledgers(%{"ledgers" => names}) when is_list(names) and names != [], do: {:ok, names}

  defp ledgers(_params),
    do:
      {:error,
       %{
         problem: :no_ledgers,
         repair: "Name the ledgers to watch. Watching none is not watching everything."
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

  # A pattern question answers with facts; a formula answers with assertions.
  defp encode(%LazyRiver.Fact{} = fact), do: Wire.fact(fact)
  defp encode(other), do: inspect(other)

  defp refusal_payload(refusal) do
    %{"problem" => to_string(refusal.problem), "repair" => Map.get(refusal, :repair, "")}
  end
end
