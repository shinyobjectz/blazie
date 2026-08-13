defmodule Blazie.Surface.Router do
  @moduledoc """
  Three of the four operations, and the two ways in.

  `watch` is a channel rather than a request — see `Blazie.Surface.WatchChannel`
  — because it is the one that answers more than once.

  Signing in is the only thing not behind a token, because it is how a token is
  got. That is one pipeline of two routes, and everything else keeps the plug
  that decides which ledgers a caller may name.
  """

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
    plug(Blazie.Surface.Authorize)
  end

  # No token yet, by definition. Nothing here reads or writes a fact except the
  # identity a successful sign-in records.
  pipeline :open_door do
    plug(:accepts, ["json"])
  end

  scope "/auth", Blazie.Surface do
    pipe_through(:open_door)

    post("/github", IdentityController, :github)
    post("/device", IdentityController, :device)
    post("/device/token", IdentityController, :device_token)
  end

  scope "/", Blazie.Surface do
    pipe_through(:api)

    get("/me", IdentityController, :me)

    post("/open", Controller, :open)
    post("/ask", Controller, :ask)
    post("/write", Controller, :write)
  end
end
