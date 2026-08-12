defmodule LazyRiver.Surface.Endpoint do
  @moduledoc """
  The door. Four operations reach this database and they all come through here.
  """

  use Phoenix.Endpoint, otp_app: :lazy_river

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(LazyRiver.Surface.Router)
end
