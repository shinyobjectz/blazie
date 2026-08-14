import { held, holdsStudio, keep, mintToken, presenting, reach } from "./clusters"
import { type Control, type Held, shown } from "./model"
import { type Asked, openFor, removeFor } from "./opening"
import {
  type Grant,
  mayName,
  mayOpen,
  mayRemove,
} from "./remit"
import { WORDS } from "./words"

/**
 * The surface an agent is given, as one list that is also the implementation.
 *
 * ## Why the schema and the handler are the same object
 *
 * An MCP server answers `tools/list` with what it can do and `tools/call` with
 * doing it. Written as two things — a manifest and a switch — they drift the
 * first time somebody adds a tool and forgets half, and the failure is silent:
 * a tool that is advertised and unimplemented, or implemented and invisible.
 *
 * Here there is one array. `tools/list` is a projection of it and `tools/call`
 * is a lookup in it, so there is no second place for a tool to be described.
 * Drift is not caught, it is unrepresentable.
 *
 * ## Why the prose comes from the ontology
 *
 * What a cluster is, what a world is, what a Studio is — these were argued over
 * and written down once, in `.monty/ontology.db`. An agent-facing description
 * retyped here would be a second copy of a definition that nothing compares.
 * `lib/control/words.ts` is generated from that database and `just check` fails
 * when it is stale, so the words an agent reads are the words the repo means.
 *
 * ## What is deliberately absent
 *
 * Nothing here returns a credential. Not the cluster's token, not the UpCloud
 * token, not the tunnel's. An agent gets operations, and the control plane
 * performs them — which is the entire reason this runs here rather than as a
 * package on a laptop beside a model that reads untrusted text.
 */

export type Doing = {
  env: Control
  grant: Grant
  /**
   * Where a machine this opens should report back to.
   *
   * Taken from the request rather than written down, so a preview deployment
   * provisions machines that call the preview back rather than production.
   */
  home: string
}

export type Tool = {
  name: string
  title: string
  description: string
  inputSchema: { type: "object"; properties: Record<string, unknown>; required?: string[] }
  /** Answers with what the agent should see, or throws `Refused`. */
  run: (doing: Doing, args: Record<string, unknown>) => Promise<unknown>
}

/** A refusal that carries its repair, the same shape everything else here uses. */
export class Refused extends Error {
  problem: string
  repair: string

  constructor(problem: string, repair: string) {
    super(`${problem}: ${repair}`)
    this.problem = problem
    this.repair = repair
  }
}

/** Turns a `Verdict` into a throw, so a handler reads as a sequence of permissions. */
function must(verdict: { ok: true } | { ok: false; problem: string; repair: string }) {
  if (!verdict.ok) throw new Refused(verdict.problem, verdict.repair)
}

/**
 * The clusters this grant can see at all.
 *
 * A Studio-scoped grant sees exactly the cluster holding its Studio. Scoped in
 * the listing rather than refused per call, for the same reason `worlds`
 * narrows by the remit: an agent shown a cluster it cannot act on will try it.
 */
async function withinReach(doing: Doing): Promise<Held[]> {
  const all = await held(doing.env, doing.grant.owner)
  const studio = doing.grant.remit.studio

  return studio ? all.filter((one) => holdsStudio(one, studio)) : all
}

/** The cluster by that name, from the ones this grant can see. */
async function clusterNamed(doing: Doing, name: unknown): Promise<Held> {
  const all = await withinReach(doing)
  const found = all.find((one) => one.name === name)

  if (!found) {
    throw new Refused(
      "no_such_cluster",
      `There is no cluster called ${JSON.stringify(String(name))}${
        doing.grant.remit.studio ? " within this grant's Studio" : ""
      }. The ones you hold are: ${all.map((one) => one.name).join(", ") || "none"}.`,
    )
  }

  return found
}

/**
 * The token this grant presents to a cluster.
 *
 * The founding token owns everything on the cluster, so it is the right thing
 * to present only when the grant was not narrowed to a Studio. Narrowed, the
 * Studio's own token goes instead — and a Studio that has vanished since the
 * grant was made is a refusal, never a quiet fallback to the token that owns
 * everything, because that is the single worst way for this to fail.
 */
function tokenFor(doing: Doing, cluster: Held): string {
  const token = presenting(cluster, doing.grant.remit.studio)

  if (!token) {
    throw new Refused(
      "no_such_studio",
      `This grant acts as a Studio that ${JSON.stringify(cluster.name)} no longer holds. ` +
        `The Studio was removed or the cluster rebuilt — make a new grant in the console under settings.`,
    )
  }

  return token
}

/**
 * Ask a cluster something, presenting its own token.
 *
 * The token stays here. The agent named a cluster and a world; what reaches the
 * cluster is this function, which is the only thing on either side that holds a
 * credential.
 */
async function askCluster(
  cluster: Held,
  token: string,
  path: string,
  body: unknown,
): Promise<unknown> {
  const said = await fetch(`${cluster.address}${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  }).catch(() => null)

  if (!said) {
    throw new Refused(
      "unreachable",
      `Nothing answered at ${cluster.address}. If it was opened moments ago it may still be installing — ask for its opening with the \`opening\` tool.`,
    )
  }

  const answer = (await said.json().catch(() => null)) as
    | { error?: { problem?: string; repair?: string } }
    | null

  if (!said.ok) {
    throw new Refused(
      answer?.error?.problem ?? String(said.status),
      answer?.error?.repair ?? `${cluster.address} answered ${said.status} without saying how to comply.`,
    )
  }

  return answer
}

/**
 * A word's definition, for a tool that is about that word.
 *
 * Quoted rather than paraphrased, and `WORDS` is generated — so this cannot
 * describe a cluster as something the repo stopped meaning.
 */
function says(code: keyof typeof WORDS | string): string {
  return WORDS[code]?.definition ?? ""
}

export const TOOLS: Tool[] = [
  {
    name: "clusters",
    title: "The clusters you hold",
    description: `List the clusters this grant's owner holds, with whether each is answering. ${says("clu")}`,
    inputSchema: { type: "object", properties: {} },
    run: async (doing) => {
      const all = await withinReach(doing)
      return { clusters: all.map(shown) }
    },
  },

  {
    name: "worlds",
    title: "The worlds a cluster holds",
    description: `Which worlds this grant may name on a cluster. ${says("wor")}`,
    inputSchema: {
      type: "object",
      properties: { cluster: { type: "string", description: "The cluster's name." } },
      required: ["cluster"],
    },
    run: async (doing, args) => {
      const cluster = await clusterNamed(doing, args.cluster)

      // Asked AS the Studio when the grant names one, so the answer is already
      // that Studio's holdings — the cluster's own account of the boundary,
      // not this control plane's filter over the founding token's view.
      const said = await fetch(`${cluster.address}/me`, {
        headers: { authorization: `Bearer ${tokenFor(doing, cluster)}` },
        signal: AbortSignal.timeout(15_000),
      }).catch(() => null)

      if (!said?.ok) {
        throw new Refused("unreachable", `Nothing answered at ${cluster.address}.`)
      }

      const answer = (await said.json()) as { worlds?: string[] }
      const there = answer.worlds ?? []

      // Narrowed by the remit, not merely reported and then refused later. An
      // agent shown a world it may not name will try it, and a refusal it could
      // have been spared is a turn wasted for everybody.
      const mine =
        doing.grant.remit.worlds.length === 0
          ? there
          : there.filter((one) => doing.grant.remit.worlds.includes(one))

      return { worlds: mine, cluster: cluster.name }
    },
  },

  {
    name: "run",
    title: "Run Lua against a world",
    description:
      `Run a chunk of Lua against one world and get back what it returned, plus the snapshot name it read. ` +
      `Writes land as facts. ${says("wor")} ` +
      `Pass \`as: "job"\` only when the chunk must reach the network — a formula deliberately cannot, and that fence is why a formula's numbers can be trusted.`,
    inputSchema: {
      type: "object",
      properties: {
        cluster: { type: "string", description: "The cluster's name." },
        world: { type: "string", description: "The world to run against." },
        source: { type: "string", description: "The Lua to run." },
        as: {
          type: "string",
          enum: ["formula", "job"],
          description: "`formula` cannot reach the network. `job` can. Defaults to formula.",
        },
      },
      required: ["cluster", "world", "source"],
    },
    run: async (doing, args) => {
      must(mayName(doing.grant.remit, String(args.world)))
      const cluster = await clusterNamed(doing, args.cluster)

      return askCluster(cluster, tokenFor(doing, cluster), "/run", {
        world: String(args.world),
        source: String(args.source),
        ...(args.as === "job" ? { as: "job" } : {}),
      })
    },
  },

  {
    name: "claim",
    title: "Claim a world",
    description: `Take a world name on a cluster and hold it. Names are first-come on a cluster, and one already held is refused rather than joined. ${says("wor")}`,
    inputSchema: {
      type: "object",
      properties: {
        cluster: { type: "string", description: "The cluster's name." },
        world: { type: "string", description: "The name to take." },
      },
      required: ["cluster", "world"],
    },
    run: async (doing, args) => {
      must(mayName(doing.grant.remit, String(args.world)))
      const cluster = await clusterNamed(doing, args.cluster)
      return askCluster(cluster, tokenFor(doing, cluster), "/worlds", { world: String(args.world) })
    },
  },

  {
    name: "opening",
    title: "How a cluster is getting on",
    description:
      "What a machine said on its way to becoming a cluster, oldest first — booted, packages, docker, pulled, serving, tunnelled. " +
      "The sequence up to a failure is most of the diagnosis, and a machine has no password and no key, so this is the only account of it there is.",
    inputSchema: {
      type: "object",
      properties: { cluster: { type: "string", description: "The cluster's name." } },
      required: ["cluster"],
    },
    run: async (doing, args) => {
      const cluster = await clusterNamed(doing, args.cluster)
      return {
        cluster: cluster.name,
        state: cluster.state,
        said: cluster.said ?? [],
        saying: cluster.saying ?? null,
      }
    },
  },

  {
    name: "open_cluster",
    title: "Open a cluster",
    description:
      `Make a machine, install blazie on it, and put it behind a tunnel. This SPENDS MONEY and takes two or three minutes. ` +
      `${says("clu")} Bounded by the grant: it refuses past the ceiling on how many may run at once.`,
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "What to call it. Becomes <name>.blazie.dev." },
        zone: { type: "string", description: "Where. Defaults to the first available." },
        plan: { type: "string", description: "How big. Defaults to the smallest." },
      },
      required: ["name"],
    },
    run: async (doing, args) => {
      const all = await held(doing.env, doing.grant.owner)
      must(mayOpen(doing.grant.remit, all.length))

      // The same function the console's own endpoint calls. Every check it makes
      // — the name, the zone, the account's room, the trial firewall, the name
      // already answering on the zone — is a check an agent needs more than a
      // person does, not less, and a second copy of them would drift.
      const opened = await openFor(doing.env, doing.grant.owner, args as Asked, doing.home)

      if (!opened.ok) throw new Refused(opened.problem, opened.repair)

      return {
        cluster: shown(opened.cluster),
        // Said plainly, because an agent that thinks this is finished will
        // immediately try to use it and get nothing.
        next: "It is opening, not open. Ask `opening` for how far along it is — it takes two or three minutes and the machine reports each step.",
      }
    },
  },

  {
    name: "remove_cluster",
    title: "Remove a cluster",
    description:
      "Destroy a cluster's machine and every world on it. This CANNOT BE UNDONE. Refused unless the grant was given removal deliberately, which is separate from opening for that reason.",
    inputSchema: {
      type: "object",
      properties: {
        cluster: { type: "string", description: "The cluster's name." },
        sure: { type: "boolean", description: "Must be true. There is no undo." },
      },
      required: ["cluster", "sure"],
    },
    run: async (doing, args) => {
      must(mayRemove(doing.grant.remit))
      const cluster = await clusterNamed(doing, args.cluster)

      if (args.sure !== true) {
        throw new Refused(
          "not_sure",
          `Removing ${JSON.stringify(cluster.name)} destroys every world on it and cannot be undone. Pass \`sure: true\` if that is what you mean.`,
        )
      }

      const removed = await removeFor(doing.env, doing.grant.owner, cluster.id, true)

      if (!removed.ok) throw new Refused(removed.problem, removed.repair)

      return { removed: cluster.name, destroyed: true, ...(removed.note ? { note: removed.note } : {}) }
    },
  },
]

/** What `tools/list` answers. A projection, so it cannot describe a tool that is not here. */
export function listed() {
  return TOOLS.map(({ name, title, description, inputSchema }) => ({
    name,
    title,
    description,
    inputSchema,
  }))
}

export function toolNamed(name: string): Tool | undefined {
  return TOOLS.find((one) => one.name === name)
}

/** Kept so the module's imports stay honest about what it can reach. */
export const REACHES = { reach, keep, mintToken }
