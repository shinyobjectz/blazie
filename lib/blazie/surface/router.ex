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

  # Authenticated, but not authorized against a name — claiming a world is the
  # one operation whose purpose is to name one this caller does not hold. The
  # operation refuses a name already taken; the plug cannot, because to it every
  # ungranted name looks identical.
  pipeline :claiming do
    plug(:accepts, ["json"])
    plug(Blazie.Surface.Authorize, names: false)
  end

  # There is no `/auth` here any more. Signing in belongs to the control plane,
  # which is served beside the console and holds the github secret — a cluster
  # that also traded oauth codes would be shipping a credential it cannot use
  # and an endpoint nobody calls, which is the definition of attack surface.

  scope "/", Blazie.Surface do
    pipe_through(:claiming)

    post("/worlds", Controller, :claim)
  end

  scope "/", Blazie.Surface do
    pipe_through(:api)

    get("/me", Controller, :me)
    get("/metrics", Controller, :metrics)

    post("/run", Controller, :run)

    # Rotation, in two verbs: share a held world with a successor's
    # fingerprint, and drop your own grant when the window closes.
    post("/grants", Controller, :share)
    post("/grants/drop", Controller, :drop)
  end
end
