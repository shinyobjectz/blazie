import Config

config :blazie, Blazie.Surface.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  # Not deployed yet. When it is, this comes from the environment — a checked-in
  # secret is a secret nobody has.
  secret_key_base: String.duplicate("blazie-not-a-production-secret", 3),
  server: config_env() != :test,
  render_errors: [formats: [json: Blazie.Surface.ErrorJSON], layout: false],
  pubsub_server: Blazie.PubSub

config :phoenix, :json_library, Jason

config :logger, level: if(config_env() == :test, do: :warning, else: :info)

# Keys live outside the facts they protect. In test and dev this is a local
# directory; in front of real users it must be a KMS, because a file can come
# back from a restore and erasure has to be irreversible.
config :blazie, key_dir: if(config_env() == :test, do: "tmp/test_keys", else: "priv/keys")

# Vitals take a reading on this cadence. Unset means the job does not run at
# all, which is right for tests and wrong for anything watching itself.
config :blazie, vitals_every: if(config_env() == :test, do: 3600, else: 60)

# Storage is measured less often than the node is: a file's size moves with
# writes rather than with time, so a reading a minute would be five identical
# facts for every one that said anything.
config :blazie, storage_every: if(config_env() == :test, do: 3600, else: 300)
