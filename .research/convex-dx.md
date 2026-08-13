# Convex Developer Experience — a mechanics map

Reference material for designing Lazy River's DX. Researched 2026-08-13 against
`docs.convex.dev` (the `llms-full.txt` corpus, ~2.4MB, which is the docs verbatim),
the `get-convex/convex-backend` source (CLI lives in `npm-packages/convex/src/cli/`),
and `stack.convex.dev`.

Read this for *mechanics and design decisions*. Section 10 is the only place that
talks about Lazy River; everything before it is description.

**A note on dates.** Convex's DX has changed materially over its life. The two
biggest shifts, both of which invalidate a lot of older writing about it:

- **Local deployments** (beta, shipped late 2024, matured through 2025). For most
  of Convex's life `npx convex dev` *required* a cloud deployment and an account.
  Now the default first run is anonymous and local.
- **Static codegen** (beta, 2025/2026) and the TypeScript-7 compiler path, both
  responses to the same complaint: inference-heavy generated types got slow.

Dated landmarks from `npm-packages/convex/CHANGELOG.md`, useful for judging
whether a blog post or forum complaint is still true:

| Version | Change |
|---|---|
| 1.17.1 (~Nov 2024) | `npx convex dev --local`, explicitly unfinished — *"not yet ready for general consumption"* |
| **1.19.0** (2025-02-06) | *"Support for Local Deployments, now in beta."* |
| **1.21.0** | *"`npx convex dev` tails logs by default. See the `--tail-logs` option."* |
| 1.26.0 (2025-08-22) | staged indexes; `schemaValidation` exposed at runtime |
| 1.27.0 | `node.nodeVersion` in `convex.json` |
| **1.32.0** | local backend data moves from `~/.convex` to `.convex` in the project root, for worktrees |
| **1.34.0** (2026-03-19) | arbitrary named deployments: `npx convex deployment create/select`, `--expiration` |
| **1.35.0** (2026-04-10) | preview deployments **reused** by default instead of recreated |
| 1.36.0 | automatic preview deployments on Cloudflare Pages |
| various | `CONVEX_AGENT_MODE=anonymous`; `--debug-node-apis`; `npx convex insights`; `--run-sh` |

Anything written about Convex before early 2025 describes a product that required
an account and a cloud round-trip to do anything at all.

### The short version

If you read nothing else, these are the load-bearing ideas:

1. **The watch set is the last build's read set** (§1.4) — not a glob. Convex
   already applies "observe what was read" to *queries*; the CLI applies the same
   trick to the *build*.
2. **A failed push names the input that would fix it, and the dev loop then
   subscribes to that input** (§1.5) — file, env var, or *database table* — and
   retries by itself when it changes. Errors as a control loop, not a message.
3. **Generated code is a manifest of names, not a projection of shapes** (§2.2) —
   which is why `_generated/` isn't a merge-conflict swamp, and why staleness
   degrades to worse autocomplete rather than a broken client.
4. **Determinism is enforced by substitution, not prohibition** (§3.3) —
   `Math.random()` is seeded, `Date.now()` is frozen at function entry — and the
   payoff is stated plainly: free retry, free caching, free invalidation (§3.4).
   Effects are quarantined into a function kind that gets none of the three.
5. **Invalidation is the OCC conflict detector run backwards** (§4.2) — "the exact
   same algorithm the committer uses for detecting serializability conflicts."
   Subscriptions are nearly free once you already need serializability.
6. **Refusal is the migration engine** (§5.3) — there is no migration system, only
   a gate that won't let a schema narrow until the data fits. Every breaking change
   is widen → backfill → narrow.
7. **A long push is a progress bar that links somewhere better** (§5.2), and index
   backfill is a *barrier before function registration*, so there's never a window
   where deployed code queries an unbuilt index (§5.4).
8. **The deploy key's type is the routing decision** (§6.3) — one command, one env
   var, and whether it's prod or a branch-named preview is a property of the
   credential.

And the sharpest things to *avoid* (§10.2):

- **There is no rollback**, and the schema gate makes rollback across a narrowing
  change impossible (§6.8). Lazy River gets this free — deploying is a write, so an
  earlier snapshot name *is* the rollback target — and should claim it as a verb
  before doctrine becomes the only answer.
- **Invalidation granularity decides your users' schemas** (§9.5). Convex
  invalidates per document and per index range, so people are told to split "hot"
  and "cold" fields into separate tables — the data model gets deformed by write
  frequency.
- **Deploying invalidates every subscription** because subscription identity is
  coupled to code identity (§9.6): 4m26s of rejections and a 3.7 MB message per
  client on a page with no subscriptions.
- **A storage-layer event must never trigger invalidation** (§9.8). A search-index
  compaction — no logical data changed — took Convex's largest customer from 50 to
  20,000 queries/second and then their own clients DDOS'd them.
- **"No need to think about this" about OCC** was a promise they spent three
  components, a docs page of error text, and an `insights` command walking back
  (§9.4); and the prescribed fix for contention is always a schema change, which is
  always a migration.
- **Two runtimes with a bundler-enforced partition is a permanent tax** (§3.3,
  §9.10) — Windows broken for a year, no Bun because it would need a third bundler,
  and a userland Zod upgrade that makes your deployment un-pushable.

Two of Convex's self-declared worst problems are things Lazy River has already
solved structurally: **server-side reactivity** (their "missing primitive… on the
to-do list for literally five years" is what `Formula` already is) and **auth**
(their #1 complaint; Lazy River made it "which ledgers a caller may name"). See
§10.0.

---

## 1. The dev loop

### 1.1 First run

The whole onboarding is one command. There is no `init`, no scaffold step, no
config file to write first.

```
npm i convex
npx convex dev
```

From the dev-workflow doc, verbatim:

> The first time you run the `npx convex dev` command you'll be asked whether you
> want start developing locally without an account or create an account.

**Anonymous/local path** (the newer default):

> `npx convex dev` will prompt you for the name of your project, and then start
> running the open-source Convex backend locally on your machine (this is also
> called a "deployment").
>
> The data for your project will be saved in the `~/.convex` directory.
>
> 1. The name of your project will get saved to your `.env.local` file so future
>    runs of `npx convex dev` will know to use this project.
> 2. A `convex/` folder will be created (if it doesn't exist), where you'll write
>    your Convex backend functions.

(The docs are inconsistent here — the local-deployments page says `.convex` in the
project, the workflow page says `~/.convex`. The changelog resolves it: it
**changed in convex 1.32.0**, and the reason is exactly the agent/worktree problem
from §1.8:

> When using a local Convex backend (local dev deployment, agent mode or anonymous
> mode), the deployment's data is now stored in a `.convex` directory in the
> project root (instead of `~/.convex`). This change is helpful when using multiple
> worktrees, since each worktree can get its own isolated storage. Existing local
> deployments are not affected.

**Per-project state beats per-user state the moment one human runs several
checkouts at once** — which is now the normal case.)

**Account path:**

> `npx convex dev` will prompt you through creating an account if one doesn't
> exist, and will add your credentials to `~/.convex/config.json` on your machine.

and then the CLI page:

> it will ask you to log in your device and create a new Convex project. It will
> then create:
>
> 1. The `convex/` directory: This is the home for your query and mutation functions.
> 2. `.env.local` with `CONVEX_DEPLOYMENT` variable: This is the main
>    configuration for your Convex project. It is the name of your development
>    deployment.

The docs never show the actual transcript, but `cli/configure.ts` does. Reassembled
from the prompt and log strings in that file, the account path is:

```
? What would you like to configure?
❯ create a new project
  choose an existing project

? Team:  my-team
? Project name:  (lazyriver)
? Which type of dev deployment would you like to use?  cloud / local

⠋ Creating new Convex project...
✔ Created project happy-otter-421 in team my-team, manage it at https://dashboard.convex.dev/t/my-team/happy-otter-421
✔ Saved VITE_CONVEX_URL and VITE_CONVEX_SITE_URL to .env.local
⠋ Preparing Convex functions...
✔ 14:31:52 Convex functions ready! (1.8s)
```

Note `Project name:` defaults to the current directory name, and the project
creation line **ends with the dashboard URL for the thing just created**. Note too
the tip printed when you are logged in but might not want to be:

```
Tip: You can try out Convex without creating an account by clearing the
CONVEX_DEPLOYMENT environment variable (often in .env.local).
```

The first run also offers to install agent instruction files (§2.6).

Design decisions worth naming:

- **The unit of identity is a deployment name in `.env.local`**, not a URL, not a
  config file in the repo. `.env.local` is gitignored, so *which backend I am
  pointed at is per-developer state, not repo state*. This is what makes "every
  developer gets their own deployment" cheap.
- **`convex/` is discovered, not registered.** There is no manifest listing your
  functions. The directory *is* the manifest. File path + export name = function
  name (§3.2).
- **Recovery is the same command.** "Run `npx convex dev` in a project directory
  without a set `CONVEX_DEPLOYMENT` to configure a new or existing project."
  There is no separate repair command.
- **Logout is a first-class verb** (`npx convex logout`) because account identity
  is machine-global (`~/.convex/config.json`), not project-local.

### 1.2 What `npx convex dev` does

The documented step list (from `npx convex dev --help`):

```
1. Configures a new or existing project (if needed)
2. Updates generated types and pushes code to the configured dev deployment
3. Runs the provided command (if `--start` or `--run` is used)
4. Watches for file changes, and repeats step 2
```

And from the dev-workflow doc, the per-save sequence:

> 1. The `npx convex dev` command typechecks your code and updates the
>    `convex/_generated` directory.
> 2. The contents of your `convex/` directory get uploaded to your dev deployment.
> 3. Your Convex dev deployment analyzes your code and finds all Convex functions.
>    In this example, it determines that `tasks.getTaskList` is a new public query
>    function.
> 4. If there are any changes to the schema, the deployment will automatically
>    enforce them.
> 5. The `npx convex dev` command updates generated TypeScript code in the
>    `convex/_generated` directory to provide end to end type safety for your
>    functions.

Note the ordering: **codegen happens twice** — once locally from source before the
push, once *after* the server has analyzed the pushed code. The server's analysis
is the authority on what the API is.

### 1.3 What it prints

From `npm-packages/convex/src/cli/lib/dev.ts`:

```ts
options.logManager?.beginDeploy();
showSpinner("Preparing Convex functions...");
try {
  await runPush(ctx, options);
  const end = performance.now();
  options.logManager?.endDeploy();
  numFailures = 0;
  logFinishedStep(
    `${getCurrentTimeString()} Convex functions ready! (${formatDuration(
      end - start,
    )})`,
  );
```

So the steady-state loop is a two-line cycle: a spinner
`Preparing Convex functions...` replaced by
`✔ 14:32:07 Convex functions ready! (412ms)`. **It prints the wall-clock time and
the duration of every push.** That is the entire feedback signal for "did my save
land, and how slow is my project getting."

There is a deliberate comment about failure output:

```ts
// NOTE: If `runPush` throws, `endDeploy` will not be called.
// This allows you to see the output from the failed deploy without
// logs getting in the way.
```

**Log interleaving is a first-class concern.** The default `--tail-logs` mode is
`pause-on-deploy`, described as: "pauses logs during deploys so you can spot sync
issues." Three modes:

```
# Show all logs continuously
npx convex dev --tail-logs always

# Pause logs during deploys to see sync issues (default)
npx convex dev

# Don't display logs while developing
npx convex dev --tail-logs disable

# Tail logs without deploying
npx convex logs
```

That is a small thing that matters a lot: a dev server that streams production
logs *and* build output into one terminal will drown its own errors, and they
solved it by muting the stream across a deploy rather than by adding colour.

### 1.4 The watcher is built from what the push actually read

This is the sharpest mechanical idea in the dev loop, and it is not in the docs —
it is in `cli/lib/dev.ts`.

The CLI does not glob `convex/**`. It runs the push inside a `WatchContext` whose
filesystem layer records every path the push touched, then builds the watch set
from those *observations*:

```ts
const observations = ctx.fs.finalize();
if (observations === "invalidated") {
  logMessage("Filesystem changed during push, retrying...");
  return;
}
// Initialize the watcher if we haven't done it already. Chokidar expects to have a
// nonempty watch set at initialization, so we can't do it before running our first
// push.
if (!watch.watcher) {
  watch.watcher = new Watcher(observations);
  await showSpinnerIfSlow("Preparing to watch files...", 500, async () => {
    await watch.watcher!.ready();
  });
  stopSpinner();
}
watch.watcher.update(observations);
```

Consequences:

- The watch set is *exactly* the dependency set of the last build — including
  files outside `convex/` that got imported, and `package.json`, and the config.
  No stale glob, no "why didn't it rebuild."
- An event only counts if `observations.overlaps(event)` says it does. Editing an
  unrelated file does nothing.
- `"invalidated"` means the tree changed *during* the push; it just retries,
  printing `Filesystem changed during push, retrying...`.

There is a **debounce/quiescence window of 500ms**:

```ts
const quiescenceDelay = 500;
...
let deadline = performance.now() + quiescenceDelay;
```

and it *extends* the deadline on each further overlapping event, so a `git
checkout` touching two hundred files produces one push, not two hundred.

`--verbose`/trace mode prints the reasoning:

```
Processing change convex/messages.ts
convex/messages.ts modified, rebuilding...
Waiting for 340ms to quiesce...
Received an overlapping event at /…/convex/schema.ts, delaying push.
```

### 1.5 The dev loop watches the *database* and the *environment*, not just files

Also from `cli/lib/dev.ts` — the loop races three watchers:

```ts
const fileSystemWatch = getFileSystemWatch(ctx, watch, cmdOptions);
const tableWatch = getTableWatch(
  ctx, options,
  tableNameTriggeringRetry?.tableName ?? null,
  tableNameTriggeringRetry?.componentPath,
);
const envVarWatch = getDeplymentEnvVarWatch(ctx, options, shouldRetryOnDeploymentEnvVarChange);
await Promise.race([
  fileSystemWatch.watch(),
  tableWatch.watch(),
  envVarWatch.watch(),
]);
```

and the table watch is itself a *subscription to a system query on the backend*:

```ts
function getTableWatch(ctx, credentials, tableName, componentPath) {
  return getFunctionWatch(ctx, {
    deploymentUrl: credentials.url,
    adminKey: credentials.adminKey,
    parsedFunctionName: "_system/cli/queryTable",
    getArgs: () => (tableName !== null ? { tableName } : null),
    componentPath,
  });
}
```

Why this exists: a push can fail for reasons that are **not in your files**. The
error taxonomy in the catch block is:

```ts
console.assert(
  e.errorType === "invalid filesystem data" ||
    e.errorType === "invalid filesystem or env vars" ||
    e.errorType["invalid filesystem or db data"] !== undefined,
);
if (e.errorType === "invalid filesystem or env vars") {
  shouldRetryOnDeploymentEnvVarChange = true;
} else if (e.errorType !== "invalid filesystem data" &&
           e.errorType["invalid filesystem or db data"] !== undefined) {
  tableNameTriggeringRetry = e.errorType["invalid filesystem or db data"];
}
```

So: **a failure names the input that would fix it, and the dev loop then watches
that input.** Push a schema that existing rows violate → the error carries the
table name → the CLI subscribes to that table → you fix the rows in the dashboard
data browser → the push retries automatically, no keystroke. Push code needing a
missing env var → the CLI subscribes to the env vars → you run `npx convex env
set` in another terminal → it retries.

This is "errors are data with the repair attached", implemented as a control loop
rather than as a message.

Transient network failures get exponential backoff with an explicit message:

```ts
logWarning(chalkStderr.yellow(
  `Failed due to network error, retrying in ${formatDuration(delay)}...`,
));
```

### 1.6 Loop-shaping flags

```
--once              Execute only the first 3 steps, stop on any failure
--until-success     Execute only the first 3 steps, on failure watch for local and
                    remote changes and retry steps 2 and 3
--run <functionName>       run a function after each successful push
--start <command>          run a long-running command alongside, e.g. 'vite --open'
--typecheck <enable|try|disable>
--codegen <mode>
--configure [choice]       --team, --project, --dev-deployment local|cloud
--env-file <envFile>
```

Three modes matter:

- `--once` is the CI/agent-setup mode: push once, exit nonzero on failure.
- `--until-success` is the "unblock me" mode: keep retrying, including on *remote*
  changes, and exit as soon as it works. This is the shape you want for a setup
  script that must not hang forever but also must not fail on a race.
- `--start 'vite --open'` folds the frontend dev server into the same process, so
  there is one terminal and one Ctrl-C. The child inherits stdin/stdout, and the
  CLI forwards SIGINT and escalates SIGINT→SIGTERM after 1000ms.

### 1.7 Local vs cloud dev

Current state (local deployments are still labelled beta):

- The local backend **runs as a subprocess of `npx convex dev`** and exits with it.
  "a `convex dev` command must be running in order to run other commands like `npx
  convex run` against this local deployment or for your frontend to connect."
- Switching is a one-liner and is *deployment selection*, not a mode flag:
  ```
  npx convex deployment select local
  npx convex deployment select dev
  ```
- Stated benefits: "code sync is faster and means resources like functions calls
  and database bandwidth don't count against the quotas for your Convex plan."
- Stated limitations, verbatim and worth copying as a checklist of what a local
  mode costs you: **no public URL** (so no webhooks, and no browser clients other
  than your own without ngrok); Node actions need a matching local Node version;
  "Node.js actions run directly on your computer … unrestricted filesystem access"
  while "Queries, mutations, and Convex runtime actions still run in isolated
  environments"; "Logs get cleared out every time a `npx convex dev` command is
  restarted"; and the dashboard doesn't work in Safari or default Brave because
  they block localhost requests.
- Explicitly **not** for production: "logs for function results and full stack
  traces for error responses are sent to connected clients."

### 1.8 Agent/worktree mode — an underrated piece of DX

Convex has a whole doc for "an AI agent is running my CLI". The problem statement
is precise:

> when cloud-based coding agents like Jules, Devin, Codex, or Cursor Cloud Agents
> run Convex CLI commands, they can't log in. And if you do log in for them, the
> agent will use your default dev deployment to develop, conflicting with your own
> changes!

Two supported answers, and one very good default:

> In non-interactive shells (the typical case for an agent's setup script), `npx
> convex` will never prompt the agent to log in — when no deployment is already
> configured and `CONVEX_DEPLOY_KEY` isn't set, the CLI defaults to provisioning a
> local deployment automatically.

i.e. **non-interactive + unauthenticated is not an error, it is a signal to
provision something disposable.** The alternative, for agents that need a real
URL:

```bash
# Create a new dev deployment and select it.
npx convex deployment create --type dev --select \
  team-slug:project-slug:dev/$USER/$(basename "$PWD") \
  --expiration "in 5 days"

# Mint a deploy key scoped only to this deployment and save it as
# CONVEX_DEPLOY_KEY in .env.local.
npx convex deployment token create agent-token --save-env

# Push code once.
npx convex dev --once
```

Note `--expiration "in 5 days"` on a *deployment*: throwaway environments have a
TTL built into the create call. And note the ordering rule they document, which
is the kind of thing that only comes from support load:

> `env set` needs a deployment to be configured first, so run it *after*
> `deployment create` (or after `npx convex init` for a local backend) and
> *before* `npx convex dev --once` so the deployed code sees the new values.

There are copy-paste worktree recipes for Codex, Conductor, Cursor local
worktrees, and T3 Code, all of the same shape: one deployment per worktree, named
after the worktree.

---

## 2. Codegen and types

### 2.1 What is in `convex/_generated/`

```
convex/
  _generated/
    api.d.ts
    api.js
    dataModel.d.ts
    server.d.ts
    server.js
  schema.ts
  myFunctions.ts
  tsconfig.json          # written on init
  README.md              # written on init
convex.json              # optional, at repo root next to package.json
.env.local               # CONVEX_DEPLOYMENT=...
```

Every generated file carries this header (`cli/codegen_templates/common.ts`):

```
/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */
```

`eslint-disable` first, the regeneration command in the header. Both are cheap and
both are right.

### 2.2 The generated code is a *manifest*, not a projection

This is the single most transferable decision in the codegen design, and it is
why `_generated/` is not a merge-conflict swamp.

`api.js` in its entirety is:

```js
import { anyApi } from "convex/server";
export const api = anyApi;
export const internal = anyApi;
```

**There is no per-function generated runtime code at all.** `anyApi` is a Proxy;
`api.messages.list` resolves to a function reference by string at runtime.

`api.d.ts` is one import line per *module*, and one map entry per module:

```ts
import type { ApiFromModules, FilterApi, FunctionReference } from "convex/server";
import type * as messages from "../messages.js";
import type * as tasks from "../tasks.js";

declare const fullApi: ApiFromModules<{
  "messages": typeof messages,
  "tasks": typeof tasks,
}>;
export declare const api: FilterApi<typeof fullApi, FunctionReference<any, "public">>;
export declare const internal: FilterApi<typeof fullApi, FunctionReference<any, "internal">>;
```

So:

- **The generated file changes only when a file is added, removed, or renamed.**
  Adding a function, changing its arguments, changing its return type — none of
  those touch `_generated/`. Two developers adding functions to different existing
  files produce *zero* diff. That is the merge-conflict answer, and it is
  structural, not a merge driver or a gitattributes hack.
- Module paths are sorted with a platform-stable comparator specifically so that
  the file is byte-identical on Windows and POSIX:

  > Sorting OS-native paths directly diverges on Windows because "\" (0x5C) sorts
  > after letters while "/" (0x2F) sorts before them.

  Deterministic generated output across machines is a prerequisite for checking it
  in, and they went to the trouble.
- `public` vs `internal` is enforced *in the generated type* by `FilterApi`, not
  by a runtime check in the client. Which functions the client can even name is a
  type-level fact derived from which builder you used.

### 2.3 What the schema drives

`dataModel.d.ts` exports four things: `TableNames` (string union), `Doc<T>`,
`Id<T>`, `DataModel`. All four come from `schema.ts`.

The graceful-degradation case is worth quoting in full, because it is a template
for how a generated artifact should behave when its input is missing
(`cli/codegen_templates/dataModel.ts`):

```ts
/**
 * No `schema.ts` file found!
 *
 * This generated code has permissive types like `Doc = any` because
 * Convex doesn't know your schema. If you'd like more type safety, see
 * https://docs.convex.dev/using/schemas for instructions on how to add a
 * schema file.
 *
 * After you change a schema, rerun codegen with `npx convex dev`.
 */
export type TableNames = string;
export type Doc = any;
export type Id<TableName extends TableNames = TableNames> = GenericId<TableName>;
```

**The absence of a schema is not an error; it produces a weaker but working
artifact that explains itself and links to the fix.** Schema is opt-in, and the
cost of not having one is visible in your editor rather than at push time.

### 2.4 Why `server.js` is generated at all

`server.js` re-exports `query`, `mutation`, `action`, `internalQuery`,
`internalMutation`, `internalAction`, `httpAction`, plus the types `QueryCtx`,
`MutationCtx`, `ActionCtx`, `DatabaseReader`, `DatabaseWriter`. The docs are blunt
about why these are not just importable from the library:

> These exports are not directly available in the `convex` package! … This is an
> alias of `queryGeneric` that is typed for your app's data model.

So the library ships `*Generic` versions parameterised by a `DataModel`, and
codegen's only job is to bind the type parameter once. **You import your builders
from your own project, not from the vendor.** Every function file therefore starts
with a relative import:

```ts
import { query } from "./_generated/server";
import { v } from "convex/values";
```

The side effect is that `./_generated/server` becomes the seam where project-wide
wrappers get installed (auth middleware, row-level security, triggers) — the
community `customQuery`/`customMutation` pattern lives exactly there.

### 2.5 Drift

Convex's position is unusually clear and worth stating as a rule:

> This code is generated automatically while running `npx convex dev` and **should
> be committed to the repo (your code won't typecheck without it!)**. Regenerating
> it explicitly is rarely needed (e.g. in CI to ensure the correct code was checked
> in).

and:

> Check in everything in your `convex/_generated/` directory. This ensures that
> your code immediately type checks and runs without having to first run `npx
> convex dev`. It's particularly useful when non-backend developers are writing
> frontend code and want to ensure their code type checks against currently
> deployed backend code.

The CI recipe is `npx convex codegen` then check `git diff --exit-code`. Note
`--dry-run` exists precisely for this ("Print out the generated configuration to
stdout instead of writing to convex directory").

There is a nice failure message when codegen is attempted in an environment that
has no deployment to ask (`cli/codegen.ts`):

```
Codegen requires an existing deployment so doesn't support CONVEX_DEPLOY_KEY.
Generate code in dev and commit it to the repo instead.
https://docs.convex.dev/understanding/best-practices/other-recommendations#check-generated-code-into-version-control
```

Three-line error: what happened, what to do instead, where to read. Note also
what it implies — **codegen is not purely a function of your source tree.** It
asks the deployment. That is what makes it correct across components and schema,
and also what makes it fail in a build box.

**What stale actually costs you** is worth being precise about, because the
manifest design (§2.2) makes it mild. `api.js` is `anyApi`, a Proxy that resolves
`api.messages.list` to the string `"messages:list"` at call time. So:

- A stale `api.d.ts` (a module file added but not regenerated) is a **type error
  only** — TypeScript doesn't know the module exists. The call would work at
  runtime if you forced it.
- A stale `dataModel.d.ts` gives you wrong `Doc<T>` shapes — again type-level.
- Calling a name the *backend* doesn't have is a **runtime** error, resolved by
  string on the server, not caught by codegen at all.

So the generated code is a *convenience over a string protocol*, and drift
degrades to "worse autocomplete", never to "broken client". That is a direct
consequence of not projecting each function into generated runtime code, and it is
why they can afford to tell people to commit the artefact.

### 2.6 Codegen extends to agent instructions — `npx convex ai-files`

Not a footnote. Convex treats the instructions it gives *coding agents* as another
generated, versioned artefact, installed during the first `npx convex dev`:

```
npx convex ai-files status     Show the current status of Convex AI files
npx convex ai-files install    Install or refresh Convex AI files
npx convex ai-files enable     Enable Convex AI files
npx convex ai-files update     Update Convex AI files to the latest version
npx convex ai-files disable    Disable without removing them
npx convex ai-files remove     Remove all Convex AI files from the project
```

What it manages:

> * `convex/_generated/ai/guidelines.md`
> * `AGENTS.md` (Convex section only)
> * `CLAUDE.md` (Convex section only)
> * Agent skills (installed to each coding agent's native path, configured via `convex.json`)

configured as:

```json
{
  "aiFiles": { "skills": { "agents": ["claude-code", "codex", "cursor"] } }
}
```

with `"aiFiles": {"enabled": false}` to suppress the suggestions entirely.

Three decisions worth stealing:

- **"Convex section only."** It writes a *bounded region* of a shared file it does
  not own. `AGENTS.md` and `CLAUDE.md` belong to the project; the tool claims a
  section and updates only that. This is the only honest way for a dependency to
  contribute to a file the user also edits.
- **Staleness is checked against a remote hash, and fails silent.**
  > Fetches the latest hashes from `version.convex.dev` to report whether each file
  > is up to date. If the network is unavailable the staleness check is skipped
  > silently.
- **`enable`/`disable` are distinct from `install`/`remove`.** Turning it off
  writes `aiFiles.enabled: false` to `convex.json` and leaves the files; removing
  is a different verb. Consent is recorded, not inferred from absence.

This is directly analogous to this repo's generated `words` skill and `onto-sync`.
Convex's addition is the remote hash check and the section-scoped write.

### 2.7 The cost of inference, and the escape hatch

The inference-heavy design has a documented price. From the static-codegen beta
section:

> Convex's code generation heavily relies on TypeScript's type inference. This
> makes updates snappy and jump-to-definition work for the `api` and `internal`
> objects, but it often slows down with large codebases.

The opt-out, in `convex.json`:

```json
{
  "$schema": "./node_modules/convex/schemas/convex.schema.json",
  "codegen": {
    "staticApi": true,
    "staticDataModel": true
  }
}
```

> This will greatly improve autocomplete and incremental typechecking performance,
> but it does have some tradeoffs:
>
> - These types only update when `convex dev` is running.
> - Jump-to-definition no longer works. To find `api.example.f`, you'll need to
>   manually open `convex/example.ts` and find `f`.
> - Functions no longer have return type inference and will default to `v.any()`
>   if they don't have a returns validator.
> - TypeScript enums no longer work in schema or API definitions.

That is the whole tradeoff, honestly stated: **inferred types are small, live and
navigable but slow; materialised types are fast but stale, un-navigable, and lose
information you must then declare manually.** There is a separate
"Typecheck Performance" page whose other advice is `npm install --save-dev
typescript@^7` and, as an explicit last resort, `--typecheck=disable` ("In
general, we do not recommend disabling typechecking").

---

## 3. The function model — query / mutation / action

This is the closest analogue to a formula/job split, so it gets the most detail.

### 3.1 The three kinds

| | reads DB | writes DB | network | deterministic | retried by system | cached | subscribable |
|---|---|---|---|---|---|---|---|
| `query` | yes | no | no | **enforced** | yes | yes | yes |
| `mutation` | yes | yes | no | **enforced** | yes (OCC) | no | no |
| `action` | via `runQuery` | via `runMutation` | yes | no | **never** | no | no |

Plus `internalQuery` / `internalMutation` / `internalAction`, which are the same
things minus client reachability, and `httpAction`.

### 3.2 How a function is declared

Declaration is an *export of a wrapped object*, and the name is positional:

```ts
// convex/myFunctions.ts
import { query } from "./_generated/server";
import { v } from "convex/values";

// Return the last 100 tasks in a given task list.
export const getTaskList = query({
  args: { taskListId: v.id("taskLists") },
  handler: async (ctx, args) => {
    const tasks = await ctx.db
      .query("tasks")
      .withIndex("by_task_list_id", (q) => q.eq("taskListId", args.taskListId))
      .order("desc")
      .take(100);
    return tasks;
  },
});
```

Naming rules, verbatim:

> * `api.myFunctions.myQuery` is `"myFunctions:myQuery"`
> * `api.foo.myQueries.myQuery` is `"foo/myQueries:myQuery"`.
> * `api.myFunction.default` is `"myFunction:default"` or `"myFunction"`.

So there is a **canonical string name** underneath the typed object, and non-TS
clients use the string. The typed `api` object is sugar over a stable string
namespace — which is why the CLI can take `npx convex run messages:send '{...}'`
and why other-language clients exist at all.

Three separable things in the declaration:

1. **the kind** (`query` vs `mutation` vs `action`) — chooses the capability set,
2. **`args`** — a validator object, checked before the handler runs,
3. **`handler`** — the body, receiving `(ctx, args)`.

`ctx` is the *only* way to reach anything outside pure computation. There is no
ambient `db`. The capability set is literally the shape of `ctx`:

```
QueryCtx    = { db: DatabaseReader, auth, storage: StorageReader }
MutationCtx = { db: DatabaseWriter, auth, storage: StorageWriter, scheduler }
ActionCtx   = { runQuery, runMutation, runAction, auth, scheduler,
                storage: StorageActionWriter, vectorSearch }
```

**Capability is conveyed by the object you are handed, not by a permission check
inside the callee.** A query cannot write because `QueryCtx.db` has no `insert`.
That is a type-level fact in TS and a runtime fact in the isolate.

### 3.3 How determinism is actually enforced

Not by convention, and not only by types. Three layers:

**Layer 1 — the ctx shape.** As above. No `db.insert` in a query, no `fetch` in
either, because `fetch` in the Convex runtime is documented as "in Actions only".

**Layer 2 — the runtime lies to you, consistently.** This is the interesting part.
Rather than *forbid* `Math.random()` and `Date.now()` — which would make ordinary
code fail to port — Convex reimplements them as deterministic:

> Convex provides a "seeded" strong pseudo-random number generator at
> `Math.random()` so that it can guarantee the determinism of your function. The
> random number generator's seed is an implicit parameter to your function.
> Multiple calls to `Math.random()` in one function call will return different
> random values. However, a call to `Math.random()` stored in a global variable
> will not change between function runs, because during import-time, the random
> number generator's seed is fixed to a value set at the most recent deployment.

> To ensure the logic within your function is reproducible, the system time used
> globally (outside of any function) is "frozen" at deploy time, while the system
> time during Convex function execution is "frozen" when the function begins.
> `Date.now()` will return the same result for the entirety of your function's
> execution.

With the illustrative snippet from the docs:

```ts
const globalRand = Math.random(); // `globalRand` does not change between runs.
const globalNow = Date.now(); // `globalNow` is the time when Convex functions were deployed.

export const updateSomething = mutation({
  args: {},
  handler: () => {
    const now1 = Date.now();      // time when the function execution started
    const rand1 = Math.random();  // new value for each function run
    const now2 = Date.now();      // `now2` === `now1`
    const rand2 = Math.random();  // `rand1` !== `rand2`
  },
});
```

Also: `performance.now()` is frozen inside a *query* but increments inside a
*mutation* (a query must be a pure function of the snapshot; a mutation is allowed
to observe its own progress). `Performance.timeOrigin` is pinned to the deploy
timestamp everywhere.

The framing is explicit — determinism is presented as *the reason retries are
safe*, not as a purity fetish:

> Query and mutation functions are further **restricted by the runtime to be
> deterministic**. This allows Convex to automatically retry them by the system as
> necessary.
>
> You don't have to think all that much about maintaining these properties of
> determinism when you write your Convex functions. Convex will provide helpful
> error messages as you go, so you can't *accidentally* do something forbidden.

**Layer 3 — the bundler and lints.** `"use node"` is a file-level directive that
moves a file to a different runtime, and the *bundler* enforces the partition:

> Files with the `"use node"` directive should not contain any Convex queries or
> mutations since they cannot be run in the Node.js runtime. Additionally, files
> without the `"use node"` directive should not import any files with the `"use
> node"` directive.

with an ESLint rule `@convex-dev/import-wrong-runtime` — "Prevent Convex runtime
files from importing from Node runtime files" — and a dedicated debug flag for
when this goes wrong:

```
npx convex dev --once --debug-node-apis
```

> It uses a slower bundling method to track the train of imports, narrowing down
> which import is responsible for the error.

### 3.4 Why determinism pays for itself: OCC

The payoff is documented in a page called "OCC and Atomicity" and it is the best
short argument for a deterministic function model I have read. Mutations use
optimistic concurrency control with a read set; on conflict, Convex **just re-runs
the function**:

> A naive optimistic concurrency control solution would be to solve this the same
> way that Git does: require the user/application to resolve the conflict and
> determine if it is safe to retry.
>
> In Convex, however, we don't need to do that. We know the transaction is
> deterministic. It didn't charge money to Stripe, it didn't write a permanent
> value out to the filesystem. It had no effect at all other than proposing some
> atomic changes to Convex tables that were not applied.
>
> The determinism means that we can simply re-run the transaction; you never need
> to worry about temporary data races.

> An OCC conflict means we cannot push because our HEAD is out of date, so we need
> to rebase our changes and try again. And determinism is what guarantees there is
> never a "merge conflict", so (unlike with Git) this rebase operation will always
> eventually succeed without developer intervention.

And they claim true serializability, not snapshot isolation:

> The implementation of optimistic concurrency control in Convex instead provides
> true serializability and will yield correct results regardless of what
> transactions are issued concurrently.

**The whole design is: purity buys you free retry, free caching, and free
invalidation. Effects are quarantined into a kind of function that gets none of
those three.**

### 3.5 What happens when determinism can't be maintained

The escape hatch is the *action*, and Convex is unusually explicit that actions
are second-class on purpose:

> actions may have side-effects and therefore can't be automatically retried by
> Convex when errors occur. For example, say your action sends a email. If it
> fails part-way through, Convex has no way of knowing if the email was already
> sent and can't safely retry the action. It is responsibility of the caller to
> handle errors raised by actions and retry if appropriate.

The prescribed pattern (from the Zen and from the actions doc) is that **actions
are never entered from the outside**:

> Don't invoke actions directly from your app. In general, it's an anti-pattern to
> call actions from the browser. Usually, actions are running on some dependent
> record that should be living in a Convex table. So it's best trigger actions by
> invoking a mutation that both *writes* that dependent record and *schedules* the
> subsequent action to run in the background.

> Don't think 'background jobs', think 'workflow'. When actions are involved, it's
> useful to write chains of effects and mutations, such as:
> action code → mutation → more action code → mutation.
> Then apps or other jobs can follow along with queries.

> Record progress one step at a time. While actions *could* work with thousands of
> records and call dozens of APIs, it's normally best to do smaller batches of work
> and/or to perform individual transformations with outside services. Then record
> your progress with a mutation, of course. Using this pattern makes it easy to
> debug issues, resume partial jobs, and report incremental progress in your app's
> UI.

Note what this buys: because progress is recorded by mutations, **the progress of
an effectful job is itself observable through the reactive query system.** The
job's status bar is free.

The documented action anti-patterns are also instructive:

```ts
// ❌ Avoid this
const foo = await ctx.runQuery(...)
const bar = await ctx.runQuery(...)

// ✅ Do this instead
const fooAndBar = await ctx.runQuery(...)
```

because separate calls "execute in different transactions and aren't guaranteed to
be consistent with each other" — an action's reads are *not* a snapshot, and they
say so. Plus:

> Make sure to await all promises created within an action. Async tasks still
> running when the function returns might or might not complete.

### 3.6 Arg validation, and the lint that makes it non-optional

`args` validators run before the handler. `returns` validators exist too. The
ESLint plugin (`@convex-dev/eslint-plugin`) turns the good habits into build
failures — the recommended set:

| Rule | Recommended | Auto-fixable |
|---|---|---|
| `no-old-registered-function-syntax` — prefer object syntax for registered functions | ✅ | 🔧 |
| `require-argument-validators` | ✅ | 🔧 |
| `explicit-table-ids` — require explicit table names in database operations | ✅ | 🔧 |
| `no-filter-in-query` — warn on `.filter()` in database queries (inefficient) | ✅ | |
| `no-top-of-hour-crons` | ✅ | |
| `import-wrong-runtime` | | |
| `no-collect-in-query` — prefer `.take()`/`.paginate()` over `.collect()` | | |

Two of these are pure DX signals rather than correctness: `no-filter-in-query`
pushes you to indexes, and `no-collect-in-query` pushes you off unbounded reads.
`no-top-of-hour-crons` exists because everyone writes `0 * * * *` and thunders the
backend. And note the *reason* given for `require-argument-validators` — not
safety, but that "using argument validators enables generating more descriptive
function specs and therefore OpenAPI bindings." The validator is the interface
description; the type is a byproduct.

### 3.7 Components — how user-space extends the database

Worth understanding because it is Convex's answer to "do we have to ship this
feature ourselves?", and because the migrations runner (§5.5), the OCC workarounds
(Workpool, Sharded Counter, Action Cache) and the agent framework are all
delivered this way rather than as platform features.

Installation is three steps and one generated object:

```ts
// convex/convex.config.ts
import { defineApp } from "convex/server";
import agent from "@convex-dev/agent/convex.config.js";

const app = defineApp();
app.use(agent);
app.use(agent, { name: "agent2" });   // second instance, its own tables
export default app;
```

```
npm i @convex-dev/agent
npx convex dev                         # generates `components` in _generated/api
```

```ts
import { components } from "./_generated/api";
const agent = new Agent(components.agent, { ... });
```

The guarantees are the interesting part, and they are exactly the ones a
capability-scoped extension system needs:

> * code inside a component **can't read data that is not explicitly provided to
>   it**. This includes database tables, file storage, environment variables,
>   scheduled functions, etc. Conversely, the component's data cannot be directly
>   mutated by the main app …
> * functions in components are run in an isolated environment, so writes to global
>   variables and patches to system behavior are not shared between components.
> * data changes commit transactionally across calls to components … **You'll never
>   have a component commit data but have the calling code roll back.**
> * each mutation call to a component is a **sub-transaction isolated from other
>   calls**, allowing you to safely catch errors thrown by components.
> * Runtime validation ensures all data that cross a component boundary are
>   validated: both arguments and return values.

Three things generalise:

- **Isolation is by absence, not by policy** — the same doctrine as the function
  runtime (§3.3) and as Lazy River's `Lua` host ("the host builds the world out of
  what it binds"). Applied one level up, to a whole installed module.
- **A sub-transaction boundary makes third-party code catchable.** A thrown error
  rolls back the component's writes and nothing else. That is what makes it safe to
  install code you did not write into your transaction.
- **The component's data is its own, and the app cannot reach it.** Encapsulation
  is enforced at the storage layer, not by convention about table names.

Also note what a component *is*: an npm package containing functions and a schema —
i.e. **the same artefact a user writes**, installed under a name. There is no
special plugin API. In Lazy River terms, a component is a bundle of formulas and
jobs plus its own ledger, installed under a name that scopes what it may open.

**The cost, in Convex's own words** (§9.7) — and this is the thing to design around
rather than copy:

> when you call across a component boundary currently **we spin up an entirely
> separate V8 isolate**, like an entirely separate kind of runtime, bootstrap it
> with your modules and run it in there before returning to the caller… where this
> doesn't work great is if you want to call a thousand components in a single
> function.

Isolation was implemented as *a fresh runtime per call*, which is why the
`better-auth` integration is slow (*"it's big… the bundle is pretty large"*). A
BEAM host gets the same isolation from process boundaries at a fraction of the
cost — the guest is already ordinary BEAM code with a deadline and a heap limit.
**The idea transfers; the implementation is a warning.**

---

## 4. Reactivity and caching

### 4.1 The three properties, stated as a bargain

> 1. **Caching**: Convex caches query results automatically. If many clients
>    request the same query, with the same arguments, they will receive a cached
>    response.
> 2. **Reactivity**: clients can subscribe to queries to receive new results when
>    the underlying data changes.
> 3. **Consistency**: All database reads inside a single query call are performed
>    at the same logical timestamp. Concurrent writes do not affect the query
>    results.
>
> To have these attributes the handler function must be *deterministic* …

The cache key is **(function identity, arguments)**. Nothing else. This is why
argument shape is a performance decision.

### 4.2 The mechanism (from "How Convex Works", stack.convex.dev)

- Every query execution records a **read set** — "The read set precisely records
  all of the data that a transaction queried." Not documents: *index ranges*
  (which is why the transaction limit is "Index ranges read: 4,096 — the number of
  calls to `db.get` and `db.query`").
- After returning initial results, the sync worker registers the read set with a
  **subscription manager**.
- On commit, the system "walks the log after the query's begin timestamp and sees
  if any entry overlaps" the read set — and crucially, this is "the exact same
  algorithm the committer uses for detecting serializability conflicts." One
  overlap test serves both OCC conflict detection and subscription invalidation.
- The subscription manager holds "all read sets for all active subscriptions" so
  the transaction log is walked **once per commit**, not once per subscriber.
- Multiversioned indexes let queries run "at multiple versions for timestamps in
  the recent past", and all queries in a client session execute "at the same
  timestamp."

**Invalidation is not a separate feature; it is the conflict detector run
backwards.** If you already have to compute "did this commit invalidate that
read set" to be serializable, subscriptions are nearly free.

### 4.3 What a subscription looks like to the developer

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function App() {
  const data = useQuery(api.functions.myQuery, { a, b });
  return data ?? "Loading...";
}
```

That is the entire subscription API. Semantics:

> The first time the hook is used it creates a subscription to your backend for a
> given query and any arguments you pass in. When your component unmounts, the
> subscription is canceled.

> The `useQuery` hook returns `undefined` while the data is first loading and
> afterwards the return value of your query.

> Convex React ensures that your application always renders a consistent view of
> the query results based on a single state of the underlying database. Imagine a
> mutation changes some data in the database, and that 2 different `useQuery` call
> sites rely on this data. Your app will never render in an inconsistent state
> where only one of the `useQuery` call sites reflects the new data.

Three DX details worth stealing:

- **Loading is `undefined`, not a status object.** `data ?? "Loading..."` is the
  whole loading state. (They have since added an experimental
  `useQuery_experimental` returning `{status: "pending"|"success"|"error", data,
  error}` with the status check enforced by the type — an admission that the terse
  form makes error handling easy to skip.)
- **`"skip"` as an argument value** solves conditional subscriptions inside a
  language that forbids conditional hooks:
  ```tsx
  const data = useQuery(api.functions.read, param !== null ? { param } : "skip");
  ```
  "When `"skip"` is used the `useQuery` doesn't talk to your backend at all and
  returns `undefined`." A sentinel in the argument position, rather than a second
  hook.
- **Consistency is cross-subscription**, i.e. the client applies a whole timestamp
  advance atomically across every live query. That is the thing you cannot bolt on
  later.

### 4.4 What the developer must still think about

- **Errors in queries are thrown at the `useQuery` call site** and are meant to be
  caught by a React error boundary. And explicitly no retry:
  > Unlike other frameworks, there is no concept of "retrying" if your query
  > function hits an error. Because Convex functions are deterministic, if the
  > query function hits an error, retrying will always produce the same error.
  > There is no point in running the query function with the same arguments again.

  Determinism used a third way: as an argument about *client* behaviour.
- **Over-reading is over-subscribing.** The read set is the subscription, so
  `.collect()` on a big table subscribes you to the whole table and re-runs on
  every insert. This is the root of both the OCC-conflict complaints and the
  function-call billing complaints (§9).
- **Optimistic updates are manual** (`OptimisticLocalStore`), and a failed
  mutation rolls them back automatically.
- Mutation errors are *not* caught by error boundaries ("the error doesn't happen
  as part of rendering your components") and must be `.catch`ed.

### 4.5 The costed advice

From the Zen, the operative performance rule:

> In general, your mutations and queries should be working with less than a few
> hundred records and should aim to finish in less than 100ms. It's nearly
> impossible to maintain a snappy, responsive app if your synchronous transactions
> involve a lot more work than this.

and backed by hard limits per transaction:

| | |
|---|---|
| Data read | 16 MiB |
| Data written | 16 MiB |
| Documents scanned | 32,000 |
| Index ranges read | 4,096 |
| Documents written | 16,000 |
| Query/mutation execution time | 1 second (user code only) |
| Function return value size | 16 MiB |

> Documents are "scanned" by the database to figure out which documents should be
> returned from `db.query`. So for example `db.query("table").take(5).collect()`
> will only need to scan 5 documents, but `db.query("table").filter(...).first()`
> might scan up to as many documents as there are in `"table"` …

> If your functions are close to hitting these limits they will log a warning.

**A warning before the wall** is the right shape, and rarer than it should be.

One documented leak in the "determinism is transparent" claim, from Best Practices,
and directly relevant to any snapshot-function model:

> **Don't use `Date.now()` in queries.** Queries don't re-run when `Date.now()`
> changes, potentially returning stale results. Additionally, using `Date.now()` in
> a query can cause the Convex query cache to be invalidated more frequently than
> necessary.

Time is *legal* in a query and *frozen* per execution — but it is not in the read
set, so nothing ever invalidates on its passing. The recommended fix is to
"denormalize a boolean flag updated by scheduled functions, or pass time as an
explicit argument from the client." i.e. **if you want a fact to be reactive, it
has to be in the database.** Making the runtime deterministic does not by itself
make the *dependency graph* honest.

---

## 5. Schema and migrations

### 5.1 One file, declarative, no history

The entire schema is `convex/schema.ts`. **There is no migrations directory, no
version numbers, no ordered files, no `up`/`down`.**

```ts
// convex/schema.ts
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  messages: defineTable({
    body: v.string(),
    user: v.id("users"),
  }),
  users: defineTable({
    name: v.string(),
    tokenIdentifier: v.string(),
  }).index("by_token", ["tokenIdentifier"]),
});
```

`_id` and `_creationTime` are added to every table and must not be declared.
Indexes are declared inline on the table, not separately.

Type primitives: `v.id(table)`, `v.null()`, `v.int64()`, `v.number()`,
`v.boolean()`, `v.string()`, `v.bytes()`, `v.commitTs()`, `v.array()`,
`v.object()`, `v.record()`, plus `v.optional()`, `v.union()`, `v.literal()`,
`v.any()`. **There is no date type** — epoch millis or ISO strings. Documents
support top-level *tagged unions*, so a table can hold several document shapes.

Two knobs:

```ts
defineSchema({ /* ... */ }, {
  schemaValidation: false,      // default true — turns off ALL validation
  strictTableNameTypes: false,  // default true — lets TS touch undeclared tables
});
```

Note that `schemaValidation: false` also disables index-reference checking. The
backend comment is candid: *"If there's no schema, hope the user knows what
they're doing and let them use the field."*

### 5.2 Enforcement happens at two moments, via a state machine

The backend stores schemas as documents with a state
(`crates/common/src/bootstrap_model/schema_state.rs`):

```
Pending → Validated → Active
             ↘ Failed { error }
             ↘ Overwritten
```

Only one schema may be in each of `Pending`, `Validated`, `Active` at a time.

**Push time — a full-table validation pass.** From the docs:

> The first push after a schema is added or modified will validate that all
> existing documents match the schema. If there are documents that fail validation,
> the push will fail. After the schema is pushed, Convex will validate that all
> future document inserts and updates match the schema.

The CLI drives it as a poll loop against `/api/deploy2/wait_for_schema` and
renders live progress:

```
⠋ Backfilling indexes (3/7 ready) and checking that documents match your schema...
⠋ Backfilling indexes (5/7 ready)...
⠋ Checking that documents match your schema...
⠋ Schema validation complete.
```

After ten seconds it appends a link, and names the specific index:

```
Backfilling index by_channel (12000/48000 ready), see progress here: <dashboard>/data?showSchema=true
```

**A long-running push is a progress bar, not a hang.** This is the single most
copyable operational decision in the deploy path.

Failure prints two lines — a summary and the raw backend error:

```
✖ Schema validation failed.
Document with ID "j57abc..." in table "messages" does not match the schema:
Object is missing the required field `author`. Consider wrapping the field
validator in `v.optional(...)` if this is expected.
Object: {body: "hi", _id: "j57abc...", _creationTime: 1734...}
Validator: v.object({author: v.string(), body: v.string()})
```

The error enum (`crates/common/src/schemas/mod.rs`) is worth reading as a
taxonomy — note that each variant names the *thing* and, where possible, the *fix*:

```
"Document with ID \"{id}\" in table \"{table_name}\" does not match the schema: {validation_error}"
"New document in table \"{table_name}\" does not match the schema: {validation_error}"
"Failed to delete table \"{table_name}\" because it appears in the schema"
"Failed to delete table \"{table_name}\" because `v.id(\"{table_name}\")` appears in the schema of table \"{table_in_schema}\""
```

and the inner validation errors:

```
"Object is missing the required field `{field_name}`. Consider wrapping the field
 validator in `v.optional(...)` if this is expected."
"Object contains extra field `{field_name}` that is not in the validator."
"`{value}` does not match literal validator `v.literal({literal_validator})`."
"Found ID \"{id}\" from table `{found_table_name}`, which does not match the table
 name in validator `v.id(\"{validator_table}\")`."
```

There is a `NewDocument` variant specifically for a document written
*concurrently during the validation pass* that violates the new schema — the push
fails on it too. (Their TODO admits they can't yet surface that document's ID.)

There is also a `raceDetected` outcome, printed as `Schema was overwritten by
another push.` — two developers pushing to the same deployment is a named,
handled case rather than a corrupt state.

Crucially, the CLI classifies a schema failure as
`errorType: {"invalid filesystem or db data": {tableName, componentPath}}` with
this comment:

```ts
// Schema validation failed. This could be either because the data
// is bad or the schema is wrong. Classify this as a filesystem error
// because adjusting `schema.ts` is the most normal next step.
```

which is what feeds the table-watch retry loop from §1.5. **The error names the
table; the dev loop then subscribes to that table; fixing the data in the
dashboard retries the push with no keystroke.**

**Write time** is a separate error type with separate wording, surfaced as a
`bad_request` with code `SchemaEnforcementError`:

```
"Failed to insert or update a document in table \"{table_name}\" because it does
 not match the schema: {validation_error}"
```

### 5.3 Breaking changes: refusal *is* the migration engine

There is no diff step, no plan, no migration statement. You edit `schema.ts` into
the shape you want and Convex compares the declared shape to the data at rest.
From the Stack post:

> With Convex, you don't have to write migration code like "add column" or "add
> index" explicitly. All you need to do is update your `schema.ts` file and Convex
> handles it. … However, it will enforce the schema you define, and **will not let
> you deploy a schema that doesn't match the data at rest**.

The documented safe-change list:

> 1. Add new tables to the schema.
> 2. Add an `optional` field to an existing table's schema, set the field on all
>    documents in the table, and then make the field required.
> 3. Mark an existing field as `optional`, remove the field from all documents, and
>    then remove the field.
> 4. Mark an existing field as a `union` of the existing type and a new type,
>    modify the field on all documents to match the new type, and then change the
>    type to the new type.

Every breaking change is therefore the same **three-push dance: widen → backfill →
narrow.**

| Goal | 1. widen (push) | 2. backfill (run) | 3. narrow (push) |
|---|---|---|---|
| Add required field | `v.optional(v.string())` | set on every doc | `v.string()` |
| Remove field | `v.optional(v.string())` | `patch(id, {f: undefined})` | delete the line |
| Change type | `v.union(v.number(), v.string())` | rewrite every value | `v.string()` |

And the same discipline is extended, unenforced, to *functions* — because old
clients are still in browsers, and because scheduled work outlives the deploy:

> **Scheduled functions should be backwards compatible.** … Whenever a function
> runs, it always runs its currently deployed version. If you change the function
> between the time it was scheduled and the time it runs, you must ensure the new
> version will behave acceptably given the old arguments.

Doctrine from the migrations post: create new fields rather than changing types;
don't delete data; and

> When possible, push changes to the schema separately from changes to the code. By
> pushing a change to allow an optional new field in the schema before adding code
> to write or rely on the new field, you will be able to roll back or revert the new
> code in case of a bug.

Dual-write is preferred over dual-read explicitly because *"this approach makes it
hard to roll back."*

### 5.4 Indexes get a barrier, and deletion gets a confirmation

> You may notice that the first deploy that defines an index is a bit slower than
> normal. This is because Convex needs to *backfill* your index. … You can feel free
> to query an index in the same deploy that defines it. **Convex will ensure that
> the index is backfilled before the new query and mutation functions are
> registered.**

That ordering invariant — *backfill is a barrier before function registration* —
eats the "two deploys instead of one" tax that online schema migration usually
imposes. Since 1.26.0 (2025-08-22) you can opt out with staged indexes:

```ts
.index("by_channel", { fields: ["channel"], staged: true })
```

Deletion is implicit and dangerous, so it gets an interactive gate:

```
⚠️  This code push will delete the following indexes
from your production deployment (https://…convex.cloud):

  messages.by_channel  ["channel"]

The documents that are in the index won’t be deleted, but the index will need
to be backfilled again if you want to restore it later.

? Delete these indexes? (y/N)
```

Default **No**. Non-interactive gets the repair spelled out:

```
To confirm the push:
• run the deploy command in an interactive terminal
• or run the deploy command with the --allow-deleting-large-indexes flag
```

Happy path prints `✔ No large indexes are deleted by this push`. **Note that the
check only fires for large indexes** — the cost of the confirmation is scaled to
the cost of the mistake.

### 5.5 There is no migration system, and that is the design

The escalation ladder, in the order the docs present it:

1. **Dashboard bulk edit.** Select documents, supply a patch object
   (`{newField: 123, fieldToRemove: undefined}`). One transaction, so **under 8,192
   documents**. Recommended for dev only.
2. **One mutation over the whole table.** Fine to "a few thousand rows".
3. **Hand-rolled paginated batches**, self-scheduling:
   ```ts
   export const myMigrationBatch = internalMutation({
     args: { cursor: v.union(v.string(), v.null()), numItems: v.number() },
     handler: async (ctx, args) => {
       const { page, isDone, continueCursor } = await ctx.db.query("mytable").paginate(args);
       for (const doc of page) { /* modify */ }
       if (!isDone) await ctx.scheduler.runAfter(0, internal.example.myMigrationBatch, {
         cursor: continueCursor, numItems: args.numItems });
     },
   });
   ```
   Test one batch with `npx convex run mutations:myMigrationBatch '{ "cursor": null, "numItems": 1 }'`.
   The advice on parallelism is refreshingly conservative: *"I'd urge you to start
   doing it serially, and only add parallelization gradually if it's actually too
   slow."*
4. **`@convex-dev/migrations`** — a first-party *component*, i.e. user-space code
   installed into your app, not a platform feature.

The component's semantics are the interesting part, because they are what a
migration runner actually needs:

- refuses to start a duplicate worker if already running;
- **resumes from the failed batch** rather than restarting, unless you pass
  `reset: true` or an explicit `cursor`;
- `dryRun: true` runs one batch **and then throws**, so nothing commits but you see
  what it would have done;
- batch size defaults to 100, overridable per-migration and per-invocation;
- `parallelize` is off by default because of read-modify-write hazards;
- series support: completed migrations skipped, partial progress resumed, a
  failure stops the series;
- **status is a reactive Convex query**, so migration progress is a live
  subscription rather than log-scraping:
  ```sh
  npx convex run --component migrations lib:getStatus --watch
  npx convex run --component migrations lib:cancel '{name: "migrations:myMigration"}'
  ```

And there is no dedicated CLI verb — you invoke a migration with `npx convex run`,
the same command you use for any other function. **A migration is just a function
you happened to write.**

---

## 6. Deploy and publish

### 6.1 `npx convex deploy`

```
The target deployment is chosen like this:
• If the `CONVEX_DEPLOYMENT` environment variable is set (typical during local
  development), the target is the project’s default production deployment.
• If the `CONVEX_DEPLOY_KEY` environment variable is set (typical in CI), it is the
  deployment associated with that key.
  • When it’s set to a preview deploy key, it will deploy to a preview deployment:
    • with the name of the current Git branch when running in CI (Vercel, Netlify,
      Cloudflare Pages, GitHub)
    • or with the name specified by the `--preview-name` or `--preview-create` flags

`npx convex deploy` will:
  1. Run a command if specified with `--cmd`, with the deployment URL available as
     an environment variable.
  2. Typecheck your Convex functions.
  3. Regenerate the generated code in the `convex/_generated` directory.
  4. Bundle your Convex functions and their dependencies.
  5. Push your functions, indexes, and schema to the deployment.
  6. When deploying to a preview deployment, it runs the function specified by
     `--preview-run`.
If any step fails, the next steps do not run.
```

Typical output:

```
✔ Ran "npm run build" with environment variables "VITE_CONVEX_URL" and "VITE_CONVEX_SITE_URL" set
⠋ Deploying to https://joyful-capybara-123.convex.cloud...
⠋ Pushing code to your Convex deployment...
⠋ Backfilling indexes (3/7 ready) and checking that documents match your schema...
⠋ Schema validation complete.
⠋ Finalizing push...
✔ Deployed Convex functions to https://joyful-capybara-123.convex.cloud
```

`--dry-run` swaps every verb to the conditional: `Would have deployed Convex
functions to …`, `Would have run "…"`. Small thing, correct thing.

### 6.2 The dev→prod interlock

If you run `deploy` from a machine that has a *dev* deployment configured, it
targets prod and asks first, showing exactly what will change and what the client
must be pointed at:

```
You're currently developing against your dev deployment

  <configured-name> (set in CONVEX_DEPLOYMENT)

Your prod deployment <requested-name> serves traffic at:

  VITE_CONVEX_URL=https://<name>.convex.cloud

Make sure that your published client is configured with this URL (for instructions
see https://docs.convex.dev/hosting)

? Do you want to push your code to your prod deployment <requested-name> now? (Y/n)
```

Plus a separate CI-misconfiguration guard:

```
Detected a non-production build environment and "CONVEX_DEPLOY_KEY" for a
production Convex deployment.
This is probably unintentional.
```

triggered by `VERCEL_ENV !== "production"` and equivalents. And deployment targets
are colour-coded in the banner: production purple, dev/local green, preview orange.

### 6.3 The deploy key's *type* is the routing decision

```
production: prod:qualified-jaguar-123|eyJ2...0=
preview:    preview:team-slug:project-slug|eyJ2...0=
dev:        dev:joyful-jaguar-123|eyJ2...0=
project:    project:team-slug:project-slug|eyJ2...0=
admin:      bold-hyena-681|01c2...c09c
```

CI config is therefore **one command and one environment variable**, and the same
command means "deploy to prod" or "create a preview named after this branch"
depending only on the key. Vercel setup in full:

1. Build Command → `npx convex deploy --cmd 'npm run build'`
2. `CONVEX_DEPLOY_KEY` = a Production key, scoped to the Production environment
3. `CONVEX_DEPLOY_KEY` = a Preview key, scoped to the Preview environment

There is no YAML. The only GitHub Actions file in the docs is for *tests*.

### 6.4 `--cmd` and the URL chicken-and-egg

The frontend build must bake in the backend URL, but for a preview deployment that
URL doesn't exist until the deploy creates it. So `convex deploy` **owns the
build**, rather than the reverse: it resolves or creates the deployment, fetches
its canonical URLs, injects them, then shells out.

```ts
const { convexCloudUrl, convexSiteUrl } = await fetchDeploymentCanonicalUrls(ctx, deployment);
const env = { ...process.env };
env[urlVar]  = canonicalCloudUrl;
env[siteVar] = canonicalSiteUrl;
const result = spawnSync(options.cmd, { env, stdio: "inherit", shell: true });
if (result.status !== 0) { crash(`'${options.cmd}' failed`); }
```

The variable *name* is inferred from the framework, so the developer never writes
it down:

| Framework | URL var |
|---|---|
| Next.js | `NEXT_PUBLIC_CONVEX_URL` |
| Vite / TanStack Start | `VITE_CONVEX_URL` |
| Create React App | `REACT_APP_CONVEX_URL` |
| Expo | `EXPO_PUBLIC_CONVEX_URL` |
| SvelteKit | `PUBLIC_CONVEX_URL` |
| plain Node | `CONVEX_URL` |

If the frontend build fails, the backend push never happens.

### 6.5 Preview deployments

Still beta. Created by `deploy` when the key is a preview key; named after the git
branch (inferred on Vercel, Netlify, Cloudflare Pages, GitHub, GitLab);
`--preview-name` reuses the deployment *and its data*, `--preview-create` destroys
and recreates. Reuse-by-default is recent — **convex 1.35.0, 2026-04-10**:

> When deploying to a preview deployment, you can now reuse the existing deployment
> instead of creating a new one by using `--preview-name` instead of
> `--preview-create`. This behavior is also used when deploying to preview
> deployments from the CI without specifying `--preview-create` explicitly.

Expiry: **5 days** on Free/Starter, **14 days** on Pro and above. Seeding is
`--preview-run <functionName>`, run **only when a new preview deployment is
created**, with an honest caveat:

> Note that if the function call fails, the `deploy` command will fail, but the new
> preview deployment will have already been provisioned.

New deployments inherit **project environment variable defaults**, which is what
makes throwaway environments actually work.

### 6.6 Environment variables: two separate systems

**Deployment env vars live in the deployment**, never in a dotfile, never in git:

```sh
npx convex env list
npx convex env get NAME
npx convex env set NAME 'value'
npx convex env set NAME                    # interactive — keeps it out of shell history
npx convex env set NAME --from-file value.txt
npx convex env set --from-file .env.convex
npx convex env remove NAME
npx convex env default                     # project-level defaults
```

with the round-trip idiom:

```sh
npx convex env list > .env.convex     # edit locally
npx convex env set --force < .env.convex
```

`--from-file` **without** `--force` refuses all changes if any variable already has
a different value — no silent clobber. `pbpaste | npx convex env set API_KEY` is
documented specifically to keep secrets out of shell history.

They are per-deployment by design, with the consequence stated plainly: *"If you
expect an environment variable to be always present in a function, you must add it
to **all** your deployments."* **Project defaults** patch that hole — applied at
deployment creation, *not* kept in sync afterward, with drift flagged in the
dashboard.

Newer: **declared** env vars, validated at deploy time, in `convex/convex.config.ts`:

```ts
const app = defineApp({
  env: {
    GIPHY_KEY: v.string(),
    LOG_LEVEL: v.optional(v.union(v.literal("debug"), v.literal("info"), v.literal("error"))),
  },
});
```

which generates a typed `env` object on the generated server module and, more
importantly, *"helps prevent removing required environment variables or setting
them to invalid values from the dashboard or `npx convex env [remove|set]`."*
**Declaring what is expected is separated from setting the values** — the schema
idea applied to configuration.

The hard rule, stated with a wrong example:

```ts
// THIS WILL NOT WORK!
export const myFunc = process.env.DEBUG ? mutation(...) : internalMutation(...);
```

> The set of Convex functions that can be called is determined during deployment and
> is not reevaluated when you change an environment variable.

### 6.7 Team / project / deployment, and the "everyone gets one" rule

**Team → Project → Deployment.** A project has one shared production deployment
and **one development deployment per team member**, provisioned automatically on
that member's first `npx convex dev`. Onboarding a teammate is: clone, `npx convex
dev`. There is no shared dev database to coordinate over.

| | Dev | Preview | Production |
|---|---|---|---|
| Reference | `dev/[creator]` | `preview/[branch]` | `production` |
| Expiration | — | 5 d / 14 d | — |
| Dashboard permissions | any team member | any team member | admins only |
| Server logs → clients | **yes** | yes | **no** |
| Server error detail → clients | **yes** | yes | **no** (unless `ConvexError`) |
| Dashboard edit confirmation | none | none | confirms first |

**Staging is not a first-class concept**; the documented answer is "use a separate
Convex project." Since **convex 1.34.0 (2026-03-19)** you can create arbitrary
extra deployments:

```sh
npx convex deployment create dev/james/feature-payment-integration \
  --type=dev --region us --expiration "in 7 days" --select
npx convex deployment select my-team:my-project:dev/james/feature-payment-integration
npx convex env list --deployment dev/james/feature-payment-integration
npx convex deployment token create agent-token --save-env
```

### 6.8 Rollback: there isn't one

Searching the full docs corpus for "rollback"/"revert" returns only *transaction*
rollback, optimistic-update rollback, and component sub-transaction rollback.
**There is no `convex rollback`, no deployment version list to re-point at, no
`--rollback` flag.** The dashboard History page is an audit log (Professional
only), read-only.

The documented emergency procedure is manual:

> * Take an additional backup prior to restore, since restores are destructive
> * Do a restore from a good backup — to restore data
> * Use `npx convex dev` to push a known version of good code.
> * Use `npx convex env` or the dashboard to restore to a good set of env vars
> * Use the dashboard to make any manual fixes to the database for your app.
> * Write mutations to make required (more programmatic) manual fixes …

So rollback = `git checkout` the old commit and deploy again, plus a destructive
restore if data was corrupted. And the structural sting: **because the schema must
match the data at rest, rolling back across a narrowing schema change is
impossible.** Which is precisely why the migration doctrine is so insistent on
additive-only steps and on pushing schema changes separately from code changes.
Convex has no rollback mechanism, so it pushes the burden onto a discipline that
keeps every intermediate state mutually compatible.

What does exist: backups (manual, plus periodic on Pro; retained 7/14 days;
restore is destructive; **contains documents and files but not code, config, env
vars, or pending scheduled functions**), and export/import:

```sh
npx convex export --path ~/Downloads --include-file-storage
# → snapshot_{unix_nanos}.zip
#     messages/documents.jsonl        one JSON document per line
#     _storage/documents.jsonl
#     _storage/<id>
#     generated_schema.jsonl          preserves Int64/Bytes typing
npx convex import --prod --replace backup.zip
```

Import is **atomic** — *"creates and replaces tables atomically"*, *"Queries and
mutations will not view intermediate states"*, and *"Indexes and schemas will work
on the new data without needing time for re-backfilling or re-validating"* — and
is the only way to write documents with pre-existing `_id`/`_creationTime`.

---

## 7. Errors, logs, and observability

### 7.1 The four reasons a function fails

The taxonomy is stated up front, and it is a *causal* taxonomy — who has to act —
not a severity one:

> 1. **Application Errors**: The function code hits a logical condition that should
>    stop further processing, and your code throws a `ConvexError`
> 2. **Developer Errors**: There is a bug in the function (like calling
>    `db.get("documents", null)` instead of `db.get("documents", id)`).
> 3. **Read/Write Limit Errors**: The function is retrieving or writing too much data.
> 4. **Internal Convex Errors**: There is a problem within Convex (like a network blip).
>
> Convex will automatically handle internal Convex errors. If there are problems on
> our end, we'll automatically retry your queries and mutations until the problem is
> resolved …
>
> On the other hand, you must decide how to handle application, developer and
> read/write limit errors.

**Category 4 is the platform's problem and is invisible; 1–3 are yours.** Drawing
that line explicitly, in the first paragraph of the error documentation, is worth
copying on its own.

### 7.2 `ConvexError` — the only thing that survives the prod boundary

Ordinary `Error`s are **redacted in production**. This is the single most important
error-handling fact in Convex:

> Using a dev deployment any server error thrown on the client will include the
> original error message and a server-side stack trace to ease debugging.
>
> Using a production deployment any server error will be redacted to only include
> the name of the function and a generic `"Server Error"` message, with no stack
> trace. Server application errors will still include their custom `data`.
>
> Both development and production deployments log full errors with stack traces
> which can be found on the Logs page of a given deployment.

So the client sees something shaped like:

```
[CONVEX M(messages:send)] [Request ID: 9f2c4a1b8e7d3f60] Server Error
```

in prod, versus the full message and stack in dev. `ConvexError` is the **declared
channel** through which a developer opts a payload into crossing that boundary:

```ts
import { ConvexError } from "convex/values";
import { mutation } from "./_generated/server";

export const assignRole = mutation({
  args: { /* ... */ },
  handler: (ctx, args) => {
    if (isRoleTaken(/* ... */)) {
      throw new ConvexError("Role is already taken");
    }
  },
});
```

The payload is any Convex value, not just a string — so structured errors are
first-class:

```ts
// error.data === "My fancy error message"
throw new ConvexError("My fancy error message");

// error.data === {message: "…", code: 123, severity: "high"}
throw new ConvexError({ message: "…", code: 123, severity: "high" });
```

and on the client the same class is used, so the discrimination is one `instanceof`:

```ts
catch (error) {
  const errorMessage =
    error instanceof ConvexError
      ? (error.data as { message: string }).message
      : // Must be some developer error, and prod deployments will not
        // reveal any more information about it to the client
        "Unexpected error occurred";
}
```

**Expected failure and unexpected failure are different types, and only the
expected one is allowed out of the building.** Note also that throwing inside a
mutation rolls the transaction back — error propagation and transaction abort are
the same act, which is why "return an error value" and "throw" are genuinely
different choices rather than style. The docs present both, and give the
type-level alternative first:

> a `createUser` mutation could return `Id<"users"> | { error: "EMAIL_ADDRESS_IN_USE" }`
> to express that either the mutation succeeded or the email address was already
> taken. This ensures that you remember to handle these cases in your UI.

### 7.3 The Request ID as the join key

> To find the appropriate logs for an error you or your users experience, Convex
> includes a **Request ID in all exception messages in both dev and prod** in this
> format: `[Request ID: <request_id>]`. You can copy and paste a Request ID into
> your Convex dashboard to view the logs for functions started by that request.

Redaction removes the *content* but preserves the *correlator*. A user can paste
you a support message containing a Request ID that reveals nothing, and you can
recover the full stack trace from it. That is exactly the right split, and it is
cheap.

### 7.4 Logging

`console.log/info/warn/error/debug`, plus `console.trace`, `console.time`,
`console.timeLog`, `console.timeEnd` in the default runtime. Three destinations,
and the first is a genuinely unusual choice:

> 1. When using the `ConvexReactClient`, **in your browser developer tools console
>    pane. The logs are sent from your dev deployment to your client**, and the
>    client logs them to the browser. Production deployments **do not** send logs to
>    the client.
> 2. In your Convex dashboard on the Logs page.
> 3. In your terminal with `npx convex dev` … or `npx convex logs`.

**Server logs appear in the browser console in dev.** For a reactive system where
a re-render is caused by a server-side re-execution, having both halves in one
timeline is a real advantage — and turning it off in prod is the same redaction
boundary as §7.2.

Limits worth knowing, because they bite silently:

| | |
|---|---|
| Length of a `console.log` line | 4 KiB |
| Log lines per function | 256 — *"Additional logs will be dropped."* |
| Log streaming buffer | 4096 logs, flushed every 5 seconds |

And the honest warning about retention:

> Convex backend currently only preserves a limited number of logs, and logs can be
> erased at any time when the Convex team performs internal maintenance and
> upgrades. You should therefore set up log streaming and error reporting
> integrations to enable your team easy access to historical logs …

i.e. **the built-in log view is a debugging aid, not a record.** Saying so is
better than implying durability they don't provide. Log streams go to Axiom,
Datadog, or a webhook; exception reporting goes to Sentry.

### 7.5 Debugging in prod is deliberately limited

> When debugging an issue in production your options are:
> 1. Leverage existing logging
> 2. Add more logging and deploy a new version of your backend to production

There is no production debugger, no breakpoint, no shell into a running isolate.
The documented alternative for actually stepping through code is *tests*:

> You can exercise your functions from tests, in which case you can add `debugger;`
> statements and step through your code.

### 7.6 The dashboard

The dashboard is treated as part of the development loop rather than an admin
console. From the Zen, stated about as strongly as it can be:

> **Keep the dashboard by your side.** Working on your Convex project without using
> the dashboard is like driving a car with your eyes closed. The dashboard lets you
> view logs, give mutations/queries/actions a test run, make sure your configuration
> and codebase are as you expect, inspect your tables, generate schemas, etc.

The pages, and what each is actually for:

- **Data** — a browser over every table, with filters, and **editable**. Editing
  production data prompts for confirmation first; dev does not. It can also
  *generate a schema* from existing data, which inverts the usual order: prototype
  without a schema, then have the tool write the `schema.ts` that matches what you
  ended up with.
- **Functions** — a list of every deployed function with per-function stats, plus a
  **function runner**: pick a function, fill in its arguments (the form is built
  from the `args` validators), run it, see the result and its logs. This is why
  `require-argument-validators` earns its keep — the validator is what makes the
  UI possible.
- **Logs** — a live stream with filters, including by Request ID (§7.3).
- **Health / Insights** — the OCC-conflict and limit reporting, mirrored to the CLI
  as `npx convex insights [--details] [--prod]`:
  > Show health insights for a Convex deployment over the last 72 hours. Reports
  > OCC (Optimistic Concurrency Control) conflicts and resource limit issues that
  > may indicate performance problems.
- **Schedules**, **File Storage**, **Schema**, **History** (an audit log,
  Professional and above), **Settings** (environment variables, deploy keys).

Two structural points:

- **Every dashboard capability has a CLI equivalent** — `npx convex data`,
  `npx convex run`, `npx convex logs`, `npx convex insights`, `npx convex env`.
  One capability, two renderings; the CLI one is what an agent or a script uses.
- **The dashboard works against local deployments too**, which is what keeps the
  offline story honest (modulo Safari and Brave blocking localhost, §1.7).

---

## 8. Testing

### 8.1 Two harnesses, and they are explicitly a tradeoff

Convex ships two ways to test, and documents the choice rather than picking for you:

| | `convex-test` | real backend |
|---|---|---|
| What it is | a **JS mock of the Convex backend**, in-memory | the actual open-source binary |
| Speed | fast, no process | slower, needs a running deployment |
| Fidelity | approximate | exact |
| Runs in | Vitest (edge-runtime environment) | Vitest / anything |

The docs are unusually candid that the fast one is a model, not the thing:

> `convex-test` is a mock implementation of the Convex backend … it does not
> perfectly replicate the behavior of the real backend.

and it publishes the divergences as a list, verbatim:

> * **Error messages content.** You should not write product logic that relies on
>   the content of error messages thrown by the real backend, as they are always
>   subject to change.
> * **Limits.** The mock doesn't enforce size and time limits.
> * **ID format.** Your code should not depend on the document or storage ID format.
> * **Runtime built-ins.** … Vitest uses a mock of Vercel's Edge Runtime, which is
>   similar but might differ from the Convex runtime. **You should always test new
>   code manually to make sure it doesn't use built-ins not available in the Convex
>   runtime.**
> * Some features have only simplified semantics, namely:
>   * Text search returns all documents that include a word for which at least one
>     word in the searched string is a prefix. **It does not sort the results by
>     relevance.**
>   * Vector search returns results sorted by cosine similarity, **but doesn't use an
>     efficient vector index**.
>   * **There is no support for cron jobs**, you should trigger your functions
>     manually from the test.

Read that list against §9. **The mock does not enforce limits, and does not model
the real runtime's built-ins — so the two classes of bug that hurt most in
production (transaction limits, and code that works locally but not in the isolate)
are precisely the two the fast harness cannot catch.** Convex says so directly
("always test new code manually"), which is honest and also an admission that the
fast loop is not sufficient.

Publishing the divergence list at all is the transferable part. A test harness that
is a model of the system should ship a written statement of where the model is
wrong, next to the harness.

### 8.2 The fast harness

```
npm install --save-dev convex-test vitest @edge-runtime/vm
```

```json
// package.json
{
  "scripts": {
    "test": "vitest",
    "test:once": "vitest run",
    "test:debug": "vitest --inspect-brk --no-file-parallelism",
    "test:coverage": "vitest run --coverage --coverage.reporter=text"
  }
}
```

```ts
// vitest.config.ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "edge-runtime",
  },
});
```

(One line of config — `edge-runtime` is what makes the test environment approximate
the Convex isolate. Projects that also test a frontend split environments with
Vitest's `projects` array, or `environmentMatchGlobs` on Vitest 3, so that
`convex/**` runs in `edge-runtime` and the rest in `jsdom`.)

and a test:

```ts
import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "./_generated/api";
import schema from "./schema";

test("sending messages", async () => {
  const t = convexTest(schema);
  await t.mutation(api.messages.send, { body: "Hi!", author: "Sarah" });
  const messages = await t.query(api.messages.list);
  expect(messages).toMatchObject([{ body: "Hi!", author: "Sarah" }]);
});
```

The shape to notice: **the test calls the same `api` object the client does.**
There is no separate test API, no test-only export, no dependency injection. A test
is a client.

Supporting facilities:

- `t.run(async (ctx) => { ... })` — direct `ctx.db` access to set up or assert on
  state without going through a public function.
- `t.withIdentity({ name: "Sarah", subject: "user_123" })` — returns a scoped
  handle so auth paths are testable without a real IdP.
- `t.finishInProgressScheduledFunctions()` / `t.finishAllScheduledFunctions()` plus
  `vi.useFakeTimers()` — **scheduled work is drained explicitly rather than waited
  on**, which is what makes tests of `ctx.scheduler.runAfter` deterministic.
- `vi.stubGlobal("fetch", vi.fn(...))` for actions — the effectful boundary is
  mocked at the one function that constitutes it.

### 8.3 Testing against the real thing

The alternative is to run the open-source backend and point tests at it — this is
what CI does when fidelity matters:

```yaml
- run: |
    curl -L -o convex-local-backend.zip \
      https://github.com/get-convex/convex-backend/releases/latest/download/convex-local-backend-x86_64-unknown-linux-gnu.zip
    unzip convex-local-backend.zip
    ./convex-local-backend &
- run: npx convex dev --once --admin-key <key> --url http://127.0.0.1:3210
- run: npx convex run init          # seed
- run: npm test
```

The generic CI shape they document for a Convex project is otherwise unremarkable
and short:

```yaml
- run: npm ci
- run: npx convex codegen        # then `git diff --exit-code` to catch drift
- run: npm run test:once
- run: npx convex deploy --cmd 'npm run build'   # with CONVEX_DEPLOY_KEY set
```

### 8.4 What is missing

Notably absent from the testing story: **there is no determinism test.** Nothing
ships that runs a query twice and compares, or that detects a formula whose answer
depends on something outside its read set. Determinism is enforced by the runtime
(§3.3) and then assumed. Given that the one documented hole — `Date.now()` in a
query never invalidating (§4.5) — is exactly a determinism-adjacent bug that the
runtime *cannot* catch, this is a real gap rather than an oversight worth copying.

---

## 9. What people complain about

Sources are HN (via the Algolia API), the `get-convex/convex-backend` and
`get-convex/convex-js` issue trackers, first-person blogs, and — unusually
valuable — **Convex's own criticism of itself**: the site `convex.sucks`, the
podcast episode literally titled *"Why Convex Sucks — For Now"* (2025-08-13), and a
follow-up episode recorded 2026-02-25. Where Convex has since fixed something, that
is marked. Reddit was unreachable from this environment.

**A warning about secondary sources.** A large fraction of "Convex review 2026"
pages are AI-generated affiliate content repeating a **factually false** claim —
that Convex has no self-hosting. It has been self-hostable since 2025-02-13.
Specifically discard `makerstack.co/reviews/convex-review/`,
`fromscratch.dev/alternatives/convex`, and `trybuildpilot.com/366-convex-review-2026`.

### 9.1 Lock-in, and an escape hatch that exists but is not load-bearing

The licence is **FSL 1.1 with an Apache 2.0 future licence** — source-available,
each release converting to Apache 2.0 on its second anniversary, with a
competing-use restriction meanwhile:

> A Permitted Purpose is any purpose other than a Competing Use. A Competing Use
> means making the Software available to others in a commercial product or service
> that: 1. substitutes for the Software; 2. substitutes for any other product or
> service we offer using the Software... or 3. offers the same or substantially
> similar functionality as the Software.
> — <https://github.com/get-convex/convex-backend/blob/main/LICENSE.md>

Cofounder James Cowling, HN, 2024-04-14, framing it fairly:

> Convex is FSL licensed which means you can basically do whatever you want with it
> re running a service, other than directly competing with Convex … After 2 years
> the code becomes Apache 2.0. Note that if you're running the open source release
> **you're on the hook for managing and scaling your own reliable infrastructure**.
> — <https://news.ycombinator.com/item?id=40035309>

The licence is not the real limitation. These are:

- **Self-hosted has no horizontal scaling.** Convex engineer `nipunn1313`,
  2026-02-17: *"Self hosted doesn't have horizontal scaling set up (yet). It's best
  for projects that will run on a single node."*
  (<https://github.com/get-convex/convex-backend/issues/360>)
- **The test suites are not open sourced.** From the repo README: *"Convex is a well
  tested piece of software, with several well designed test frameworks including
  randomized testing. Those tests are not provided as part of the open source
  offering."*
- **No versioned releases.** Same issue thread, 2026-02-16: *"as of Sept 2025, they
  aren't updating said changelog anymore and telling users to just look at the `git
  log` … do I just move everything to 'latest' and pray everything is fine?"*
  Convex: *"Would recommend using a pinned SHA for now."*
- **Data export is still a beta feature** (<https://docs.convex.dev/database/import-export/>).
- And Convex says it outright:
  > **We don't consider the self-hosted product to be an acceptable escape hatch for
  > any major product gaps.**
  > — <https://news.convex.dev/self-hosting/>, 2025-02-13

Their own self-roast is the most honest statement of it:

> **I'm going to get locked in and depend on Convex** — Yeah, this could happen.
> This is a tricky one. If you love Convex and build your product on it then you
> depend on it. That's the problem with falling in love. If you wanted to move off
> of hosted Convex then you can run the open source version but **it isn't as
> seamless of an experience as hosted Convex**.
> — <https://www.convex.sucks/>

The canonical migration-away decision, from a 3-person team choosing Supabase
(issue #6, 2024-10-01) — note that the *reasons* are ranked:

> 1. local dev experience 2. **vendor lock-in (convex really seems to be the least
> friendly to move away when the cloud's pricing doesn't work for us, it's okay to
> pay but if there's a risk to end up with a Datadog-like billing, we'd like to
> avoid it)** 3. product maturity 4. database knowledge (it's not clear how convex
> db is designed internally and it'd be risky if our team who already know SQL get
> stuck with convex gotchas)

And the general-purpose version of the objection, joshstrange on HN 2024-08-15:

> It's not even concerns on cost, it's mostly lock-in… I just kept thinking **"I'd
> have to change everything about my web/apps around this."** I'll try new things …
> but only if I feel like I have a fallback to something else if I need it.
> — <https://news.ycombinator.com/item?id=41260776>

**The lesson is not about licensing.** It is that an escape hatch nobody would
execute under duress is not an escape hatch. If Lazy River's answer to "what if I
want out" is "the facts are yours, here they are", that has to be a tested,
versioned, first-class operation — which, given `Backup.restore/verify` already
exists and refuses rather than overwrites, is a real advantage to protect.

### 9.2 Cost, and the fact that reactivity itself is metered

The billing unit is the function call, defined to include the thing that makes the
product what it is:

> **Explicit client calls, scheduled executions, subscription updates, and file
> accesses count as function calls.**
> — <https://docs.convex.dev/production/state/limits>

Compounding it: there is no column projection and no `COUNT`, so you pay for every
byte of every document any query touches. Convex explains why, and the explanation
is honest:

> SELECT would only be cheap if Convex could skip reading the big fields in storage.
> But Convex **stores whole JSON docs, not column chunks** so it still has to read
> the full blob, then throw away what you didn't ask for.
> — <https://stack.convex.dev/why-doesn-t-convex-have-select-or-count>

The canonical cost-shock report (issue #95, 2025-05-19) is worth the numbers:

> I've already hit the **1 GB database bandwidth threshold**… My **database is only
> 5 MB**. My **writes are only 6 MB**. But my **reads are at 900 MB**… With Convex,
> based on my current trajectory, **this could scale to over 600 GB/month**.

> When listing elements with `query` or `paginationQuery`, **any update to a single
> element triggers a full re-send of the entire list**, instead of just the updated
> row.

Part of that was a genuine backend regression in paginated-query caching, **fixed
2025-06-02**. The structural model is unchanged, and the complaint recurred
2025-09-22: *"i have gone through entire docs and optimized queries as much i can
but still same problem."*

An independent measurement, Diwaker Gupta's friction log (2025-09-15) — one action
downloading a ~10MB RSS feed and doing a few hundred updates:

> **Actions can be slow!** … for my action running similar code locally against
> sqlite took a few seconds; **in Convex's dev environment it took hours and I
> actually ran into project limits before it could complete.**
> **I/O usage was surprising!** … my action above ended up consuming **2.85 GB in
> "Database Bandwidth"**.
> — <https://diwaker.io/friction-log-convex/>

Convex's CEO concedes the estimation problem on the record:

> There was another thing you mentioned … and I just want to acknowledge it as a
> real real critique — you said **it's hard to estimate how much Convex will cost.
> Yeah, I think it probably is.**
> — Jamie Turner, *"Why Convex Sucks — For Now"*, <https://www.youtube.com/watch?v=FMhaM3yXYbk>, 2025-08-13

The promised pricing calculator still does not exist.

**And the ceiling moved under existing customers.** Mutation write-throughput
limits were cut twice in one week in 2026 via docs edits:

| Date | S16 (Free/Starter) | S256 (Pro) | Commit |
|---|---|---|---|
| before 2026-03-27 | 16 MiB | 16 MiB | — |
| 2026-03-27 | 4 MiB | 8 MiB | `a30f7e95` |
| 2026-04-02 | **1 MiB** | 4 MiB | `1b8a0b88` |
| today | 4 MiB | 8 MiB | — |

Scheduled-job concurrency was cut in the same window. **A limit that is
documentation rather than contract can be lowered retroactively**, and was.

### 9.3 Correct your numbers: the transaction limits doubled

Widely-cited figures (8 MiB / 16,384 documents) are stale. Current values, and what
they were on 2025-01-22:

| Limit | Jan 2025 | Now |
|---|---|---|
| Data read / written per transaction | 8 MiB | **16 MiB** |
| Documents scanned | 16,384 | **32,000** |
| Documents written | 8,192 | **16,000** |
| Function argument / return size | 8 MiB | **16 MiB** (raised 2025-04-17) |
| Query/mutation execution time | 1 second | 1 second (unchanged) |
| Document size | 1 MiB | 1 MiB |

The 1-second cap is narrower than it reads — *"Limit applies only to user code and
doesn't include database operations."*

### 9.4 OCC conflicts, and starvation

The error text (§7.1's category 2/3 boundary in practice):

> **failure `updateCounter`** — Documents read from or written to the table
> "counters" changed while this mutation was being run and on every subsequent
> retry.

The genuinely alarming variant is **starvation**, documented by Convex itself:

> the `processBatchOfEmails` mutation is reading the whole "emails" table. That means
> it conflicts with every `enqueue` mutation. If there are too many email requests,
> **`processBatchOfEmails` might never succeed because it's blocked by continuous
> `enqueue`s.** And if `processBatchOfEmails` doesn't succeed, the set of emails
> keeps getting longer, so it's likely to take longer next time, and even more
> likely to be blocked.
> — <https://stack.convex.dev/high-throughput-mutations-via-precise-queries>

Every prescribed fix is **data-model surgery**: shard the hot document, split "hot"
and "cold" fields into separate tables, take predicate locks that read only rows in
abnormal states. Note the compounding cost: a contention fix is a schema change,
and a schema change is a widen→backfill→narrow migration (§5.3). **The remedy for a
concurrency problem costs a multi-deploy migration.**

Aggregates are the sharpest case, and Convex's CTO says the quiet part:

> the other kind of big question mark is around aggregates and analytics and OLAP
> and the phrase that **aggregates in convex suck.** — They do. Yeah. — I think it's
> probably fair… **It really is intentional that they suck.**
> — James Cowling, <https://www.youtube.com/watch?v=fqGwg6np7ek>, recorded 2026-02-25

The official Aggregate component fixes the O(n) scan with a B-tree and introduces
**false contention**:

> Users "Laura" and "Lauren" have adjacent keys, so there is a node internal to the
> Aggregate component that includes the counts of Laura and Lauren combined… **So
> when Lauren gets a new high score, Laura's query reruns (but its result doesn't
> change).**
> **Corollary: if a table's aggregate uses a key on `_creationTime`, each new data
> point will be added to the same part of the data structure (the end)… Therefore
> all inserts will wait for each other and no mutations can run in parallel.**
> — <https://github.com/get-convex/aggregate>

and can silently corrupt: *"it's very easy to forget to update the Aggregate
component when you make a mutation to the underlying data, **leaving your aggregate
in a corrupted state that you then have to migrate your way out of.** Or worse, if
you or one of your teammates changes a value in the dashboard…"*

### 9.5 Invalidation granularity — the deepest structural critique

**Invalidation is per-document, not per-field.** Confirmed by Convex (issue #95,
2025-05-19). The user:

> If I update the `userIds` field, **it invalidates all queries for that document**,
> even queries that only retrieve and return the `name` of the workspace — despite
> the fact that the result of those queries **hasn't changed at all**. … **What's
> the point of having a caching layer if any field update invalidates all queries?**

Convex (`@ikhare`): *"Query function invalidation is determined based on which
records/documents change, **not at a sub-document level**."*

The user's follow-up names the tax exactly:

> If that's the case, it means I have to **extract the `status` field into a separate
> table** just to avoid unnecessary invalidation … **It feels like a lot of overhead
> just to work around a limitation in the cache invalidation model.**

Convex now teaches this as a pattern ("hot and cold fields"). **Which means the
schema is deformed by write frequency, not just by the data model.**

**Read sets are ranges, so invalidation is over-approximate — including on empty
results.** Cowling, HN 2024-04-15:

> the readsets aren't based on lists of objects but rather **the data ranges that a
> query touches**… If you were to attempt to fetch all items from an empty shopping
> cart, that query will automatically be invalidated if any item is added to the
> cart, **even though there were no documents returned**.
> — <https://news.ycombinator.com/item?id=40037484>

And the backend admits deliberate imprecision (`crates/database/src/committer.rs`):

> Note that this can cause theoretical false conflicts… This should be very rare,
> and **false positives are acceptable by design**.

**There is no incrementality.** Cofounder sujayakar, HN 2022-06-22, answering a
former Firebase engineer:

> **we entirely re-run the javascript function whenever we detect any of its inputs
> change. incrementality at this layer would be very difficult**, since we're
> dealing with a general purpose programming language… eventually, I'd like to
> explore "reverse query execution" … using an approach like differential dataflow.
> — <https://news.ycombinator.com/item?id=31832333>

Four years later it is still unimplemented. **This is a language-design consequence,
not a backlog item:** you cannot diff the output of arbitrary TypeScript. A
community proof-of-concept (issue #479, 2026-05-27) measured what it costs — 96–99%
of a typical payload on a 100-item list. *(A parallel issue, #478, notes that
`permessage-deflate` already absorbs most of the wire cost; the irreducible cost is
the server-side **re-execution**, not the bytes.)*

Two ergonomic consequences (issue #88, 2025-05-06, still open):

- Query results are **new object references every time**, so referential equality
  breaks: *"This behavior makes it incompatible with React's `useOptimistic`
  hook."* Convex: *"a more fundamental improvement would be to maintain object
  references if query results don't change."*
- A slow paginated query **blocks all other query updates**, because the client
  applies a consistent timestamp across every subscription (§4.3): a 50ms mutation
  showed 2.6s of perceived latency. **Cross-query consistency has a cost, and this
  is it.**

### 9.6 Deploys invalidate everything — read this one twice

Directly relevant to this repo's own "deploys reset in-flight work" ground rule.
Issue #466 (self-hosted, 2026-05-06):

> every `convex deploy` triggers **~4 minutes 26 seconds of query/mutation
> rejections for all callers**… The downtime only happens when at least one
> WebSocket session is active. With no sessions open, deploy is near-instant.
> Each active WS session receives a **3.7 MB transition message** post-deploy…
> Reproduces **even on the login page with no data subscriptions** — so the 3.7 MB
> is bundle metadata (function manifest + schema validators + Components), not query
> results. Convex container at **< 5% CPU** during the entire 4m26s window.

Convex's Ian Macartney, 2026-05-13:

> No, this is not expected… **We're looking at avoiding invalidating queries whose
> code (or any of its imports) didn't change** — no promises, as it's an active
> exploration. But we are aware of the big spike of load post-deploy.

**Subscription identity is coupled to code identity.** Deploying anything
invalidates everything, whether or not the deployed change could affect any given
query. For Lazy River this is a *design decision to make deliberately now*: since
deploying is a write of source facts, a subscription's read set could include the
specific formula source fact it depends on — in which case only subscribers to
changed formulas would be disturbed. That falls out of the existing model rather
than needing "active exploration."

### 9.7 Convex's own current list of what is bad

From the episode recorded 2026-02-25 — the most authoritative statement of gaps
available, and better than anything a critic wrote:

1. **"It's hard to know how well Convex performs ahead of time."** No published
   benchmarks.
2. **"It's too easy to use the scheduler in a way which spawns a ton of jobs and
   then causes you problems."** — *"they use the scheduler API and basically say,
   'Run all of these right now.' And our scheduler goes, 'Okay, you really want me
   to try to run 10 million things at the same time…'"* The fix is the `workpool`
   component, *"the most popular component installed by far"* — and head-of-line
   blocking means a batch job can delay signup emails by an hour.
3. **"Latency can be high when you run components."** — *"when you call across a
   component boundary currently **we spin up an entirely separate V8 isolate**…
   bootstrap it with your modules and run it in there before returning to the
   caller."* This is the hidden cost of §3.7's otherwise-excellent isolation model:
   **isolation was implemented as a fresh runtime per call.**
4. **No server-side reactivity.** — *"despite the fact that you all benefit from
   awesome client side reactivity, **there really is no good way to have server side
   reactivity in Convex right now**… we kind of have this small list of missing
   primitives that have been on the to-do list for **literally five years**."* Its
   absence is *why* components hit OCC conflicts. Note that Lazy River's `Formula`
   —facts that follow from facts, invalidated by read set — **is** server-side
   reactivity, and is the primitive Convex has wanted for five years.
5. **Auth is confusing** (§9.9).
6. **Aggregates/OLAP suck, intentionally.**

### 9.8 The outage that shows the reactivity model's failure mode

Convex's own postmortem, *"How Convex Took Down T3 Chat"* (2025-06-03):

> **Problem #1: Search indexing compaction causing query invalidation.** … when our
> search indexing service runs a compaction, it causes any documents with
> search-indexed fields currently in a subscription to be invalidated, **even though
> no real data has been changed**. For T3 Chat, every online user is subscribed to
> the first 20 messages for preloading. So thousands of clients would recalculate
> tens of thousands of queries as fast as possible…
>
> We didn't yet understand why T3 chat was sporadically going from a steady-state
> query load of **~50 queries per second to 20,000+ per second**.
>
> **Problem #2:** … it can connect, issue expensive queries, have an overloaded
> server drop the connection, and then it will just do the whole thing over again.
> That's what happened here, **resulting in a DDOS from our own clients**.
> — <https://news.convex.dev/how-convex-took-down-t3-chat-june-1-2025-postmortem/>

Two transferable lessons, both cheap to act on early:

- **Invalidation must be triggered by logical data change, never by storage-layer
  events.** A compaction is not a write. If Lazy River's checkpointing, segment
  rotation, or backup ever touches the structures a read set is compared against,
  this is the exact landmine.
- **A reconnecting client must back off on server health, not on TCP connect.**
  Otherwise every overload becomes a self-inflicted thundering herd. Lazy River has
  a websocket `watch` and will have exactly this problem.

### 9.9 Auth — Convex says this is their #1 complaint

> **The complaint I hear about Convex more than any other? "Auth still isn't good
> enough."** And we agree. Getting auth set up correctly is notoriously painful.
> — <https://news.convex.dev/convex-x-workos/>, 2025-09-23

Still true, per Cowling in 2026:

> the first hour of the day sucked cuz the first hour of the day was me trying to
> bootstrap a project, figure out what auth provider to use and I got in some kind
> of weird auth mess … **the auth story is still confusing and it's still probably
> the biggest friction point for new projects.**

Four competing options (Convex Auth, Clerk, WorkOS AuthKit, better-auth); Convex
Auth has been in beta since launch and was *"put on ice"* — Turner: *"maybe that
was a mistake."* Auth is also the largest cluster of open issues (#75, #108, #145,
#259, #242, #402).

**This is the most encouraging finding in the whole document for Lazy River.**
Convex's worst friction point is the one place Lazy River has already made a
structural decision instead of a product decision: *"Authorization is which ledgers
a caller may name. Not row rules, not predicates."* Convex's problem is that
identity is a third-party concern bolted to a data model with no natural place for
it. Keep that decision, and do not grow four options.

### 9.10 The action boundary and the two-runtime tax

The 2023 objection, still the clearest statement (HN, 2023-01-30):

> transaction patterns where **external interaction is needed within the transaction
> are not uncommon**. A tradeoff of automatic transaction retries for a constraint
> that you can never have client-side side effects … means you are likely to have to
> write more higher level business transaction compensation logic … **in practical
> terms it's a trade off, not a pure gain.**
> — <https://news.ycombinator.com/item?id=34587632>

The 2025 version, from Diwaker's friction log: *"**Perhaps my biggest frustration in
using Convex was the different ways Actions caught me by surprise**"* — chiefly that
npm packages that work locally don't work in the isolate.

The `"use node"` partition's accumulated damage:

- Argument limit 5 MiB (Node) vs 16 MiB (Convex runtime); RAM 512 MiB vs 64 MiB;
  execution 10 min vs 30 min; queries/mutations 1 second.
- **Windows has been broken for over a year.** Issue #152, opened 2025-07-17, still
  open: *"On Windows, absolute paths must be valid file:// URLs. Received protocol
  'c:'"*. Convex's advice was *"it's going to be a lot more likely to work on WSL."*
  A fix landed in April 2026 — **filed by a community member, not Convex.**
- **No Bun**, and the refusal leaks the architecture (issue #279, 2026-02-08):
  *"Running bun in the production environment would require adding another AWS lambda
  setup and a **third bundling setup of code** (currently we bundle 'use node' files
  separately from the normal runtime)."*
- **A userland dependency upgrade can make your deployment un-pushable.** Issue
  #414, 2026-03-23: Zod v4 causes *"JavaScript execution ran out of memory (64 MB)"*
  during push.

For balance, the payoff determinism actually buys:

> When you use the scheduler with a mutation, it will indefinitely retry the mutation
> on database conflicts until it succeeds or throws an exception from your code. It
> will continue retrying across server restarts or suspension, **giving you an
> exactly-once guarantee**.
> — <https://stack.convex.dev/durable-workflows-and-strong-guarantees>

with a caveat buried below it: called directly from an action or over HTTP, *"it
will retry database conflicts, **but not automatically retry otherwise**."*

### 9.11 No SQL, no joins, and analytics is someone else's system

The best quote in the whole corpus, jamwt on HN 2023-01-30:

> SQL is the C ABI of querying for sure. **BI tools will never adapt to use Convex
> directly, and nor should they.**
> So… yes, Convex actually had a prototype SQL adapter for the read side of things
> back in the early few months… **We've kept this adapter on ice** in part because…
> if we exposed SQL on the thing as-is, this would presumably be for more analytical
> type queries involving patterns normal Convex queries can't express. Right now
> that would be a Bad Idea because your website would slow down just like every
> other database system allows you to.
> So the current recommended practice is **use our Airbyte Egress connector and get
> yourself into an offline Clickhouse/MySQL/Snowflake whatever**.
> — <https://news.ycombinator.com/item?id=34586364>

Three years on, still unshipped. Also conceded on `convex.sucks`: **no joins**
(*"The `withIndex` syntax is a little clumsy and it's extra code to write"*), and
per issue #95, **no array-membership indexing** — *"you might want to query all
workspaces where a given `userId` is included in `userIds`, but that's currently
**not supported at all**. This makes many-to-many relationships difficult."*

The honest reading: **a reactive engine optimised for many small consistent reads is
not an analytical engine, and pretending otherwise would ruin the first property.**
The mistake is not the constraint; it is having no story for the second system for
three years while claiming to replace the backend.

### 9.12 Papercuts that cost week-one users

- **`null` vs `undefined` (issue #245, 2025-11-01, open).** The API demands `null`
  for a blank field but `undefined` to clear one via `db.patch`, and — the actually
  broken part — *"if the client sends `undefined` to the API, Convex just drops it
  and it never gets to the mutation."* **There is no way through the API to
  distinguish "leave this field alone" from "unset this field."** Convex: *"I don't
  think this [is a] change we'd be willing to make."* The original report:
  *"This application ended up having a lot of boilerplate, with the structure of the
  data having to be defined 4 times, which feels very error prone."*
- **`exactOptionalPropertyTypes` (issue #211).** Convex emitted `prop?: T | undefined`
  where the runtime omits the key. Thomas Ballinger: *"Tom has been internally
  advocating for this for years."* **Fixed 2025-09-15** (`3d89c6eb`, ~`convex@1.27.1`).
- **Monorepo type blowup** — `"Type instantiation is excessively deep and possibly
  infinite"` (convex-js #53, open since 2025-07-09). Same root cause as §2.7.
- **Silent data corruption**: issue #498, 2026-07-04 — *"Storage Blob returns
  zero-filled bytes on second read in the default runtime."*
- Local backend port 3210 is hardcoded (#288); `npx convex codegen` can't run on
  Vercel (#81, and §2.5); File Storage security model undocumented with files
  publicly accessible (#328).

### 9.13 What people praise, as calibration

Worth recording, because it says which costs were worth paying. The reactivity
genuinely eliminates a whole category of cache-invalidation and state-management
code. End-to-end type safety from schema to component is real, and it is real
*because* of the constraint in §5.3 — since a schema cannot deploy unless it matches
the data at rest, *"you can safely trust that the typescript types inferred from your
schema match the actual data."* And the refusal to ship pretend-cheap primitives —
no `COUNT`, no `SELECT`, no query planner, mandatory explicit indexes — is widely
liked and is what keeps performance predictable. **The complaint is never the
constraint; it is that the replacement carries hidden costs the constraint was
supposed to eliminate.**

Finally, the practice worth copying outright: **Convex publishes its own criticism.**
`convex.sucks`, two podcast episodes of self-critique, and a detailed public
postmortem of taking down their largest customer. It buys real goodwill. The tell to
avoid is also visible — one of the six gaps they list has been *"on the to-do list
for literally five years."* **Candour without shipping eventually reads as a shrug.**

---

## 10. What transfers, and what does not

### 10.0 Where Lazy River already is

Worth stating first, because it changes what is worth copying. Reading
`lib/lazy_river/`, the *engine* already has Convex's core mechanisms, sometimes
in a cleaner form:

| Convex mechanism | Lazy River equivalent | Status |
|---|---|---|
| Query read set | `Formula` — "the dependency list is not written because it is *observed*" | present |
| Subscription = read set + log walk | `Subscription` — "a write outside it pushes nothing" | present |
| Determinism by runtime substitution (seeded `Math.random`, frozen `Date.now`) | `Lua.run(source, as: :formula)` — "`os` and `math.random` are absent rather than discouraged" | present, and **stricter** |
| Effects quarantined into actions | `Job` — "the only thing a schedule can attach to" | present |
| Errors carry a repair | `%{problem: atom(), repair: String.t()}` | present |
| Deploy = a push of bundled source | deploy = a `write` of source facts | present, and **better** |
| Cache invalidation | none needed — "a client caches on `{name, question}` and never invalidates" | **strictly better** |

The gap is not the engine. **The gap is everything in sections 1, 2, 6, 7 and 8 of
this document**: there is no CLI, no authoring loop, no local run story, no error
surface for an author, no test harness. That is what this research is for.

Two of these deserve emphasis, because Convex names them as its own unsolved
problems (§9.7) and Lazy River has already solved them structurally:

- **Server-side reactivity.** Convex's CTO, 2026-02-25: *"there really is no good
  way to have server side reactivity in Convex right now… we kind of have this small
  list of missing primitives that have been on the to-do list for literally five
  years."* Lazy River's `Formula` — facts that follow from facts, staleness decided
  by an observed read set — **is** that primitive. It is also, per §9.7, the missing
  piece that causes Convex's components to hit OCC conflicts.
- **Auth.** Convex's self-declared #1 complaint (§9.9), with four competing options
  and a first-party solution "on ice." Lazy River made it a structural decision
  instead: *"Authorization is which ledgers a caller may name. Not row rules, not
  predicates."* **Do not grow four options.**

### 10.1 Transfers directly — take these

**1. The dev loop's watch set is the last build's read set.** (§1.4)
Convex watches exactly the files the push actually read, and an event only
triggers a rebuild if it overlaps. Lazy River has this concept *already*, one
level down, in `Formula` — "running a formula records what it read." Use the same
idea one level up: a `river dev` should watch what the last deploy-write actually
read (the formula sources, the job sources, whatever files they included), not a
glob. And note the 500ms quiescence window with deadline extension — a `git
checkout` must produce one deploy, not two hundred.

**2. A failed push names the input that would fix it, and the loop then watches
that input.** (§1.5, §5.2) This is the best single idea in Convex's CLI. Their
error taxonomy is not `error`/`warning`; it is *which input is wrong*:

```
"invalid filesystem data"          → watch files
"invalid filesystem or env vars"   → watch files AND the deployment's env vars
{"invalid filesystem or db data": {tableName}}  → watch files AND that table
```

Lazy River's refusals already carry `%{problem:, repair:}`. Add a third field —
the *input* — and a `river dev` can race a file watcher against a `watch`
subscription on the ledger that the refusal named. A formula that refuses because
an attribute doesn't declare its space would then retry by itself the moment
somebody writes the declaration. **You already have the websocket that makes this
free; Convex had to build one for the CLI.**

**3. Generated code should be a manifest, not a projection.** (§2.2) The reason
`convex/_generated/` is not a merge-conflict swamp is structural: `api.js` is three
lines, and `api.d.ts` has *one line per module file*. Adding a function changes
nothing. If Lazy River ever emits a client-side surface (typed formula/job
references for an Elixir or TS caller), emit **the list of names**, not a
projection of each name's shape, and let the consumer's type system or runtime do
the rest. Also: sort with a platform-stable comparator so the artefact is
byte-identical everywhere, and put the regeneration command in the file header.

**4. A missing input produces a weaker artefact that explains itself, not an
error.** (§2.3) `dataModel.d.ts` with no `schema.ts` is `Doc = any` plus a comment
saying why and linking the fix. Applies directly to Lazy River: an attribute with
no declared space, a formula with no recorded read set yet, a ledger with no facts
— each should produce a working-but-weak answer that names its own weakness.

**5. Long operations are progress bars that link to somewhere better.** (§5.2)
`Backfilling indexes (3/7 ready) and checking that documents match your schema...`,
and after ten seconds it appends a URL. Any Lazy River operation that scans a
ledger — a backfill, a `verify`, a formula's first run over a large snapshot —
should stream `(n/m)` and, past a threshold, tell you where to watch it. The
`watch` channel is the obvious place to publish that from.

**6. Log muting across a deploy.** (§1.3) `--tail-logs pause-on-deploy` is the
default because a dev server that streams runtime logs into the same terminal as
build output drowns its own errors. Cheap, and nobody thinks of it until they have
been bitten.

**7. `--once` / `--until-success` as distinct loop shapes.** (§1.6) `--once` for
CI and agent setup; `--until-success` for "retry, including on remote changes, and
exit as soon as it works." Both are needed and they are not the same flag.

**8. Non-interactive + unauthenticated is a signal, not an error.** (§1.8)
Convex's rule — *"when no deployment is already configured and `CONVEX_DEPLOY_KEY`
isn't set, the CLI defaults to provisioning a local deployment automatically"* —
is exactly right for a world where agents run your CLI. Lazy River is a single
node with a `LEDGER_DIR`; the equivalent default is "no `LEDGER_DIR`, no
credentials, non-interactive → start an in-memory node and point at it." The
README already says an in-memory ledger "is right for a test"; make it right for
an agent too.

**9. Per-worker isolation as the default, with a TTL.** (§6.7, §1.8) One
deployment per developer, per branch, per agent worktree, and
`--expiration "in 5 days"` on the create call. For Lazy River the cheap analogue
is a **ledger namespace per worker**, since authorization is already "which
ledgers a caller may name" — an agent gets a token that can name only its own
ledgers, and those ledgers have an expiry fact.

**10. Declared configuration is separate from set configuration.** (§6.6) Convex's
newer `defineApp({ env: { GIPHY_KEY: v.string() } })` declares *what must exist and
of what shape* in the repo, while the values live only in the deployment — and the
declaration then prevents `env remove` from breaking things. Lazy River's config
table in the README is currently prose. Making it a declaration the node reads at
boot, which refuses a deploy that would remove a required variable, is the same
move.

**11. The migration runner is a function you happened to write.** (§5.5) No
`convex migrate` verb; you run a migration with `npx convex run`, the same command
you run anything with. Its status is a *reactive query*. For Lazy River this is
nearly free and philosophically identical: a backfill is a **job**, its progress is
facts, and `watch` on those facts is the progress bar. Copy the operational
semantics — resume from the failed batch by default, `reset` to restart,
`dryRun` that runs one batch **and then throws so nothing commits**, serial by
default with parallelism opt-in.

**12. Naming: the typed surface is sugar over a stable string namespace.** (§3.2)
`api.foo.myQueries.myQuery` is always also `"foo/myQueries:myQuery"`. That string
is what the CLI takes, what non-TS clients use, and what makes an OpenAPI export
possible. Lazy River should fix the canonical string name of a formula/job **now**,
before any client library exists, because everything else becomes sugar over it.

**13. `--cmd` inverts build ordering to solve a chicken-and-egg.** (§6.4) Whenever
a downstream build needs a value that only the deploy can produce, the deploy tool
should own the build rather than the reverse. If Lazy River ever grows a client
that must be told a ledger name or a node URL that the deploy creates, this is the
shape.

**14. `npx convex run --inline-query`** (§: CLI). A sandboxed, read-only,
throwaway query typed on the command line:

```
npx convex run --inline-query 'await ctx.db.query("messages").take(5)'
```

> The function call is also completely sandboxed, so it can only read data and
> cannot modify the database or access the network.

For Lazy River this is *trivially* available and enormously valuable: `river ask
--lua 'return facts{attribute="height"}'` is just `Lua.run(source, as: :formula)`
against a snapshot. It is a REPL that cannot break anything, and it falls out of
the formula/job split for free. **Ship this early — it is the cheapest possible
demonstration that the fence is real.**

**15. Generated agent instructions are a first-class artefact with their own
verbs.** (§2.6) `npx convex ai-files status|install|enable|update|disable|remove`,
writing a *Convex-owned section* of `AGENTS.md`/`CLAUDE.md` and checking staleness
against a remote hash. This repo already generates the `words` skill via
`onto-sync`; the two additions worth copying are **section-scoped writes into files
the tool does not own**, and **`enable`/`disable` as verbs distinct from
`install`/`remove`**, so that "the user turned this off" is recorded rather than
inferred from a missing file.

**16. An extension is the same artefact a user writes, installed under a name that
scopes what it may reach.** (§3.7) Convex components have no plugin API: a
component is a package of ordinary functions plus its own schema, and
`app.use(agent, { name: "agent2" })` gives it its own tables. Isolation is by
absence ("can't read data that is not explicitly provided to it"), and each call
is a **sub-transaction**, so a thrown error rolls back the component's writes and
nothing else — which is what makes installing someone else's code into your
transaction survivable. For Lazy River: a bundle of formulas and jobs plus a
ledger, installed under a name, where the name is what the existing
"authorization is which ledgers a caller may name" rule already scopes. **You get
this nearly free; Convex had to build a sandbox boundary for it.**

**17. Publish your own criticism.** (§9.13) `convex.sucks`, two podcast episodes of
structured self-critique, and a detailed public postmortem of taking down their
largest customer were the highest-signal sources in this entire research — better
than anything a critic wrote — and they visibly buy goodwill. This repo's doctrine
("claims are doctrine in that database, choices are in the commit that made them")
already has the substrate for it: **a "what this does badly" list belongs in the
ontology as rulings, not in a marketing page.** The tell to avoid is also visible in
Convex's version — one of their six admitted gaps has been "on the to-do list for
literally five years." Candour without shipping eventually reads as a shrug.

**18. Everything the CLI can do, the dashboard can do, and vice versa.**
`npx convex data <table>` is explicitly "a simple view of the dashboard data page
in the command line." One capability, two renderings — and the CLI one is what an
agent uses.

### 10.2 Transfers as a warning — do not inherit these

**1. Rollback does not exist, and the schema gate makes it impossible.** (§6.8)
This is Convex's sharpest self-inflicted wound. Because a schema must match the
data at rest, once you have narrowed a schema you *cannot* redeploy the old code.
Their answer is a doctrine — additive-only, push schema separately from code — and
doctrine is not a mechanism.

Lazy River is in a much better position and should not squander it: **deploying is
a write, source is a fact, and facts are immutable and named.** A rollback is
therefore *already* expressible as "open at the earlier snapshot name" or "write
the earlier source fact again." Make that a first-class verb (`river rollback
<name>`) on day one rather than discovering later that the doctrine is all you
have. Note the asymmetry to respect: rolling back *formula* source is safe because
formulas are pure and rederivable; rolling back *job* source is not, because jobs
already reached outside.

**2. Determinism at the runtime level does not make the dependency graph
honest.** (§4.5) Convex freezes `Date.now()` inside a query — and then has to tell
you in Best Practices *"Don't use `Date.now()` in queries"*, because time is not in
the read set, so the answer never invalidates. Lazy River is already stricter (`os`
is *absent* from a formula, not frozen), which is the right call — but the general
lesson stands: **anything a formula can observe that is not part of the snapshot is
a silent staleness bug.** Audit the whole bound world of `as: :formula` against
that test, not just the clock.

**3. Inference-heavy generated types are a scaling trap with an ugly exit.**
(§2.6) Convex's `api` object is beautiful and got slow, and the escape hatch
(`staticApi: true`) costs jump-to-definition, return-type inference, and TS enums.
The lesson for Lazy River: if you generate anything for a typed client, **prefer
the materialised form from the start** and accept the staleness, or design so
nothing needs generating at all. Lazy River's string-named formulas over a dynamic
Lua surface may simply not have this problem — that is a reason to keep it that
way, not an accident to fix.

**4. Codegen that requires a live backend fails in the one place you need it.**
(§2.5) `npx convex codegen` refuses with `Codegen requires an existing deployment
so doesn't support CONVEX_DEPLOY_KEY.` — i.e. it does not work in CI. They mitigate
with "commit the generated code and diff it," which works but is a workaround.
**Whatever Lazy River generates must be derivable from the repo alone.**

**5. `.env.local` holding the deployment identity is convenient and leaky.** It
makes per-developer deployments free (good) but it also means "which backend am I
talking to" is invisible state on a developer's disk. Convex compensates with the
loud colour-coded interlock prompt before any prod deploy (§6.2). If Lazy River
puts the node URL and ledger set in a dotfile, **copy the interlock too** — print
the target, print what it serves, and default the confirmation to the safe answer.
Their index-deletion prompt defaults to **No**; theirs is the right instinct.

**6. Two runtimes with a bundler-enforced partition is a permanent tax.** (§3.3)
`"use node"`, files that may not import each other, an ESLint rule to catch it, a
`--debug-node-apis` flag with a slower bundler to explain the failures, and a
separate memory/timeout/argument-size regime. This exists because their fast
runtime cannot run arbitrary npm. **Lazy River has one runtime (Luerl on the BEAM)
and should fight hard to keep it that way** — the moment there is a second place
code can run, you have inherited the whole partition problem, plus its error
messages.

**7. Actions are second-class and everybody feels it.** (§3.5) An action is not
transactional, not retried, must not be called from the client, and multiple
`runQuery` calls from one action are not a consistent snapshot. Convex's answer is
a *pattern* (mutation writes intent + schedules action → action → mutation records
progress) and later a set of components (Workpool, Workflow) to make the pattern
survivable. Lazy River's `Job` already writes its answer and its failures as facts,
which is that pattern **built in rather than prescribed**. Keep it that way, and
resist any convenience that lets a caller invoke a job and await its answer
inline — that is the exact door Convex left open and then spent documentation
closing.

**8. "No need to think about this" is a claim that gets audited.** (§3.4) The OCC
page ends with *"day to day there's no need to worry about conflicts, locking, or
atomicity."* Convex then had to write a whole errors page about
`Documents read from or written to the table "counters" changed while this mutation
was being run and on every subsequent retry`, ship an `npx convex insights` command
whose stated purpose is reporting OCC conflicts, and publish three components
(Workpool, Sharded Counter, Action Cache) whose reason for existing is working
around it. **Do not promise that a resource limit is invisible.** Convex's own
better instinct is elsewhere on the same page: *"If your functions are close to
hitting these limits they will log a warning."* Warn before the wall; don't claim
there is no wall.

**9. The read set is the subscription, so over-reading is over-subscribing —
and it is also the bill.** (§4.4) `.collect()` on a large table subscribes you to
the whole table. Lazy River inherits this exactly, since `Subscription` is a read
set. The mitigations Convex reached for, in order: an ESLint rule
(`no-collect-in-query`), a Best Practice, a transaction limit that errors, and a
warning before the limit. **Build the warning and the limit before you need the
lint** — a limit that errors is a contract; a lint is advice.

**10. Deploy invalidates every subscription, because subscription identity is
coupled to code identity.** (§9.6) Four and a half minutes of rejected queries and a
3.7 MB transition message per client, *on a login page with no data subscriptions*,
at under 5% CPU — and Convex's answer in 2026 is that avoiding it is "an active
exploration." **Decide this now, while it is free.** Since deploying is a write of
source facts, a subscription's read set can simply *include the source fact of the
formula it depends on*. Then redeploying an unrelated formula disturbs nobody, and
redeploying a depended-on formula invalidates exactly its subscribers — by the same
read-set mechanism that already exists, with no special case. This also directly
serves this repo's standing "deploys reset in-flight work" rule.

**11. Invalidation granularity is the whole ballgame, and it decides your users'
schemas.** (§9.5) Convex invalidates per *document* and per *index range*, so a
write to any field re-runs every query that touched that document, and a query over
an empty range still re-runs when anything enters the range. The user-visible
consequence is that people are told to split "hot" and "cold" fields into separate
tables — **the data model gets deformed by write frequency.** Lazy River's unit is a
fact `{entity, attribute, answer}`, not a document, so attribute-level granularity
is available *for free* and should be taken deliberately rather than by accident.
The same choice also decides whether a "hot attribute" forces a user to restructure
their ledgers.

**12. Never let a storage-layer event trigger invalidation.** (§9.8) Convex took
down its largest customer because a *search index compaction* — which changes no
logical data — invalidated every subscription touching a search-indexed field,
taking a 50 qps deployment to 20,000+ qps. Lazy River has checkpoints, segment
rotation, and a backup job that all touch the structures reads are compared
against. **Write the test now**: perform every maintenance operation and assert
that no subscription fires.

**13. A reconnecting client must back off on server health, not on TCP connect.**
(§9.8) The second half of the same outage was a self-inflicted DDOS: clients
reconnected, issued expensive queries, got dropped by an overloaded server, and
immediately repeated. Lazy River's `watch` channel will have exactly this failure
mode.

**14. `strictTableNameTypes: false` and `schemaValidation: false` are two knobs
that quietly turn off different things.** The second also disables *index
reference checking*, which is not what its name says. If Lazy River grows any
"trust me" escape hatch, make each one name exactly the check it removes.

**15. A concurrency remedy that costs a migration is very expensive.** (§9.4) Every
OCC fix Convex prescribes — shard the counter, split hot and cold fields, narrow the
read — is a schema change, and a schema change is a widen→backfill→narrow
multi-deploy dance (§5.3). The two problems multiply. Lazy River's append-only,
attribute-grained model means "the schema" is much less of a thing, which is an
advantage worth *keeping* rather than spending: resist any feature that makes a
contention fix require restructuring what a user already wrote.

**16. Arbitrary code cannot be incrementalised, and that is permanent.** (§9.5)
Convex's cofounder said in 2022 that incrementality "would be very difficult… since
we're dealing with a general purpose programming language", and named differential
dataflow as the aspiration; four years later a query still re-runs whole. **Lua is
also a general-purpose language, so Lazy River inherits exactly this.** The
`Formula` moduledoc already anticipates it — *"This one re-executes… an incremental
evaluator would slot in underneath without any formula changing"* — and the escape
route is visible in `Sandbox.mapping`: a *restricted shape* ("applies an exported
`apply` to every answer matching a pattern") is narrow enough to incrementalise, and
arbitrary Lua is not. If incremental evaluation is ever wanted, **it will only be
available for the restricted shapes**, so those shapes are worth defining before
everything is written as free-form Lua.

**17. A limit that lives in documentation can be lowered retroactively, and
Convex did it.** (§9.2) Mutation write throughput was cut 16 → 4 → 1 MiB in a week
in 2026 by editing a docs page, then partly restored. Whatever Lazy River's
transaction/deadline/heap limits are, they should be **stated where they are
enforced** — in the refusal — and the refusal should name the actual number it
enforced, not a documented one.

**18. Do not meter something the user cannot predict.** (§9.2) Convex bills per
function call, and *subscription updates are function calls*, so the price of a
query is a function of other people's writes. Their CEO conceded on the record that
estimating cost is genuinely hard and promised a calculator that still does not
exist. The Lazy River analogue is not billing but **resource attribution**: if a
formula's cost depends on write traffic it does not control, that has to be
observable (a fact) before anyone is surprised by it.

### 10.3 Does not transfer — TypeScript/JS-toolchain artefacts

These are large parts of Convex's DX that solve problems Lazy River does not have.
Listing them is useful mainly so they are not cargo-culted:

- **The whole bundling apparatus** — esbuild, tree-shaking, 32 MiB code limits,
  `externalPackages`, dynamic-import failures, the CJS/ESM interop errors,
  `source-map-explorer` for debugging bundle size. Lua source is source. There is
  nothing to bundle. (§3.3, Bundling)
- **`_generated/server.js` re-exporting parameterised builders.** This exists
  because TypeScript needs a place to bind a `DataModel` type parameter. In a Lua
  guest, the host binds the world at call time (`Lua.run(source, as: :formula)`),
  which is the same idea achieved at runtime with no artefact. The *seam* is worth
  keeping — it is where wrappers get installed — but it should be a host-side
  concept, not a generated file.
- **Typecheck-before-push, `tsc --noEmit`, TypeScript 7, `generateTrace`, and the
  entire "Typecheck Performance" page.** The equivalent question for Lazy River is
  much smaller: does the Lua parse, and does it name only bound functions? Both are
  fast and both are answerable without a compiler. **But do keep the shape:** there
  *is* a static check that runs before the deploy-write lands, and its failure is a
  refusal with a repair.
- **The `api`/`internal` split enforced by `FilterApi` in generated types.**
  Public-vs-internal reachability is real and worth having, but Lazy River should
  express it as an attribute of the fact that declares the formula/job — a
  property of the thing, checked at the surface — rather than as a type-level
  filter that only one client language can see. The Convex version is invisible to
  their own Python and Swift clients.
- **React-specific ergonomics** — `useQuery` returning `undefined` while loading,
  `"skip"` as a sentinel argument, error boundaries, optimistic updates. The
  *underlying* decisions transfer (a loading state cheap enough that nobody skips
  it; a way to express "not yet, don't subscribe"; automatic rollback of a
  speculative write), but the hook shape does not.
- **Vercel/Netlify/Cloudflare preview-deployment integration.** Convex's preview
  system exists because their users deploy frontends to those platforms and want
  a backend per PR. Lazy River is a single node with an HTTP/WS surface; the
  transferable core is "a throwaway environment with a TTL, seeded by a function,
  named after the branch," not the host integrations.

### 10.4 The four operations, mapped

Concretely, where each Convex idea lands on Lazy River's surface. **The command
names below are placeholders for shape, not proposals** — nothing here has been
through `monty onto check`, and `river` in particular is an unchecked name.

| Convex | Lazy River |
|---|---|
| `npx convex dev` watch loop | a `river dev` that watches the source files the last deploy-write read, races that against a `watch` subscription on the ledger a refusal named, 500ms quiescence, prints `HH:MM:SS ready (Nms)` |
| `npx convex run <fn> [args]` | `river ask <name> <question>` — already the `ask` operation |
| `npx convex run --watch` | `river watch` — already the `watch` operation, already a websocket |
| `npx convex run --inline-query '<js>'` | `river ask --lua '<source>'` — `Lua.run(as: :formula)` against a snapshot; sandboxed by construction |
| `npx convex deploy` | a `write` of source facts, returning the new snapshot name; **the name is the deploy id and the rollback target** |
| preview deployment with a TTL | a ledger namespace with an expiry fact, scoped by the same authorization that already decides which ledgers a caller may name |
| `npx convex env` | config declared in the repo, values written as facts to a config ledger the node reads at boot |
| schema push validation pass | a formula's first run over the snapshot — same shape: full scan, streamed progress, refusal names the fact |
| `npx convex logs` | `watch` on the job/failure facts — "what is failing, and since when is a question rather than a log search" |
| `npx convex insights` | a formula over the failure and read-set facts |
| dashboard data browser | `ask` with a pattern; the CLI rendering and the web rendering are the same capability |
| migrations component | a `job` whose progress is facts, watched |
| `npx convex codegen` | ideally nothing; if anything, a manifest of names derivable from the repo alone |

The recurring shape: **Convex had to build a control plane beside the database
(CLI protocol, deploy2 endpoints, `_system/cli/*` queries, a subscription just for
the dev loop). Lazy River's four operations already are that control plane**,
because source is facts and progress is facts. The work is not building the
mechanism; it is deciding the command names and the output, and making refusals
name their input.

---

## Sources

Primary, in rough order of how much of this document came from each.

**Documentation** (docs.convex.dev serves raw markdown at any page URL + `.md`,
and the whole corpus at `/llms-full.txt` — ~2.4MB, which is what most quotes here
come from):

- <https://docs.convex.dev/llms-full.txt> and <https://docs.convex.dev/llms.txt>
- <https://docs.convex.dev/cli> · `/cli/reference/dev` · `/cli/reference/deploy` ·
  `/cli/reference/codegen` · `/cli/reference/run` · `/cli/reference/env`
- <https://docs.convex.dev/cli/local-deployments> · `/cli/agent-mode` ·
  `/cli/deploy-key-types`
- <https://docs.convex.dev/functions/query-functions> · `/functions/mutation-functions` ·
  `/functions/actions` · `/functions/runtimes` · `/functions/bundling` ·
  `/functions/debugging` · `/functions/error-handling/` ·
  `/functions/error-handling/application-errors` · `/functions/validation`
- <https://docs.convex.dev/generated-api/> · `/generated-api/api` ·
  `/generated-api/data-model` · `/generated-api/server`
- <https://docs.convex.dev/database/schemas> · `/database/types` ·
  `/database/indexes` · `/database/advanced/occ` ·
  `/database/advanced/schema-philosophy` · `/database/import-export/` ·
  `/production/backups`
- <https://docs.convex.dev/production/> · `/production/hosting/vercel` ·
  `/production/environment-variables` · `/production/project-configuration` ·
  `/production/multiple-deployments` · `/production/state/limits`
- <https://docs.convex.dev/understanding/workflow> · `/understanding/zen` ·
  `/understanding/best-practices` · `/understanding/best-practices/typescript`
- <https://docs.convex.dev/eslint> · `/error` (Errors and Warnings)
- <https://docs.convex.dev/dashboard> and its deployment sub-pages
- <https://docs.convex.dev/testing/> · `/testing/convex-test` · `/testing/convex-backend`

**Source** (`get-convex/convex-backend`, which vendors the CLI at
`npm-packages/convex/src/`; license is FSL, Apache-2.0 after two years):

- `cli/lib/dev.ts` — the watch loop, observation-based watching, the three-way
  watcher race, the error taxonomy, `quiescenceDelay = 500`
- `cli/codegen.ts`, `cli/codegen_templates/{api,dataModel,common}.ts` — the
  generated-code templates quoted in §2
- `cli/lib/deploy2.ts` — the push/schema poll loop and its spinner text
- `cli/lib/checkForLargeIndexDeletion.ts` — the index-deletion confirmation
- `cli/lib/envvars.ts` — framework URL-variable inference
- `crates/common/src/schemas/mod.rs`, `crates/common/src/schemas/validator.rs`,
  `crates/common/src/bootstrap_model/schema_state.rs` — the schema state machine
  and the exact validation error strings
- `npm-packages/convex/CHANGELOG.md` — the version timeline

**Engineering writing:**

- <https://stack.convex.dev/how-convex-works> — read sets, the subscription
  manager, and the shared overlap algorithm
- <https://stack.convex.dev/intro-to-migrations> ·
  <https://stack.convex.dev/migrating-data-with-mutations> ·
  <https://stack.convex.dev/schema-philosophy>
- <https://github.com/get-convex/migrations> — the migrations component README

**Criticism (§9)** — individual URLs and dates are inline in that section. The
highest-signal sources were Convex's own:

- <https://www.convex.sucks/> — their self-roast page
- <https://www.youtube.com/watch?v=FMhaM3yXYbk> — *"Why Convex Sucks — For Now"*, 2025-08-13
- <https://www.youtube.com/watch?v=fqGwg6np7ek> — follow-up, recorded 2026-02-25;
  the six-gap list in §9.7
- <https://news.convex.dev/how-convex-took-down-t3-chat-june-1-2025-postmortem/>
- <https://news.convex.dev/self-hosting/> (2025-02-13) and
  <https://news.convex.dev/convex-x-workos/> (2025-09-23)
- <https://stack.convex.dev/high-throughput-mutations-via-precise-queries> and
  <https://stack.convex.dev/why-doesn-t-convex-have-select-or-count>

Third-party: Hacker News via the Algolia API (threads 31832333, 34585773, 34586016,
34586364, 34587632, 40035309, 40037484, 41260776); the `get-convex/convex-backend`
issue tracker (#6, #88, #95, #152, #211, #245, #279, #288, #328, #360, #414, #443,
#466, #479, #498) and `convex-js` (#53); <https://diwaker.io/friction-log-convex/>
(2025-09-15); <https://ocavue.com/posts/convex-first-look/> (2025-06-24);
<https://github.com/get-convex/aggregate>. Reddit was unreachable from this
environment, so community sentiment is drawn from HN and issue trackers instead.

**Do not cite** `makerstack.co`, `fromscratch.dev/alternatives/convex`, or
`trybuildpilot.com` on Convex — all AI-generated, all repeating the false claim that
Convex cannot be self-hosted.

---
