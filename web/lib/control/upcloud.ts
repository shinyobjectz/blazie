/**
 * Making a machine, and making it a cluster.
 *
 * UpCloud is a vendor, so nothing here is vocabulary — a `Host` records who the
 * machine was bought from and the rest of the control plane never asks. Adding a
 * second vendor means another file this shape, not another word.
 *
 * ## Nothing listens
 *
 * The machine is provisioned with no inbound port open, and reaches Cloudflare
 * by dialling OUT through a tunnel. That is a stronger thing than a firewall
 * rule and a simpler one: there is no origin certificate to issue and renew, no
 * list of Cloudflare's addresses to keep current as it changes, and no port for
 * anybody to find. A cluster is reachable at a hostname on this zone and by
 * nothing else, which means the WAF, the rate limiting and the DDoS protection
 * in front of the console are in front of every cluster too.
 *
 * The firewall is still set, denying everything inbound. Not because the tunnel
 * needs it — it does not — but because a machine whose safety rests on nothing
 * having been started is a machine one `apt install` away from being wrong.
 */

import type { Host } from "./model"

const API = "https://api.upcloud.com/1.3"

export type Opening = {
  name: string
  hostname: string
  zone: string
  plan: string
  /** Connects the machine to the tunnel that fronts it. */
  tunnelToken: string
  /** Where to say how it is getting on, and what to present when it does. */
  home: string
  id: string
  hello: string
  /**
   * What this cluster's key-encryption keys are kept under.
   *
   * Without one the keyring falls back to a constant in a public repository, so
   * sealing appears to work and protects nothing — which is what a provisioned
   * cluster was doing, silently. Per cluster, so one cannot open another's.
   *
   * It is held here, which means the control plane could decrypt what a cluster
   * sealed. That is not a widening: it already holds the token that can read
   * everything the cluster holds unsealed.
   */
  masterKey: string

  /** Where this cluster copies itself to. Absent means it does not. */
  backup?: Backup
  /** Where this cluster's blob bytes live. Absent means it cannot hold any. */
  blobs?: Backup
  /**
   * What signs this cluster's own cookies. Generated per cluster, written once.
   *
   * The release refuses to boot without it, deliberately — so the first machine
   * this ever made would have come up dead. Caught by the gate in the image
   * workflow before any of it ran, which is the entire reason that gate starts a
   * container and asks it a question rather than trusting a successful build.
   */
  secret: string
}

/**
 * The machine is never told the cluster's token, and does not need to be.
 *
 * A blazie caller IS a token's fingerprint: any bearer token is a caller, and it
 * simply holds no worlds until it claims one. So there is nothing to install —
 * the control plane mints a token, presents it, and becomes that cluster's first
 * caller by doing so. Measured against the live node before this was written,
 * because a cloud-init that set a variable nothing read would have looked
 * exactly like one that worked.
 *
 * What makes that safe is the tunnel rather than the token. Nothing listens on
 * the machine, so the only thing on earth that can present a token to it is the
 * control plane. On a cluster reachable from the internet this arrangement would
 * be wrong, and it is one of the reasons it is not.
 */

/**
 * An UpCloud API token, presented as a bearer.
 *
 * Not the username and password the API's Basic auth also accepts — a token can
 * be scoped and revoked without touching the login that can see the invoices,
 * which is the right shape for a credential a web service holds.
 */
export type Credentials = { token: string }

/**
 * Everything a machine is handed that must never come back out of it.
 *
 * Listed once, so adding a credential to `Opening` and forgetting to blank it
 * is a change to this function rather than a silent leak in a log tail nobody
 * reads until something breaks. Empty values are dropped: a `sed` matching the
 * empty string replaces between every character.
 */
export function scrubbing(opening: Opening): { called: string; value: string }[] {
  return [
    { called: "tunnel token", value: opening.tunnelToken },
    { called: "secret key base", value: opening.secret },
    { called: "master key", value: opening.masterKey },
    { called: "hello", value: opening.hello },
    { called: "backup key id", value: opening.backup?.accessKeyId ?? "" },
    { called: "backup secret", value: opening.backup?.secretAccessKey ?? "" },
    { called: "blob key id", value: opening.blobs?.accessKeyId ?? "" },
    { called: "blob secret", value: opening.blobs?.secretAccessKey ?? "" },
  ].filter((one) => one.value.length > 0)
}

export type Backup = {
  bucket: string
  endpoint: string
  accessKeyId: string
  secretAccessKey: string
  prefix: string
}

/**
 * The plans offered, and nothing else.
 *
 * A free-form plan string would let a console ask for something UpCloud does not
 * sell and find out four minutes later. These are the ones a cluster is worth
 * running on: below 2GB the BEAM and a build both fit badly.
 */
export const PLANS = [
  { id: "1xCPU-2GB", label: "1 CPU · 2 GB", monthly: 9, cores: 1, memory: 2048 },
  { id: "2xCPU-4GB", label: "2 CPU · 4 GB", monthly: 18, cores: 2, memory: 4096 },
  { id: "4xCPU-8GB", label: "4 CPU · 8 GB", monthly: 44, cores: 4, memory: 8192 },
] as const

export const ZONES = [
  { id: "uk-lon1", label: "London" },
  { id: "de-fra1", label: "Frankfurt" },
  { id: "us-nyc1", label: "New York" },
  { id: "sg-sin1", label: "Singapore" },
] as const

export function known(list: readonly { id: string }[], id: string): boolean {
  return list.some((entry) => entry.id === id)
}

/**
 * Debian 12 Bookworm, because the image is built on bookworm and a host that
 * matches it is one fewer thing that can differ between what was tested and what
 * runs.
 *
 * Read off `/1.3/storage/template` rather than trusted: the uuid written here
 * first was not a template at all, and nothing would have said so until a
 * machine failed to clone four minutes into an otherwise successful provision.
 */
const TEMPLATE = "01000000-0000-4000-8000-000020070100"

/**
 * What the account will let you have, asked before anything is made.
 *
 * Two things, and the first one is fatal. A trial account's firewall cannot be
 * disabled and cannot be modified — `TRIAL_FIREWALL`, on both endpoints — and
 * its fixed rule set permits outbound 80, 443, 8080, 6443, DNS, NTP and ICMP
 * while dropping everything else. cloudflared reaches Cloudflare's edge on 7844
 * and Cloudflare's own documentation calls that non-negotiable, so a tunnelled
 * cluster cannot work on a trial account at all.
 *
 * Which is worth knowing BEFORE making a tunnel, a DNS record and a server that
 * can never connect. It cost three provisions to find out, each of which
 * installed perfectly and then sat there.
 *
 * The second is capacity: cores and memory are capped and a machine that will
 * not fit should be refused rather than attempted.
 */
export async function limits(
  credentials: Credentials,
): Promise<
  | { ok: true; trialFirewall: boolean; cores: number | null; memory: number | null }
  | { ok: false; problem: string; repair: string }
> {
  const said = await fetch(`${API}/account`, {
    headers: { authorization: basic(credentials) },
    signal: AbortSignal.timeout(20_000),
  }).catch(() => null)

  if (!said?.ok) {
    return {
      ok: false,
      problem: "upcloud_unreachable",
      repair: "UpCloud would not say what this account may have. Check UPCLOUD_TOKEN.",
    }
  }

  const body = (await said.json().catch(() => null)) as {
    account?: { trial_resource_limits?: Record<string, number | null> }
  } | null

  const trial = body?.account?.trial_resource_limits ?? {}

  return {
    ok: true,
    trialFirewall: trial.trial_firewall_restrictions === 1,
    cores: trial.trial_total_server_cores ?? null,
    memory: trial.trial_total_server_memory ?? null,
  }
}

/**
 * What the account is already spending, so what is left can be worked out.
 *
 * Asked of the machines rather than of a number kept somewhere: a count of
 * cores that is maintained is a second account of the servers and can be wrong,
 * and the servers are right by construction.
 */
export async function spent(
  credentials: Credentials,
): Promise<{ cores: number; memory: number }> {
  const said = await fetch(`${API}/server`, {
    headers: { authorization: basic(credentials) },
    signal: AbortSignal.timeout(20_000),
  }).catch(() => null)

  if (!said?.ok) return { cores: 0, memory: 0 }

  const body = (await said.json().catch(() => null)) as {
    servers?: { server?: { plan?: string }[] }
  } | null

  let cores = 0
  let memory = 0

  for (const server of body?.servers?.server ?? []) {
    // A plan we do not sell is still a plan the account is paying for, so it is
    // counted at whatever the name says rather than skipped.
    const known = PLANS.find((p) => p.id === server.plan)
    const named = /^(\d+)xCPU-(\d+)GB$/.exec(String(server.plan ?? ""))

    cores += known?.cores ?? (named ? Number(named[1]) : 0)
    memory += known?.memory ?? (named ? Number(named[2]) * 1024 : 0)
  }

  return { cores, memory }
}

export async function open(
  credentials: Credentials,
  opening: Opening,
): Promise<{ ok: true; host: Host } | { ok: false; problem: string; repair: string }> {
  const response = await fetch(`${API}/server`, {
    method: "POST",
    headers: {
      authorization: basic(credentials),
      "content-type": "application/json",
    },
    body: JSON.stringify({
      server: {
        title: `blazie ${opening.name}`,
        hostname: opening.hostname,
        zone: opening.zone,
        plan: opening.plan,
        // No password, no keys, no console. The machine is not something anybody
        // logs into — it is something that runs one container and dials out.
        login_user: { create_password: "no" },
        metadata: "yes",
        user_data: cloudInit(opening),
        storage_devices: {
          storage_device: [
            {
              action: "clone",
              storage: TEMPLATE,
              title: `${opening.hostname} disk`,
              size: 50,
              tier: "maxiops",
            },
          ],
        },
        // Off at birth, and switched on once the machine is up — see `wall`.
        //
        // On is what this wants to be, and on is what it was. But UpCloud's
        // firewall denies everything in both directions until rules exist, and
        // rules cannot be posted while the disk is still cloning. So a machine
        // created with it on boots sealed: no dns, no apt, no pull, no tunnel,
        // and no way to report any of that, because reporting is a request too.
        //
        // Trying to close that gap from the control plane failed twice — once
        // by posting rules into `maintenance` and ignoring the refusals, once
        // by waiting for the machine in `waitUntil`, which does not outlive the
        // response by the minute a clone takes.
        //
        // What actually keeps this machine closed is not the firewall: blazie
        // is published to `127.0.0.1:4000`, so it is not on the public
        // interface at all, and the tunnel only ever dials out. The firewall is
        // defence in depth, and defence in depth is not worth a machine that
        // cannot boot.
        firewall: "off",
      },
    }),
    signal: AbortSignal.timeout(30_000),
  })

  if (!response.ok) {
    return {
      ok: false,
      problem: "would_not_open",
      repair: await said(response),
    }
  }

  const body = (await response.json()) as { server?: { uuid?: string } }
  const uuid = body.server?.uuid

  if (!uuid) {
    return {
      ok: false,
      problem: "would_not_open",
      repair: "UpCloud accepted the request and did not say which machine it made, so there is nothing to point at. Check the UpCloud console before asking again — a machine may exist.",
    }
  }

  return {
    ok: true,
    host: { vendor: "upcloud", uuid, plan: opening.plan, zone: opening.zone },
  }
}

/**
 * Everything the machine has to be able to reach, and nothing else.
 *
 * Each of these is load-bearing, so the list is written with what needs it:
 * lose any one and the install stops somewhere different.
 */
const OUT = [
  { protocol: "tcp", port: 53, needs: "dns" },
  { protocol: "udp", port: 53, needs: "dns" },
  { protocol: "udp", port: 123, needs: "ntp, or tls rejects every certificate" },
  { protocol: "tcp", port: 80, needs: "apt" },
  { protocol: "tcp", port: 443, needs: "docker pull, and saying how it is getting on" },
  { protocol: "tcp", port: 7844, needs: "cloudflared to the edge" },
  { protocol: "udp", port: 7844, needs: "cloudflared to the edge, over quic" },
] as const

/**
 * Wall the machine in: say what may pass, then start enforcing.
 *
 * Called once the machine has said `tunnelled` — which is to say, once it has
 * finished needing anything unusual and has proved it is alive. That timing is
 * not a nicety. It is the only moment when the machine is certainly out of
 * `maintenance` (rules are refused before that), the work is short enough to
 * finish inside a request, and nothing is left to install if it goes wrong.
 *
 * The rule set is written out here rather than inherited from a vendor default.
 * The previous version added one rule for 7844 and explained in a comment that
 * UpCloud's default set already permits 80, 443, DNS and NTP outbound — but
 * that was measured on a trial account, and what it described was the TRIAL
 * firewall. On an ordinary account, `firewall: "on"` with no rules denies
 * everything both ways. So taking the account out of trial, which was the fix
 * for the previous failure, turned a machine that could do everything except
 * dial the tunnel into one that could do nothing at all — and could not say so,
 * because saying so is a request to 443.
 *
 * A default that changes underneath you is not a dependency you can see. This
 * one changed for a reason that looked like unrelated progress.
 */
export async function wall(credentials: Credentials, uuid: string): Promise<boolean> {
  const made: boolean[] = []
  let position = 1

  // Both families, because a machine reaching Cloudflare over IPv6 and denied
  // over IPv4 fails the same way as one denied entirely, and which it prefers is
  // not ours to decide.
  for (const family of ["IPv4", "IPv6"]) {
    for (const { protocol, port, needs } of OUT) {
      const said = await fetch(`${API}/server/${uuid}/firewall_rule`, {
        method: "POST",
        headers: { authorization: basic(credentials), "content-type": "application/json" },
        body: JSON.stringify({
          firewall_rule: {
            direction: "out",
            action: "accept",
            family,
            protocol,
            destination_port_start: String(port),
            destination_port_end: String(port),
            position: String(position),
            comment: needs,
          },
        }),
        signal: AbortSignal.timeout(20_000),
      }).catch(() => null)

      made.push(Boolean(said?.ok))
      position += 1
    }
  }

  if (!made.every(Boolean)) return false

  // Only now. Switching it on with no rules is the sealed box, so the order
  // here is the whole point: describe what may pass, then start enforcing.
  const on = await fetch(`${API}/server/${uuid}`, {
    method: "PUT",
    headers: { authorization: basic(credentials), "content-type": "application/json" },
    body: JSON.stringify({ server: { firewall: "on" } }),
    signal: AbortSignal.timeout(20_000),
  }).catch(() => null)

  return Boolean(on?.ok)
}

/**
 * Take the machine away, and its disk.
 *
 * Stopped first, because UpCloud refuses to delete a running server — measured,
 * after a destroy that removed the tunnel and the DNS record and left the
 * machine running and billing. That is precisely the outcome this whole design
 * claims to avoid, and it survived because the delete's failure was swallowed:
 * `.catch(() => undefined)` on a call whose success nobody checked.
 *
 * `hard`, not `soft`. A machine being destroyed is one nothing is expected from,
 * and a soft stop waits on a guest that may be the reason it is being destroyed.
 */
export async function close(credentials: Credentials, uuid: string): Promise<boolean> {
  await fetch(`${API}/server/${uuid}/stop`, {
    method: "POST",
    headers: { authorization: basic(credentials), "content-type": "application/json" },
    body: JSON.stringify({ stop_server: { stop_type: "hard" } }),
    signal: AbortSignal.timeout(30_000),
  }).catch(() => undefined)

  // Polled rather than assumed. Stopping is not instant and a delete sent too
  // early is refused exactly as it was before.
  for (let i = 0; i < 30; i++) {
    const state = await stateOf(credentials, uuid)

    // Already gone, which is a success rather than a case to handle.
    if (state === null) return true
    if (state === "stopped") break

    await new Promise((wake) => setTimeout(wake, 4_000))
  }

  const gone = await fetch(`${API}/server/${uuid}/?storages=1&backups=delete`, {
    method: "DELETE",
    headers: { authorization: basic(credentials) },
    signal: AbortSignal.timeout(60_000),
  }).catch(() => null)

  // A machine that is not there is a machine that is gone. Removing something
  // twice has to succeed the second time, or a removal interrupted halfway can
  // never be finished — and one was: the machine deleted, the tunnel still
  // draining, and every attempt after that refused.
  return Boolean(gone?.ok) || gone?.status === 404
}

/**
 * What UpCloud says the machine is doing.
 *
 * `maintenance` for the minute or so a disk clone takes, then `started`. Used
 * by `close` to know when a stop has landed, and exported because it is also
 * the only true thing there is to say during the longest and least explicable
 * part of opening a cluster: before the machine exists, nothing can report on
 * itself, so the console had a full minute with nothing to show.
 */
export async function stateOf(credentials: Credentials, uuid: string): Promise<string | null> {
  const said = await fetch(`${API}/server/${uuid}`, {
    headers: { authorization: basic(credentials) },
    signal: AbortSignal.timeout(20_000),
  }).catch(() => null)

  if (!said?.ok) return null

  const body = (await said.json().catch(() => null)) as { server?: { state?: string } } | null
  return body?.server?.state ?? null
}

/**
 * Everything the machine does, once.
 *
 * Deliberately short. It installs a container runtime, runs one published image
 * and one tunnel, and closes everything else — there is no build here, no source
 * checkout, and no step that depends on a machine somebody is holding. A cluster
 * that could only be opened from a particular laptop would not be a product.
 */
/**
 * The backup settings, or nothing at all.
 *
 * Nothing rather than empty values: `runtime.exs` decides whether to back up by
 * whether `BACKUP_BUCKET` is set, and a blank one would configure a destination
 * that does not exist and fail on the first cadence rather than at boot.
 */
function backupEnv(opening: Opening): string {
  return [named("BACKUP", opening.backup), named("BLOB", opening.blobs)]
    .filter(Boolean)
    .join("\n")
}

/**
 * One block of settings, or nothing at all.
 *
 * Nothing rather than empty values: `runtime.exs` decides whether each is
 * configured by whether its bucket is set, and a blank one configures a
 * destination that does not exist and fails on first use rather than at boot.
 */
function named(prefix: string, where: Backup | undefined): string {
  if (!where) return ""

  return [
    `      ${prefix}_BUCKET=${where.bucket}`,
    `      ${prefix}_ENDPOINT=${where.endpoint}`,
    `      ${prefix}_REGION=auto`,
    `      ${prefix}_ACCESS_KEY_ID=${where.accessKeyId}`,
    `      ${prefix}_SECRET_ACCESS_KEY=${where.secretAccessKey}`,
    `      ${prefix}_PREFIX=${where.prefix}`,
  ].join("\n")
}

function cloudInit(opening: Opening): string {
  const said = `${opening.home}/api/clusters/${opening.id}/said`

  return `#cloud-config
package_update: true
packages:
  - docker.io
  - ufw
  - curl
  # Debian 12 has AppArmor in the kernel and \`docker.io\` does not depend on the
  # thing that loads its profiles, so every \`docker run\` fails with
  # "docker-default profile could not be loaded" and \`apparmor_parser: not
  # found". The machine boots, docker starts, and nothing runs — which is
  # exactly the silence the first provision died in.
  - apparmor

write_files:
  - path: /etc/blazie.env
    permissions: "0600"
    content: |
      BLAZIE_CLUSTER=${opening.hostname}
      SECRET_KEY_BASE=${opening.secret}
      BLAZIE_MASTER_KEY=${opening.masterKey}
${backupEnv(opening)}

  - path: /usr/local/bin/blazie-open
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail

      # Every step is announced before and after, so a machine that dies mid-step
      # is stuck at a named place rather than simply silent.
      # Tried more than once, because a step that does not land is a step that
      # did not happen as far as anybody watching is concerned — and that is not
      # a cosmetic loss. A provision reported ONLY \`failed\`, having in fact
      # reached every step and connected its tunnel; the console showed a broken
      # cluster, offered to remove it, and a working one was destroyed.
      #
      # The early ones are the ones that miss: this runs seconds into a boot,
      # when dns may not answer yet. Still \`|| true\` at the end — saying so is
      # not worth failing the install over — but no longer one attempt.
      # Every secret this machine was given, blanked out of anything it says.
      #
      # \`died\` sends the tail of cloud-init's log, and that log is written by a
      # script whose arguments include the tunnel token, the key everything is
      # sealed under, and the credentials for the backup bucket. The console
      # prints what comes back. So the one place a failure was most useful was
      # also the one place every credential could leave the machine — and it is
      # shown, by design, to whoever is watching a cluster open.
      #
      # Blanked here rather than in the console, because the console cannot know
      # what a secret looks like and this script is holding them by name.
      scrub() {
        sed ${scrubbing(opening)
          .map((secret) => `-e 's|${secret.value}|<${secret.called}>|g'`)
          .join(" \\\n          ")}
      }

      say() {
        detail=$(printf '%s' "\${2-}" | tr -d '"\\\\' | tr '\\n\\r\\t' '   ' | scrub | tail -c 1500)
        for attempt in 1 2 3 4 5; do
          curl -fsS -m 15 -X POST '${said}' \\
            -H 'content-type: application/json' \\
            --data "{\\"hello\\":\\"${opening.hello}\\",\\"step\\":\\"$1\\",\\"detail\\":\\"$detail\\"}" \\
            >/dev/null 2>&1 && return 0
          sleep "$attempt"
        done
        return 0
      }

      # The whole point. Without this a failure is indistinguishable from a slow
      # install, which is exactly how the first provision was lost.
      #
      # Entered once. This handler calls say, and if anything inside say fails
      # the trap fires again from inside the handler — a broken scrub produced
      # nine identical reports in four seconds and no detail in any of them,
      # which says nothing about what went wrong and buries the one line that
      # would. A failure handler that can fail into itself reports its own
      # recursion instead of the failure.
      dying=""
      died() {
        [ -n "$dying" ] && return 0
        dying=yes
        trap - ERR
        say failed "line $1: $(tail -c 1200 /var/log/blazie-open.log 2>/dev/null)"
      }
      trap 'died $LINENO' ERR

      say booted
      say packages

      # Inbound: nothing. The tunnel dials out, so denying everything costs no
      # reachability and takes away every port a scan could find.
      ufw --force default deny incoming
      ufw --force default allow outgoing
      ufw --force enable

      systemctl enable --now docker
      for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
      docker info >/dev/null
      say docker

      docker pull ghcr.io/shinyobjectz/blazie:latest
      docker pull cloudflare/cloudflared:latest
      say pulled

      mkdir -p /var/lib/blazie
      docker run -d --name blazie --restart always \\
        --env-file /etc/blazie.env \\
        -v /var/lib/blazie:/data \\
        -p 127.0.0.1:4000:4000 \\
        ghcr.io/shinyobjectz/blazie:latest

      # Refuses without a token, which is the cheapest proof it is serving
      # rather than merely running — the same question the healthcheck asks.
      for i in $(seq 1 60); do
        code=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:4000/run \\
          -H 'content-type: application/json' -d '{}' --max-time 5 || true)
        [ "$code" = "401" ] && break
        sleep 2
      done
      [ "\${code-}" = "401" ] || { say failed "blazie answered $code where 401 was expected: $(docker logs --tail 40 blazie 2>&1)"; exit 1; }
      say serving

      docker run -d --name tunnel --restart always --network host \\
        cloudflare/cloudflared:latest tunnel --no-autoupdate \\
        --protocol http2 run \\
        --token ${opening.tunnelToken}

      # A container that stayed up is not a tunnel that connected — the
      # difference cost a provision that reported it while Cloudflare
      # served 1033. cloudflared says so in its own log when it registers.
      #
      # Read into a variable and matched with \`case\`, NOT piped into \`grep -q\`.
      # \`grep -q\` exits the moment it matches, which SIGPIPEs the producer for
      # 141 — and under \`pipefail\` that makes the whole pipeline non-zero. So
      # finding the line is what made the test fail. The loop ran all 45 rounds,
      # the check after it took its failing branch, and four provisions reported
      # "cloudflared never registered" while attaching a log that showed it
      # registering four connections ninety seconds earlier. One of those was
      # believed and a working cluster was destroyed.
      registered=""
      for i in $(seq 1 45); do
        logs=$(docker logs tunnel 2>&1 || true)
        case "$logs" in *"Registered tunnel connection"*) registered=yes; break;; esac

        up=$(docker ps --filter name=tunnel --filter status=running -q || true)
        [ -n "$up" ] || { say failed "cloudflared exited: $(docker logs --tail 60 tunnel 2>&1 || true)"; exit 1; }
        sleep 2
      done

      [ -n "$registered" ] \\
        || { say failed "cloudflared never registered: $(docker logs --tail 60 tunnel 2>&1 || true)"; exit 1; }
      say tunnelled

      # Asking what to run, on a timer. A cluster listens on nothing, so an
      # upgrade cannot be pushed at one — and giving it a port to be upgraded
      # through would undo the reason it has none.
      #
      # Deploys reset in-flight work, which this repo already knows and paid for
      # once. A restart here kills a running job mid-chunk; what it does not do
      # is lose a fact, because nothing is acknowledged until it is appended.
      cat > /usr/local/bin/blazie-upgrade <<'UPGRADE'
      #!/usr/bin/env bash
      set -Eeuo pipefail

      wanted=$(curl -fsS -m 20 "HOME_URL/image?hello=HELLO_TOKEN" | sed -n 's/.*"image":"\\([^"]*\\)".*/\\1/p')
      [ -n "$wanted" ] || exit 0

      docker pull "$wanted" >/dev/null

      running=$(docker inspect --format '{{.Image}}' blazie 2>/dev/null || echo none)
      latest=$(docker inspect --format '{{.Id}}' "$wanted" 2>/dev/null || echo none)

      [ "$running" = "$latest" ] && exit 0

      docker rm -f blazie
      docker run -d --name blazie --restart always \\
        --env-file /etc/blazie.env \\
        -v /var/lib/blazie:/data \\
        -p 127.0.0.1:4000:4000 \\
        "$wanted"
      UPGRADE

      sed -i "s|HOME_URL|${opening.home}/api/clusters/${opening.id}|; s|HELLO_TOKEN|${opening.hello}|" /usr/local/bin/blazie-upgrade
      sed -i 's/^      //' /usr/local/bin/blazie-upgrade
      chmod +x /usr/local/bin/blazie-upgrade

      cat > /etc/systemd/system/blazie-upgrade.service <<'UNIT'
      [Unit]
      Description=Ask what image this cluster should run
      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/blazie-upgrade
      UNIT

      cat > /etc/systemd/system/blazie-upgrade.timer <<'TIMER'
      [Unit]
      Description=Ask on a cadence
      [Timer]
      OnBootSec=15min
      OnUnitActiveSec=15min
      [Install]
      WantedBy=timers.target
      TIMER

      sed -i 's/^      //' /etc/systemd/system/blazie-upgrade.service /etc/systemd/system/blazie-upgrade.timer
      systemctl daemon-reload
      systemctl enable --now blazie-upgrade.timer

runcmd:
  # One entry, and a file rather than folded lines. The previous version put
  # multi-line \`docker run\` invocations directly in \`runcmd\`, which relies on
  # YAML plain-scalar folding and gives no way to set -e, no way to trap, and no
  # log to read afterwards. A script is a thing that can report.
  - bash -c '/usr/local/bin/blazie-open >>/var/log/blazie-open.log 2>&1'
`
}

function basic({ token }: Credentials): string {
  return `Bearer ${token}`
}

// UpCloud says why in a shape of its own, and the operator needs the why rather
// than the status code.
async function said(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as {
      error?: { error_message?: string; error_code?: string }
    }

    if (body.error?.error_message) {
      return `UpCloud refused: ${body.error.error_message}${
        body.error.error_code ? ` (${body.error.error_code})` : ""
      }`
    }
  } catch {
    // Not JSON.
  }

  return `UpCloud answered ${response.status} without saying why. Check UPCLOUD_TOKEN, and that the account is permitted to create servers and has cores and memory left within its resource limits.`
}
