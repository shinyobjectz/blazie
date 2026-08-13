defmodule Blazie.Surface.Endpoint do
  @moduledoc """
  The door. Four operations reach this database and they all come through here.
  """

  use Phoenix.Endpoint, otp_app: :blazie

  socket("/socket", Blazie.Surface.Socket, websocket: true, longpoll: false)

  # The console runs on blazie.dev and this runs somewhere else, so the browser
  # asks permission before it will talk to us. Origins are configured rather
  # than wildcarded — a console is a named place, and `*` with credentials is
  # not a thing a browser will accept anyway.
  plug(CORSPlug, origin: &__MODULE__.origins/0)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(Blazie.Surface.Router)

  @doc """
  Which consoles may talk to this node.

  Read at request time so a deployment can add one without a rebuild, and
  defaulting to the real console plus local development. A node nobody has
  configured still answers its own CLI, which presents a token and is not a
  browser.
  """
  def origins do
    Application.get_env(:blazie, :console_origins, [
      "https://blazie.dev",
      "https://www.blazie.dev",
      "http://localhost:3000",
      "http://localhost:3111"
    ])
  end
end
