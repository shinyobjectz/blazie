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

import { asHostname, mintToken, presenting, same } from "../lib/control/clusters.ts"
import { type Held, type Studio, shown, studioShown } from "../lib/control/model.ts"
import * as phoenix from "../lib/control/phoenix.ts"
import * as tunnel from "../lib/control/tunnel.ts"
import * as upcloud from "../lib/control/upcloud.ts"

/* ------------------------------------------------------------ the boundary */

type Sent = { url: string; method: string; headers: Record<string, string>; body: unknown }

/**
 * The shapes these assertions expect to have been sent.
 *
 * Named rather than reached into with `any`, because writing down what a
 * request should look like IS the test — the sending code chose this shape and
 * these types are the second opinion about it.
 */
type ServerCreate = {
  server: {
    firewall: string
    login_user: { create_password: string; ssh_keys?: unknown }
    user_data: string
    storage_devices: { storage_device: { storage: string }[] }
  }
}

type FirewallRule = { firewall_rule: Record<string, string> }
type StopServer = { stop_server: { stop_type: string } }
type TunnelConfig = { config: { ingress: { hostname?: string; service: string }[] } }
type DnsRecord = { type: string; content: string; proxied: boolean }

function bodyOf<T>(one: Sent): T {
  return one.body as T
}

let sent: Sent[] = []
type Answer = { ok: boolean; status?: number; body: unknown }

let answers: (() => Answer)[] = []
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

    const next: () => Answer =
      answers.shift() ?? (() => ({ ok: true, body: { success: true, result: {} } }))
    const said = next()

    return {
      ok: said.ok,
      status: said.status ?? (said.ok ? 200 : 500),
      json: async () => said.body,
    } as Response
  }) as typeof fetch
}

/** Queue what the vendor answers, in order. */
function answering(...these: Answer[]) {
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
    masterKey: "MASTER",
    home: "https://blazie.dev",
    id: "CLUSTER",
    hello: "HELLO",
  }

  it("clones a template that exists", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "server-1" } } })
    await upcloud.open(credentials, opening)

    const storage = bodyOf<ServerCreate>(sent[0]).server.storage_devices.storage_device[0]

    // The uuid written here first was not a template at all, and nothing said so
    // until a machine failed to clone four minutes into a provision that had
    // already made a tunnel, a name and a server. Debian 12 Bookworm.
    assert.equal(storage.storage, "01000000-0000-4000-8000-000020070100")
  })

  it("creates no login, and publishes blazie only to loopback", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "server-1" } } })
    await upcloud.open(credentials, opening)

    const server = bodyOf<ServerCreate>(sent[0]).server

    // The machine is not something anybody logs into. It runs one container and
    // dials out, and the whole security story rests on there being nothing to
    // reach — so a password or a key here is the fence coming down.
    assert.equal(server.login_user.create_password, "no")
    assert.equal(server.login_user.ssh_keys, undefined)

    // Which is where "nothing to reach" actually comes from, and it is worth
    // asserting because it is what makes the line below survivable: blazie is
    // bound to loopback, so it is not on the public interface whatever the
    // firewall says.
    assert.match(server.user_data, /-p 127\.0\.0\.1:4000:4000/)
  })

  it("makes the machine with its firewall off, and closes it later", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "server-1" } } })
    await upcloud.open(credentials, opening)

    // This said "on" for as long as it was wrong, which was every provision.
    //
    // UpCloud denies everything both ways until rules exist, and rules are
    // refused while the disk clones — so a machine created with the firewall on
    // boots with no dns, no apt, no pull and no tunnel, and cannot report any of
    // it, because reporting is a request too. Two attempts to close that gap
    // from here failed: posting rules into `maintenance` and ignoring the
    // refusals, then waiting for the machine in `waitUntil`, which does not
    // outlive the response by the minute a clone takes.
    //
    // So it is off at birth and switched on by `wall` once the machine says it
    // is through the tunnel. Defence in depth is worth having and is not worth
    // a machine that cannot boot.
    assert.equal(bodyOf<ServerCreate>(sent[0]).server.firewall, "off")
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

describe("what the account will allow", () => {
  it("notices a trial firewall, which no tunnel can survive", async () => {
    stub()
    answering({
      ok: true,
      body: { account: { trial_resource_limits: { trial_firewall_restrictions: 1, trial_total_server_cores: 6 } } },
    })

    const said = await upcloud.limits({ token: "t" })

    assert.equal(said.ok, true)
    if (!said.ok) return
    assert.equal(said.trialFirewall, true)
    assert.equal(said.cores, 6)
  })

  it("says a paid account has no such restriction", async () => {
    stub()
    answering({ ok: true, body: { account: { trial_resource_limits: {} } } })

    const said = await upcloud.limits({ token: "t" })

    assert.equal(said.ok, true)
    if (!said.ok) return
    assert.equal(said.trialFirewall, false)
  })
})

describe("what the account is already spending", () => {
  it("counts the machines rather than trusting a tally", async () => {
    stub()
    answering({
      ok: true,
      body: { servers: { server: [{ plan: "1xCPU-2GB" }, { plan: "2xCPU-4GB" }] } },
    })

    assert.deepEqual(await upcloud.spent({ token: "t" }), { cores: 3, memory: 6144 })
  })

  it("counts a plan it does not sell, because the account still pays for it", async () => {
    stub()
    answering({ ok: true, body: { servers: { server: [{ plan: "8xCPU-32GB" }] } } })

    assert.deepEqual(await upcloud.spent({ token: "t" }), { cores: 8, memory: 32768 })
  })

  it("counts nothing when there is nothing", async () => {
    stub()
    answering({ ok: true, body: { servers: {} } })

    assert.deepEqual(await upcloud.spent({ token: "t" }), { cores: 0, memory: 0 })
  })
})

describe("what a machine is allowed to say back", () => {
  const opening = {
    name: "atlas",
    hostname: "atlas",
    zone: "us-nyc1",
    plan: "1xCPU-2GB",
    tunnelToken: "TUNNEL-TOKEN",
    secret: "SECRET-KEY-BASE",
    masterKey: "MASTER-KEY",
    home: "https://blazie.dev",
    id: "CLUSTER",
    hello: "HELLO-TOKEN",
    backup: {
      bucket: "b",
      endpoint: "e",
      accessKeyId: "BACKUP-KEY-ID",
      secretAccessKey: "BACKUP-SECRET",
      prefix: "p",
    },
    blobs: {
      bucket: "b2",
      endpoint: "e",
      accessKeyId: "BLOB-KEY-ID",
      secretAccessKey: "BLOB-SECRET",
      prefix: "p",
    },
  }

  it("blanks every credential it was given", () => {
    // `died` sends the tail of cloud-init's log, and that log is written by a
    // script holding all of these. The console prints what comes back. So the
    // most useful thing a failing machine can say was also the way every secret
    // could leave it — shown, by design, to whoever is watching it open.
    const blanked = upcloud.scrubbing(opening).map((one) => one.value)

    for (const secret of [
      opening.tunnelToken,
      opening.secret,
      opening.masterKey,
      opening.hello,
      opening.backup.accessKeyId,
      opening.backup.secretAccessKey,
      opening.blobs.accessKeyId,
      opening.blobs.secretAccessKey,
    ]) {
      assert.ok(blanked.includes(secret), `${secret} would have been sent as written`)
    }
  })

  it("does not blank the empty string, which would match everywhere", () => {
    const bare = { ...opening, backup: undefined, blobs: undefined }

    // A `sed` for the empty string replaces between every character, so a
    // cluster with no bucket would have turned its whole log into markers.
    assert.equal(upcloud.scrubbing(bare).some((one) => one.value === ""), false)
  })
})

describe("walling the machine in", () => {
  const fine = { ok: true, body: {} }

  it("opens everything the machine needs, not only the tunnel's port", async () => {
    stub()
    answering(...Array.from({ length: 15 }, () => fine))

    assert.equal(await upcloud.wall({ token: "t" }, "server-1"), true)

    // This used to send four rules, all for 7844, on the belief that switching
    // the firewall on brings UpCloud's permissive default set. What was actually
    // being described was the TRIAL firewall — and on an ordinary account,
    // firewall on with no rules denies everything both ways. So taking the
    // account out of trial turned a machine that could do everything except
    // dial the tunnel into one that could not resolve a name, install anything,
    // or report that it could not. This assertion is the difference.
    const rules = sent.filter((one) => one.url.endsWith("/firewall_rule"))
    assert.equal(rules.length, 14)

    const ports = rules.map((one) => {
      const rule = bodyOf<FirewallRule>(one).firewall_rule
      assert.equal(rule.direction, "out")
      assert.equal(rule.action, "accept")
      return `${rule.family}/${rule.protocol}/${rule.destination_port_start}`
    })

    // Each of these is load-bearing: without 53 nothing resolves, without 123
    // tls rejects every certificate, without 80 apt stops, without 443 neither
    // docker pull nor saying how it is getting on works, and without 7844 the
    // tunnel never registers.
    for (const family of ["IPv4", "IPv6"]) {
      for (const want of ["tcp/53", "udp/53", "udp/123", "tcp/80", "tcp/443", "tcp/7844", "udp/7844"]) {
        assert.ok(ports.includes(`${family}/${want}`), `${family}/${want} was never opened`)
      }
    }
  })

  it("says what may pass before it starts enforcing", async () => {
    stub()
    answering(...Array.from({ length: 15 }, () => fine))

    await upcloud.wall({ token: "t" }, "server-1")

    // The order IS the fix. Switching the firewall on before the rules exist is
    // the sealed box: no dns, no apt, no pull, no tunnel, and no way to report
    // any of it, because reporting is a request too. A machine is therefore
    // made with the firewall off and closed only once it is up.
    const on = sent.at(-1)!
    assert.equal(on.method, "PUT")
    assert.match(on.url, /\/server\/server-1$/)
    assert.equal(bodyOf<{ server: { firewall: string } }>(on).server.firewall, "on")

    assert.equal(sent.slice(0, -1).every((one) => one.url.endsWith("/firewall_rule")), true)
  })

  it("does not start enforcing when a rule would not take", async () => {
    stub()
    answering({ ok: false, status: 400, body: {} })

    assert.equal(await upcloud.wall({ token: "t" }, "server-1"), false)

    // The half-applied case is the dangerous one: some rules on, the firewall
    // switched on, and everything they do not cover silently dropped.
    assert.equal(sent.some((one) => one.method === "PUT"), false)
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
    assert.equal(bodyOf<StopServer>(sent[0]).stop_server.stop_type, "hard")

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

    const ingress = bodyOf<TunnelConfig>(sent[1]).config.ingress

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

    const record = bodyOf<DnsRecord>(sent[2])

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

  it("knows a name already answering on the zone", async () => {
    stub()
    answering({ ok: true, body: { success: true, result: [{ id: "dns-1" }] } })

    assert.equal(await tunnel.taken(reaching, "atlas.blazie.dev"), true)
  })

  it("and knows a free one", async () => {
    stub()
    answering({ ok: true, body: { success: true, result: [] } })

    assert.equal(await tunnel.taken(reaching, "atlas.blazie.dev"), false)
  })

  it("stops at the first refusal rather than carrying on", async () => {
    stub()
    answering({ ok: false, status: 403, body: { success: false, errors: [{ message: "no" }] } })

    const made = await tunnel.make(reaching, "atlas", "blazie.dev")

    assert.equal(made.ok, false)
    assert.equal(sent.length, 1)
  })

  it("retries a tunnel cloudflare will not delete yet", async () => {
    stub()
    answering(
      { ok: true, body: { success: true, result: [] } },
      // "This tunnel has active connections. Please stop all cloudflared
      // replicas, or wait a few minutes" — the window a destroy lands in,
      // measured at 30 seconds.
      { ok: false, status: 400, body: { success: false, errors: [{ message: "active connections" }] } },
      { ok: true, body: { success: true, result: {} } },
    )

    assert.equal(await tunnel.unmake(reaching, "tunnel-1", "atlas.blazie.dev"), true)
    assert.equal(sent.filter((one) => one.method === "DELETE").length, 2)
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

describe("studios, the tenant boundary", () => {
  const alpha: Studio = { id: "s-alpha", name: "alpha", token: "ALPHA-TOKEN", opened: "" }
  const beta: Studio = { id: "s-beta", name: "beta", token: "BETA-TOKEN", opened: "" }

  const cluster: Held = {
    id: "c1",
    name: "atlas",
    address: "https://atlas.blazie.dev",
    token: "FOUNDING-TOKEN",
    hello: "HELLO",
    state: "open",
    opened: "",
    studios: [alpha, beta],
  }

  it("speaks as the studio that was named", () => {
    assert.equal(presenting(cluster, "s-alpha"), "ALPHA-TOKEN")
    assert.equal(presenting(cluster, "s-beta"), "BETA-TOKEN")
  })

  it("speaks as the founding caller when none is named", () => {
    assert.equal(presenting(cluster, null), "FOUNDING-TOKEN")
    assert.equal(presenting(cluster, undefined), "FOUNDING-TOKEN")
  })

  it("refuses a studio that does not exist, rather than falling back", () => {
    // The single worst way this could fail: a typo in a studio id quietly
    // becoming the founding token, which owns every world on the cluster.
    assert.equal(presenting(cluster, "s-typo"), null)
  })

  it("works on a cluster opened before studios existed", () => {
    const older: Held = { ...cluster, studios: undefined }

    assert.equal(presenting(older, null), "FOUNDING-TOKEN")
    assert.equal(presenting(older, "s-alpha"), null)
  })

  it("never carries a studio's token to a browser", () => {
    const out = shown(cluster)
    const json = JSON.stringify(out)

    // A nested credential is the one a `shown` written for the outer shape
    // forgets. Both are checked because both would be a leak.
    assert.equal(json.includes("ALPHA-TOKEN"), false)
    assert.equal(json.includes("BETA-TOKEN"), false)
    assert.equal(json.includes("FOUNDING-TOKEN"), false)

    assert.deepEqual(out.studios.map((s) => s.name), ["alpha", "beta"])
    assert.equal(studioShown(alpha).name, "alpha")
    assert.equal((studioShown(alpha) as Record<string, unknown>).token, undefined)
  })

  it("shows an empty list rather than nothing, on an older cluster", () => {
    // The console maps over this. `undefined` would be a crash on exactly the
    // clusters that existed before the feature.
    assert.deepEqual(shown({ ...cluster, studios: undefined }).studios, [])
  })
})

describe("what a machine said, kept in order", () => {
  it("bounds the account so a retrying machine cannot grow it forever", async () => {
    const { SAID_KEPT } = await import("../lib/control/model.ts")

    // Generous enough that a real install never reaches it — six steps — and
    // finite so a machine looping on a failure cannot fill a KV value.
    assert.ok(SAID_KEPT > 6)
    assert.ok(SAID_KEPT <= 100)
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
    masterKey: "MASTER",
        home: "https://blazie.dev",
        id: "CLUSTER",
        hello: "HELLO",
      },
    )

    rendered = bodyOf<ServerCreate>(sent[0]).server.user_data

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

  it("writes an upgrade script that is also valid bash", () => {
    // A script inside a heredoc inside a script inside YAML. Checking only the
    // outer one would leave the inner one exactly as unchecked as the whole
    // cloud-init used to be — and it is the one that runs unattended, forever,
    // on a timer.
    const from = script.indexOf("<<'UPGRADE'") + "<<'UPGRADE'\n".length
    const to = script.indexOf("UPGRADE\n", from)
    const inner = script
      .slice(from, to)
      .split("\n")
      .map((line) => line.replace(/^ {6}/, ""))
      .join("\n")

    const dir = mkdtempSync(join(tmpdir(), "blazie-"))
    const path = join(dir, "blazie-upgrade")
    writeFileSync(path, inner)

    execFileSync("bash", ["-n", path])

    // And it must be pointed somewhere before it runs, which a `sed` in the
    // outer script does.
    assert.match(inner, /HOME_URL\/image\?hello=HELLO_TOKEN/)
    assert.match(script, /sed -i "s\|HOME_URL\|/)
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

  it("dials out over tcp, not quic", () => {
    // cloudflared prefers QUIC on UDP/7844 and the machine's firewall does not
    // pass it — the log said "Initial protocol quic" and then never registered.
    // http2 is cloudflared's own fallback and rides TCP/443 like everything
    // else the machine does.
    assert.match(script, /--protocol http2/)
  })

  it("quotes the END of a log, where the error is", () => {
    // The first failure came back showing cloudflared's version banner, because
    // the detail was cut from the front. A truncated log that omits the error is
    // the same as no log.
    assert.match(script, /tail -c 1500/)
  })

  it("proves the tunnel connected, not merely that a container is up", () => {
    // A provision once reported `tunnelled` while Cloudflare served 1033: the
    // container had stayed up and never registered. Those are different facts.
    assert.match(script, /Registered tunnel connection/)
  })

  it("installs an upgrade it ASKS for, since nothing can push at it", () => {
    // A cluster listens on nothing, so an upgrade cannot be pushed — and a port
    // to be upgraded through would undo the reason it has none.
    assert.match(script, /blazie-upgrade/)
    assert.match(script, /systemctl enable --now blazie-upgrade\.timer/)
    // Compared by digest, so `latest` moving is the signal and a restart only
    // happens when the image actually changed.
    assert.match(script, /docker inspect --format/)
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

  it("carries a master key, so sealing protects something", () => {
    // Without one the keyring falls back to a constant in a public repository:
    // sealing appears to work and anybody can decrypt it. Silent, until this.
    assert.match(rendered, /BLAZIE_MASTER_KEY=MASTER/)
  })

  it("carries where to back up, when there is somewhere", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "s" } } })

    await upcloud.open(
      { token: "t" },
      {
        name: "atlas", hostname: "atlas", zone: "us-nyc1", plan: "1xCPU-2GB",
        tunnelToken: "T", secret: "S", masterKey: "M", home: "https://blazie.dev", id: "CID", hello: "H",
        backup: {
          bucket: "blazie-clusters",
          endpoint: "https://acct.r2.cloudflarestorage.com",
          accessKeyId: "AKI",
          secretAccessKey: "SAK",
          prefix: "clusters/CID/",
        },
      },
    )

    const yaml = bodyOf<ServerCreate>(sent[0]).server.user_data

    assert.match(yaml, /BACKUP_BUCKET=blazie-clusters/)
    assert.match(yaml, /BACKUP_PREFIX=clusters\/CID\//)
    assert.match(yaml, /BACKUP_ACCESS_KEY_ID=AKI/)
  })

  it("carries where blobs live, in a different bucket from the backup", async () => {
    stub()
    answering({ ok: true, body: { server: { uuid: "s" } } })

    await upcloud.open(
      { token: "t" },
      {
        name: "atlas", hostname: "atlas", zone: "us-nyc1", plan: "1xCPU-2GB",
        tunnelToken: "T", secret: "S", masterKey: "M", home: "https://blazie.dev",
        id: "CID", hello: "H",
        backup: { bucket: "blazie-clusters", endpoint: "https://r2", accessKeyId: "AKI", secretAccessKey: "SAK", prefix: "clusters/CID/" },
        blobs: { bucket: "blazie-blobs", endpoint: "https://r2", accessKeyId: "AKI", secretAccessKey: "SAK", prefix: "clusters/CID/" },
      },
    )

    const yaml = bodyOf<ServerCreate>(sent[0]).server.user_data

    assert.match(yaml, /BLOB_BUCKET=blazie-blobs/)
    assert.match(yaml, /BACKUP_BUCKET=blazie-clusters/)
    // Different buckets on purpose: a backup is a copy of this cluster and a
    // blob is the cluster's data. A restore that overwrote blobs with a copy of
    // itself would be a bad day.
    assert.notEqual(
      /BLOB_BUCKET=(\S+)/.exec(yaml)?.[1],
      /BACKUP_BUCKET=(\S+)/.exec(yaml)?.[1],
    )
  })

  it("omits blobs entirely when there is nowhere to put them", () => {
    assert.equal(/BLOB_BUCKET=/.test(rendered), false)
  })

  it("omits backup entirely rather than configuring an empty one", () => {
    // `runtime.exs` decides whether to back up by whether BACKUP_BUCKET is set.
    // A blank one configures a destination that does not exist and fails on the
    // first cadence rather than at boot, which is the worse of the two.
    assert.equal(/BACKUP_BUCKET=/.test(rendered), false)
  })
})

/* ----------------------------------------------------------------- watching */

describe("speaking phoenix's channel protocol", () => {
  it("frames as a positional array, which is what the wire wants", () => {
    // `[join_ref, ref, topic, event, payload]`. A wire format rather than an
    // API, so it is written down once instead of inferred at three call sites.
    assert.deepEqual(JSON.parse(phoenix.joining("watch:x", "main", "return 1")), [
      "1",
      "1",
      "watch:x",
      "phx_join",
      { world: "main", source: "return 1" },
    ])
  })

  it("beats, because phoenix drops a socket that stops talking", () => {
    assert.deepEqual(JSON.parse(phoenix.heartbeat(7)), [null, "7", "phoenix", "heartbeat", {}])
    // The server times out at 60s, so one missed beat survives and two do not.
    assert.ok(phoenix.HEARTBEAT_MS < 60_000 / 2 + 1)
  })

  it("carries the token in the socket url, where the browser never sees it", () => {
    const url = new URL(phoenix.socketUrl("https://atlas.blazie.dev", "THE-TOKEN"))

    assert.equal(url.pathname, "/socket/websocket")
    assert.equal(url.searchParams.get("token"), "THE-TOKEN")
    // Phoenix refuses a socket that does not say which protocol it speaks.
    assert.equal(url.searchParams.get("vsn"), "2.0.0")
    // `https`, not `wss` — a Worker upgrades an https fetch; wss is what a
    // browser would dial and is not what happens here.
    assert.equal(url.protocol, "https:")
  })

  it("reads a frame back, and refuses anything that is not one", () => {
    assert.deepEqual(phoenix.readFrame('["1","1","t","e",{"a":1}]'), ["1", "1", "t", "e", { a: 1 }])
    assert.equal(phoenix.readFrame("not json"), null)
    assert.equal(phoenix.readFrame('{"not":"an array"}'), null)
    assert.equal(phoenix.readFrame('["too","short"]'), null)
  })

  it("names its events, so a browser can tell an answer from a refusal", () => {
    assert.equal(phoenix.event("answer", { value: 1 }), 'event: answer\ndata: {"value":1}\n\n')
  })
})
