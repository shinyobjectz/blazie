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

  # TLS is optional and, when present, additional rather than instead. The node
  # sits behind a proxy that terminates the public certificate; this encrypts
  # the hop from that proxy to here, which otherwise crosses the internet in
  # the clear carrying bearer tokens. A self-signed certificate is enough for
  # that hop — the proxy is configured to trust this origin, not the world.
  https =
    case {System.get_env("TLS_CERT"), System.get_env("TLS_KEY")} do
      {cert, key} when is_binary(cert) and is_binary(key) ->
        [
          https: [
            ip: {0, 0, 0, 0, 0, 0, 0, 0},
            port: String.to_integer(System.get_env("TLS_PORT") || "4443"),
            certfile: cert,
            keyfile: key
          ]
        ]

      _ ->
        []
    end

  config :blazie,
         Blazie.Surface.Endpoint,
         [
           server: true,
           secret_key_base: secret,
           http: [
             ip: {0, 0, 0, 0, 0, 0, 0, 0},
             port: String.to_integer(System.get_env("PORT") || "4000")
           ]
         ] ++ https

  # Where ledgers keep their facts. The store is the seam, so moving this to
  # object storage later is a different module rather than a different path.
  config :blazie,
    # LEDGER_DIR, not WORLD_DIR. The running node is configured with it and
    # every fact it holds is under /data/ledgers; renaming the variable or the
    # path would point a fresh node at an empty directory and call it healthy.
    ledger_dir: System.get_env("LEDGER_DIR") || "/data/ledgers",
    ledger_sync: System.get_env("LEDGER_SYNC") == "true",
    # Keys must outlive a deployment. Defaulting this inside the release would
    # put them on an ephemeral disk, which is the in-memory keyring's bug
    # wearing a filesystem — every subject erased by accident on redeploy.
    key_dir: System.get_env("KEY_DIR") || "/data/keys",
    kms_key: System.get_env("KMS_KEY"),
    gcp_credentials: System.get_env("GOOGLE_APPLICATION_CREDENTIALS")

  # Where copies go. Configured or absent — there is no default, because a
  # default destination is a bucket somebody did not choose, and a backup
  # nobody chose the location of is one nobody checks.
  backup_target =
    cond do
      bucket = System.get_env("BACKUP_BUCKET") ->
        {Blazie.Backup.Target.S3,
         endpoint: System.fetch_env!("BACKUP_ENDPOINT"),
         bucket: bucket,
         region: System.get_env("BACKUP_REGION") || "auto",
         access_key_id: System.fetch_env!("BACKUP_ACCESS_KEY_ID"),
         secret_access_key: System.fetch_env!("BACKUP_SECRET_ACCESS_KEY"),
         prefix: System.get_env("BACKUP_PREFIX")}

      dir = System.get_env("BACKUP_DIR") ->
        {Blazie.Backup.Target.Directory, root: dir}

      true ->
        nil
    end

  config :blazie,
    backup_target: backup_target,
    backup_every: String.to_integer(System.get_env("BACKUP_EVERY") || "900")

  # A backup nobody has restored is a rumour, so the drill is on by default
  # wherever a backup is. `DRILL_EVERY=0` turns it off and says so in the
  # environment, which is a decision somebody made rather than a component
  # quietly never wired.
  #
  # It stages into a scratch directory that is deliberately not the data volume:
  # a restore must never share a path with the facts it is checking. If the
  # container's temp space cannot hold the largest ledger, set DRILL_DIR to
  # somewhere that can — never to LEDGER_DIR, which the drill refuses anyway.
  drill_every = String.to_integer(System.get_env("DRILL_EVERY") || "21600")

  config :blazie,
    drill_every: if(drill_every > 0, do: drill_every),
    drill_dir: System.get_env("DRILL_DIR"),
    drill_max_bytes: String.to_integer(System.get_env("DRILL_MAX_BYTES") || "536870912")

  if backup_target == nil do
    IO.warn(
      "No backup target is configured, so nothing is being copied anywhere. Losing /data loses every fact and every key. Set BACKUP_BUCKET (with BACKUP_ENDPOINT and credentials) or BACKUP_DIR."
    )
  end

  # Who may sign in, and how. The secret is read from the environment and never
  # written down here — a checked-in secret is a secret nobody has.
  config :blazie,
    github_client_id: System.get_env("GITHUB_CLIENT_ID"),
    github_client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
    github_logins:
      (System.get_env("GITHUB_LOGINS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

  if System.get_env("GITHUB_CLIENT_ID") == nil do
    IO.warn(
      "GITHUB_CLIENT_ID is not set, so nobody can sign in. The four operations still work for a token issued another way."
    )
  end

  if System.get_env("KEY_DIR") == nil do
    IO.warn(
      "KEY_DIR is not set; keys will be written to /data/keys. That path must be persistent storage — if it is not, a redeploy erases every subject."
    )
  end
end
