defmodule Blazie.Surface.Endpoint do
  @moduledoc """
  The door. Four operations reach this database and they all come through here.
  """

  use Phoenix.Endpoint, otp_app: :blazie

  socket("/socket", Blazie.Surface.Socket, websocket: true, longpoll: false)

  # No CORS, because no browser reaches a cluster.
  #
  # There used to be a configured list of console origins here, from when the
  # console talked to a cluster's own HTTP API from the page. It does not: it
  # talks to the control plane on its own origin, and the control plane talks to
  # clusters server to server, holding the token a browser must never have.
  #
  # A tunnelled cluster listens on nothing at all, so the only thing on earth
  # that can present a request to it is the control plane. A configured list of
  # origins would be a setting nobody has to get right, which is worse than no
  # setting: it looks like a control and is not one.

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(Blazie.Surface.Router)
end
