import Config

config :lazy_river, LazyRiver.Surface.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  # Not deployed yet. When it is, this comes from the environment — a checked-in
  # secret is a secret nobody has.
  secret_key_base: String.duplicate("lazyriver-not-a-production-secret", 3),
  server: config_env() != :test,
  render_errors: [formats: [json: LazyRiver.Surface.ErrorJSON], layout: false],
  pubsub_server: LazyRiver.PubSub

config :phoenix, :json_library, Jason

config :logger, level: if(config_env() == :test, do: :warning, else: :info)
