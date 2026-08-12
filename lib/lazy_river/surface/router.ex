defmodule LazyRiver.Surface.Router do
  @moduledoc """
  Three of the four operations. `watch` is a channel rather than a request,
  because it is the one that answers more than once.
  """

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", LazyRiver.Surface do
    pipe_through(:api)

    post("/open", Controller, :open)
    post("/ask", Controller, :ask)
    post("/write", Controller, :write)
  end
end
