defmodule Blazie.Surface.Router do
  @moduledoc """
  Three of the four operations. `watch` is a channel rather than a request —
  see `Blazie.Surface.WatchChannel` — because it is the one that answers
  more than once.
  """

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
    plug(Blazie.Surface.Authorize)
  end

  scope "/", Blazie.Surface do
    pipe_through(:api)

    post("/open", Controller, :open)
    post("/ask", Controller, :ask)
    post("/write", Controller, :write)
  end
end
