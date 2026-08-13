defmodule Blazie.Surface.Endpoint do
  @moduledoc """
  The door. Four operations reach this database and they all come through here.
  """

  use Phoenix.Endpoint, otp_app: :blazie

  socket("/socket", Blazie.Surface.Socket, websocket: true, longpoll: false)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(Blazie.Surface.Router)
end
