defmodule Blazie.Surface.Socket do
  @moduledoc """
  The way in for `watch`, the one operation that answers more than once.

  A caller presents the same token it would on any other operation, and the
  same rule applies: authorization is which ledgers it may name. That is
  checked when a watch is joined, not only when the socket connects — a socket
  is a connection, and naming happens per question.
  """

  use Phoenix.Socket

  channel("watch:*", Blazie.Surface.WatchChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) and token != "" do
    {:ok, assign(socket, :caller, token)}
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "caller:" <> Blazie.Authority.caller(socket.assigns.caller)
end
