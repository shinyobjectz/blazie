import Config

# Read at boot, not at build. A release carries no secrets and no paths — a
# checked-in secret is a secret nobody has, and a baked-in path is a release
# that only runs where it was built.

if config_env() == :prod do
  secret =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      SECRET_KEY_BASE is not set.

      Generate one with `mix phx.gen.secret` and put it in the environment. It
      is not in the repo on purpose.
      """

  config :lazy_river, LazyRiver.Surface.Endpoint,
    server: true,
    secret_key_base: secret,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4000")
    ]

  # Where ledgers keep their facts. The store is the seam, so moving this to
  # object storage later is a different module rather than a different path.
  config :lazy_river,
    ledger_dir: System.get_env("LEDGER_DIR") || "/data/ledgers",
    ledger_sync: System.get_env("LEDGER_SYNC") == "true"
end
