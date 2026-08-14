/**
 * The control plane, tested at the boundary it talks to vendors through.
 *
 * This is the half of blazie that holds every credential and creates billable
 * infrastructure, and it had no tests at all while the cluster had six hundred.
 * Both bugs found in it so far were found by running it against live vendors and
 * then checking the vendors afterwards — a template uuid that was not a
 * template, and a destroy that reported success while leaving a machine running.
 * Neither is visible from the outside; both are visible in what was SENT.
 *
 * So `fetch` is replaced and every assertion is about the request. That is the
 * only way to test this without spending money, and it happens to be the shape
 * that catches the failures that actually occurred.
 */

import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { after, before, describe, it } from "node:test"

import { asHostname, mintToken, same } from "../lib/control/clusters.ts"
import { type Held, shown } from "../lib/control/model.ts"
import * as tunnel from "../lib/control/tunnel.ts"
import * as upcloud from "../lib/control/upcloud.ts"

/* ------------------------------------------------------------ the boundary */

type Sent = { url: string; method: string; headers: Record<string, string>; body: unknown }

let sent: Sent[] = []
let answers: (() => { ok: boolean; status?: number; body: unknown })[] = []
const realFetch = globalThis.fetch

function stub() {
  sent = []
  answers = []

  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const headers = Object.fromEntries(
      Object.entries((init?.headers ?? {}) as Record<string, string>),
    )

    sent.push({
      url: String(input),
      method: init?.method ?? "GET",
      headers,
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
    })

    const next = answers.shift() ?? (() => ({ ok: true, body: { success: true, result: {} } }))
    const said = next()

    return {
      ok: said.ok,
      status: said.status ?? (said.ok ? 200 : 500),
      json: async () => said.body,
    } as Response
  }) as typeof fetch
}

/** Queue what the vendor answers, in order. */
function answering(...these: { ok: boolean; status?: number; body: unknown }[]) {
  answers.push(...these.map((one) => () => one))
}

before(stub)
after(() => {
  globalThis.fetch = realFetch
})

/* --------------------------------------------------------------- upcloud */

describe("making a machine", () => {
  const credentials = { token: "ucat_test" }

  const opening = {
    name: "atlas",
    hostname: "atlas",
    zone: "us-nyc1",
    plan: "1xCPU-2GB",
    tunnelToken: "TUNNEL",
    secret: "SECRET",
    home: "https://blazie.dev",
    id: "CLUSTER",
    hello: "HELLO",
  }

  it("clones a template that exists", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "server-1" } } })
    await upcloud.open(credentials, opening)

    const storage = (sent[0].body as any).server.storage_devices.storage_device[0]

    // The uuid written here first was not a template at all, and nothing said so
    // until a machine failed to clone four minutes into a provision that had
    // already made a tunnel, a name and a server. Debian 12 Bookworm.
    assert.equal(storage.storage, "01000000-0000-4000-8000-000020070100")
  })

  it("opens no port and creates no login", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "server-1" } } })
    await upcloud.open(credentials, opening)

    const server = (sent[0].body as any).server

    // The machine is not something anybody logs into. It runs one container and
    // dials out, and the whole security story rests on there being nothing to
    // reach — so a password or an opened port here is the fence coming down.
    assert.equal(server.firewall, "on")
    assert.equal(server.login_user.create_password, "no")
    assert.equal(server.login_user.ssh_keys, undefined)
  })

  it("presents the token as a bearer, not basic auth", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "server-1" } } })
    await upcloud.open(credentials, opening)

    assert.equal(sent[0].headers.authorization, "Bearer ucat_test")
  })

  it("says why when UpCloud refuses, in UpCloud's own words", async () => {
    stub()
    answering({
      ok: false,
      status: 402,
      body: { error: { error_message: "resource limit reached", error_code: "LIMIT" } },
    })

    const said = await upcloud.open(credentials, opening)

    assert.equal(said.ok, false)
    if (said.ok) return
    assert.match(said.repair, /resource limit reached/)
    assert.match(said.repair, /LIMIT/)
  })

  it("refuses when UpCloud accepts and names no machine", async () => {
    stub()
    answering({ ok: true, body: { server: {} } })

    const said = await upcloud.open(credentials, opening)

    // Worse than a refusal: a machine may exist and nothing points at it.
    assert.equal(said.ok, false)
    if (said.ok) return
    assert.match(said.repair, /did not say which machine/)
  })
})

describe("taking a machine away", () => {
  const credentials = { token: "ucat_test" }

  it("stops before deleting, because UpCloud refuses a running server", async () => {
    stub()
    answering(
      { ok: true, body: {} }, // stop
      { ok: true, body: { server: { state: "stopped" } } }, // poll
      { ok: true, body: {} }, // delete
    )

    const gone = await upcloud.close(credentials, "server-1")

    assert.equal(gone, true)
    assert.match(sent[0].url, /\/server\/server-1\/stop$/)
    assert.equal(sent[0].method, "POST")
    assert.equal((sent[0].body as any).stop_server.stop_type, "hard")

    const deleted = sent.at(-1)!
    assert.equal(deleted.method, "DELETE")
    assert.match(deleted.url, /storages=1/)
  })

  it("waits rather than assuming the stop was instant", async () => {
    stub()
    answering(
      { ok: true, body: {} },
      { ok: true, body: { server: { state: "started" } } },
      { ok: true, body: { server: { state: "stopped" } } },
      { ok: true, body: {} },
    )

    assert.equal(await upcloud.close(credentials, "server-1"), true)

    // Polled twice: a delete sent after the first look would have been refused
    // exactly as it was in production.
    assert.equal(sent.filter((s) => s.method === "GET").length, 2)
  })

  it("reports failure instead of swallowing it", async () => {
    stub()
    answering(
      { ok: true, body: {} },
      { ok: true, body: { server: { state: "stopped" } } },
      { ok: false, status: 409, body: {} },
    )

    // This returned nothing at all once, and the caller reported `destroyed:
    // true` while a machine kept running and billing. A destroy that cannot
    // confirm must not claim.
    assert.equal(await upcloud.close(credentials, "server-1"), false)
  })
})

/* ---------------------------------------------------------------- tunnel */

describe("the way in", () => {
  const reaching = { accountId: "acct", zoneId: "zone", token: "account-token" }

  const madeTunnel = {
    ok: true,
    body: { success: true, result: { id: "tunnel-1", token: "TUNNEL_TOKEN" } },
  }
  const ok = { ok: true, body: { success: true, result: {} } }

  it("makes the tunnel, routes it, then names it — in that order", async () => {
    stub()
    answering(madeTunnel, ok, { ok: true, body: { success: true, result: { id: "dns-1" } } })

    const made = await tunnel.make(reaching, "atlas", "blazie.dev")

    assert.equal(made.ok, true)
    assert.match(sent[0].url, /cfd_tunnel$/)
    assert.match(sent[1].url, /configurations$/)
    assert.match(sent[2].url, /dns_records$/)
  })

  it("routes everything on the hostname to loopback and nothing else", async () => {
    stub()
    answering(madeTunnel, ok, { ok: true, body: { success: true, result: { id: "dns-1" } } })
    await tunnel.make(reaching, "atlas", "blazie.dev")

    const ingress = (sent[1].body as any).config.ingress

    assert.deepEqual(ingress[0], {
      hostname: "atlas.blazie.dev",
      service: "http://127.0.0.1:4000",
    })
    // Anything else is a 404 rather than reaching the cluster: a tunnel that
    // forwarded unmatched hostnames would make every cluster reachable at every
    // other cluster's name.
    assert.deepEqual(ingress.at(-1), { service: "http_status:404" })
  })

  it("proxies the record, which is what puts cloudflare in front", async () => {
    stub()
    answering(madeTunnel, ok, { ok: true, body: { success: true, result: { id: "dns-1" } } })
    await tunnel.make(reaching, "atlas", "blazie.dev")

    const record = sent[2].body as any

    assert.equal(record.type, "CNAME")
    assert.equal(record.content, "tunnel-1.cfargotunnel.com")
    // Unproxied would expose the tunnel hostname directly and skip the WAF, the
    // rate limiting and the DDoS protection this design is paying for.
    assert.equal(record.proxied, true)
  })

  it("uses the zone token for the zone and the account token for the account", async () => {
    stub()
    answering(madeTunnel, ok, { ok: true, body: { success: true, result: { id: "dns-1" } } })

    await tunnel.make({ ...reaching, dnsToken: "zone-token" }, "atlas", "blazie.dev")

    // Cloudflare puts Tunnel on the account and DNS on the zone, and a token
    // minted for one commonly carries none of the other — measured twice, on two
    // freshly made tokens that came out exact mirror images.
    assert.equal(sent[0].headers.authorization, "Bearer account-token")
    assert.equal(sent[1].headers.authorization, "Bearer account-token")
    assert.equal(sent[2].headers.authorization, "Bearer zone-token")
  })

  it("falls back to the one token when there is only one", async () => {
    stub()
    answering(madeTunnel, ok, { ok: true, body: { success: true, result: { id: "dns-1" } } })
    await tunnel.make(reaching, "atlas", "blazie.dev")

    assert.equal(sent[2].headers.authorization, "Bearer account-token")
  })

  it("stops at the first refusal rather than carrying on", async () => {
    stub()
    answering({ ok: false, status: 403, body: { success: false, errors: [{ message: "no" }] } })

    const made = await tunnel.make(reaching, "atlas", "blazie.dev")

    assert.equal(made.ok, false)
    assert.equal(sent.length, 1)
  })

  it("unmaking removes the name before the tunnel", async () => {
    stub()
    answering(
      { ok: true, body: { success: true, result: [{ id: "dns-1" }] } },
      { ok: true, body: { success: true, result: {} } },
      { ok: true, body: { success: true, result: {} } },
    )

    await tunnel.unmake(reaching, "tunnel-1", "atlas.blazie.dev")

    assert.match(sent[1].url, /dns_records\/dns-1$/)
    assert.equal(sent[1].method, "DELETE")
    assert.match(sent.at(-1)!.url, /cfd_tunnel\/tunnel-1$/)
    assert.equal(sent.at(-1)!.method, "DELETE")
  })
})

/* ------------------------------------------------- what crosses the wire */

describe("what a browser is allowed to see", () => {
  const held: Held = {
    id: "c1",
    name: "atlas",
    address: "https://atlas.blazie.dev",
    token: "THE-CLUSTER-TOKEN",
    hello: "THE-OPENING-SECRET",
    state: "open",
    opened: "2026-08-14T00:00:00.000Z",
  }

  it("never carries a credential", () => {
    const out = shown(held) as Record<string, unknown>

    // The entire reason every call is proxied. A token in a browser is a token
    // in a place we do not control.
    assert.equal(out.token, undefined)
    assert.equal(out.hello, undefined)
    assert.equal(JSON.stringify(out).includes("THE-CLUSTER-TOKEN"), false)
    assert.equal(JSON.stringify(out).includes("THE-OPENING-SECRET"), false)
  })

  it("still carries what the console needs", () => {
    const out = shown(held)

    assert.equal(out.name, "atlas")
    assert.equal(out.address, "https://atlas.blazie.dev")
    assert.equal(out.state, "open")
  })
})

describe("names and secrets", () => {
  it("refuses a name that leaves nothing to be a hostname", () => {
    assert.equal(asHostname("平和"), null)
    assert.equal(asHostname("---"), null)
    assert.equal(asHostname(""), null)
  })

  it("makes a hostname out of one that can be", () => {
    assert.equal(asHostname("Atlas Prime"), "atlas-prime")
    assert.equal(asHostname("--tenant_7--"), "tenant-7")
  })

  it("mints something long enough to be worth minting", () => {
    const a = mintToken()

    assert.equal(a.length, 64)
    assert.notEqual(a, mintToken())
  })

  it("compares secrets without short-circuiting", () => {
    assert.equal(same("abc", "abc"), true)
    assert.equal(same("abc", "abd"), false)
    assert.equal(same("abc", "abcd"), false)
    assert.equal(same("", ""), true)
  })
})

/* ------------------------------------------------------------ cloud-init */

describe("what the machine is told to do", () => {
  let rendered = ""
  let script = ""

  before(async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "server-1" } } })

    await upcloud.open(
      { token: "ucat_test" },
      {
        name: "atlas",
        hostname: "atlas",
        zone: "us-nyc1",
        plan: "1xCPU-2GB",
        tunnelToken: "TUNNEL",
        secret: "SECRET",
        home: "https://blazie.dev",
        id: "CLUSTER",
        hello: "HELLO",
      },
    )

    rendered = (sent[0].body as any).server.user_data

    // Pulled out the way cloud-init would, rather than by matching on text.
    const at = rendered.indexOf("      #!/usr/bin/env bash")
    const rest = rendered.slice(at)
    script = rest
      .slice(0, rest.indexOf("\nruncmd:"))
      .split("\n")
      .map((line) => line.replace(/^ {6}/, ""))
      .join("\n")
  })

  it("is cloud-config, which it must be to run at all", () => {
    assert.ok(rendered.startsWith("#cloud-config"))
  })

  it("is valid yaml", () => {
    // The first version was never checked and never worked. A machine finding
    // this out is a four minute round trip; a test finding it out is instant.
    const dir = mkdtempSync(join(tmpdir(), "blazie-"))
    const path = join(dir, "cloud-init.yaml")
    writeFileSync(path, rendered)

    const out = execFileSync("python3", [
      "-c",
      "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(' '.join(sorted(d)))",
      path,
    ])

    assert.match(String(out), /package_update/)
    assert.match(String(out), /runcmd/)
    assert.match(String(out), /write_files/)
  })

  it("is valid bash", () => {
    const dir = mkdtempSync(join(tmpdir(), "blazie-"))
    const path = join(dir, "blazie-open")
    writeFileSync(path, script)

    // `bash -n` parses without running. The previous cloud-init put multi-line
    // docker invocations directly in `runcmd`, where nothing could check them.
    execFileSync("bash", ["-n", path])
  })

  it("runs one command, and it is the script", () => {
    const runcmd = rendered.slice(rendered.indexOf("\nruncmd:"))
    const entries = runcmd.split("\n").filter((l) => l.trimStart().startsWith("- "))

    assert.equal(entries.length, 1)
    assert.match(entries[0], /blazie-open/)
    // Redirected, so a failure has something to quote back.
    assert.match(entries[0], /blazie-open\.log/)
  })

  it("reports every step, and reports dying", () => {
    for (const step of ["booted", "packages", "docker", "pulled", "serving", "tunnelled"]) {
      assert.ok(script.includes(`say ${step}`), `never says ${step}`)
    }

    // The whole reason this exists: without a trap, a failure is
    // indistinguishable from a slow install.
    assert.match(script, /trap 'died \$LINENO' ERR/)
    assert.match(script, /set -Eeuo pipefail/)
  })

  it("says where it is going and what it presents", () => {
    assert.ok(script.includes("https://blazie.dev/api/clusters/CLUSTER/said"))
    assert.ok(script.includes("HELLO"))
  })

  it("waits for blazie to answer rather than assuming a start is a serve", () => {
    // A container that starts and does not serve is the failure the image gate
    // catches in CI, and the same question is worth asking on the machine.
    assert.match(script, /127\.0\.0\.1:4000\/run/)
    assert.match(script, /401/)
  })

  it("installs what docker needs to run anything at all", () => {
    // Found by a machine, not by reading: Debian 12 enables AppArmor and
    // `docker.io` does not bring `apparmor_parser`, so `docker run` fails on a
    // system where `docker info` is perfectly happy.
    assert.match(rendered, /^ {2}- apparmor$/m)
  })

  it("proves the tunnel connected, not merely that a container is up", () => {
    // A provision once reported `tunnelled` while Cloudflare served 1033: the
    // container had stayed up and never registered. Those are different facts.
    assert.match(script, /Registered tunnel connection/)
  })

  it("closes everything inbound", () => {
    assert.match(script, /ufw --force default deny incoming/)
    assert.match(script, /ufw --force enable/)
  })

  it("binds blazie to loopback, never to the interface", () => {
    // `-p 4000:4000` would publish on every interface, which is the one edit
    // that would quietly undo the tunnel's whole argument.
    assert.ok(script.includes("-p 127.0.0.1:4000:4000"))
    assert.equal(/-p\s+4000:4000/.test(script), false)
  })

  it("carries the secret the release refuses to boot without", () => {
    assert.match(rendered, /SECRET_KEY_BASE=SECRET/)
  })

  it("carries where to back up, when there is somewhere", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "s" } } })

    await upcloud.open(
      { token: "t" },
      {
        name: "atlas", hostname: "atlas", zone: "us-nyc1", plan: "1xCPU-2GB",
        tunnelToken: "T", secret: "S", home: "https://blazie.dev", id: "CID", hello: "H",
        backup: {
          bucket: "blazie-clusters",
          endpoint: "https://acct.r2.cloudflarestorage.com",
          accessKeyId: "AKI",
          secretAccessKey: "SAK",
          prefix: "clusters/CID/",
        },
      },
    )

    const yaml = (sent[0].body as any).server.user_data

    assert.match(yaml, /BACKUP_BUCKET=blazie-clusters/)
    assert.match(yaml, /BACKUP_PREFIX=clusters\/CID\//)
    assert.match(yaml, /BACKUP_ACCESS_KEY_ID=AKI/)
  })

  it("omits backup entirely rather than configuring an empty one", () => {
    // `runtime.exs` decides whether to back up by whether BACKUP_BUCKET is set.
    // A blank one configures a destination that does not exist and fails on the
    // first cadence rather than at boot, which is the worse of the two.
    assert.equal(/BACKUP_BUCKET=/.test(rendered), false)
  })
})
