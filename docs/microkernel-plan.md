# The microkernel plan — the final form of the BEAM-isolated sandbox

*Drafted 2026-08-15, after the reversal (storage-plan.md). Status: plan.
Same discipline as the storage plan: each phase is test-first, every commit
stays green, and a phase's verdict is written here before the next begins.*

## What the final form IS

One sentence: **a guest is a BEAM process whose entire operating system is a
capability table, and that table now grows to a complete, documented,
deterministic POSIX-shaped surface — implemented natively in Elixir, like
Luerl.** No wasm, no NIFs in the guest path, no processes, no host paths, no
network except what a `:job` is granted. Lua authors; Elixir hosts.

What exists today (the floor this plan builds on): Luerl guests (unlinked,
deadline, `max_heap_size`, 0.1ms floor); `file.read/write/list` over the
key→bytes VFS; `sh()` — a pure-function shell with real grammar (pipes, `;`,
`&&`/`||`, `>`/`>>`, `$VAR`, `for`/`while`/`if`, block tails) and ~19 native
tools including a sed `s///` subset and seq; `sql()` read-only over the
world's own SQLite file; captured `print`; the prelude shelf (json, lust);
`http.get`+`blob` for jobs only; the kong-derived fence tripwire.

## What else it needs (the gap inventory, syscall-table framing)

Ordered by what an agent actually reaches for, not by POSIX completeness:

1. **Real conditionals and status** — `test`/`[` (`-f`, `-z`, `-n`, `=`,
   `!=`, `-eq`/`-lt`/`-gt`), `$?`, exit codes threaded through the grammar.
   Today `if` can only test a command's success and the only predicates are
   true/false/grep — this is the single biggest expressiveness hole.
2. **Command substitution and arithmetic** — `$(...)` (the parser already
   recurses; substitution is an eval-into-word) and `$((...))` integer
   arithmetic. `n=$(wc -l < notes.txt)` is the idiom that makes vars+loops
   actually compose.
3. **The missing coreutils** — tr, cut, nl, tac, paste, tee, diff (small
   LCS), find (pattern walk over keys), xargs, basename/dirname, sha256
   (`:crypto`), grep gains `-n`/`-E` (Elixir Regex for `-E`), sort `-n`/`-r`,
   uniq `-c`, wc `-w`/`-c`, head/tail `-n N` spelling. Each lands with usage
   text, because of (7).
4. **Filesystem semantics over the flat map** — `cd`/`pwd` as a current
   PREFIX (resolution stays key math; there is still no filesystem), cp,
   stat (size), du, and `**` in globs. Directories remain implicit — the
   flat map is the design, not a limitation to fix.
5. **Streams done honestly** — a second stream: stderr per command, `2>`,
   `2>&1`; `sh()` grows Lua multiple-return `out, rc` (backward-compatible —
   today's callers read only `out`); OUTPUT CAPS with a refusal that names
   the limit (a guest printing gigabytes should get a repair, not a
   heap-kill).
6. **Determinism kept under growth** — `date` exists but reads the guest's
   frozen `at` (a formula's date is the snapshot's date, deterministic);
   `whoami` prints the run's provenance id; NO `$RANDOM` (math.random is
   already seeded from `at` in Lua — the shell inherits the same stance).
7. **Introspection as a first-class tool** — `help` (the shelf with one
   usage line per tool: the man page an agent can actually read), and the
   unknown-command refusal keeps naming the shelf. The sandbox documents
   itself from inside.
8. **What it deliberately never gets** (absence, recorded): processes/`&`/
   signals/subshell-as-process (jobs are the async model), tty, users and
   permissions (a world is single-tenant by construction), symlinks, env
   inheritance from the host (secrets live in the Secret plane and never
   enter a guest), network in the shell (a `:job`'s `http.get` is the one
   granted exception, and it is Lua's, not the shell's).

## The phases

**S1 — conditionals + status.** `test`/`[` with the file/string/integer
predicates over the VFS; `$?`; exit codes threaded (`if grep -c x f.txt`
already works — `if [ -f f.txt ]` joins it); `sh()` returns `out, rc` to
Lua. Exit: an authored script branches on a file's existence and a
computation's result without leaving the shell.

**S2 — substitution + arithmetic.** `$(...)` nested, `$((...))` with
`+ - * / %` and comparisons; both compose with S1 (`if [ $(wc -l x) -gt 3 ]`).
Exit: the idiom sentence runs.

**S3 — the coreutils sweep.** The list in (3), each with usage text and its
own tests; grep/-E brings real regex to the shell. Exit: the shelf's refusal
message is over 30 tools long and every one has `help` text.

**S4 — cwd + fs semantics.** Prefix-relative resolution everywhere (file.*,
tools, globs, redirects), cp/stat/du, `**`. Exit: a script `cd`s into a
"directory," works relatively, and nothing anywhere touched a host path.

**S5 — streams + caps.** stderr, `2>`, `2>&1`, tee across both; output caps
(default ~4MB per run, configurable) refusing with the repair. Exit: a
deliberately-noisy guest gets a named refusal, never a heap kill, and errors
route separately from data.

**S6 — the conformance gate: differential against real bash.** The
tiny-lasers idea kept from the detour: for the DOCUMENTED subset, run the
same script under `/bin/bash` (files materialized to a tmpdir) and under
`Blazie.Lua.Shell` (files as the map) and assert byte-identical stdout.
Excluded-by-default tag (`:bash`), a corpus that grows with every phase, and
a SHELLSPEC.md that states exactly what the subset is — the sandbox's
contract, written down. Exit: the corpus passes both engines; divergence is
either a bug fixed or a subset line documented.

**S7 — fence hardening for the grown surface.** Extend `lua_fence_test`'s
kong-style checklist to the shell: no tool reaches a host path (property
test over hostile keys), no env leakage, caps enforced, `date`/`whoami`
deterministic per `at`. The tripwire grows with the surface, so a future
tool cannot quietly widen the fence.

## Doctrine constraints that bind every phase

- The shell stays a **pure function** — `run(line, files, opts) → {out, err,
  rc, files}` internally; no process dict, no side channel.
- Every tool is an Elixir function; NO new deps for tool implementations
  (`:crypto` and `Regex` are stdlib).
- Determinism: same line + same files + same `at` → same output, forever.
- Absence over prohibition: what the sandbox lacks, it lacks structurally,
  and the refusal names the repair.
- The behavior contract (`lua_shell_test`) only ever GROWS — the engine-swap
  proof depended on it, and the next swap (should one ever come) will too.

## Verdicts

*(appended per phase as they land)*

**S1–S5 (2026-08-15): PASS.** One coherent build, landed against the growing
contract (52 shell tests green; the pre-existing 21 passed unchanged
throughout). S1: `test`/`[` with file/string/integer predicates, `$?`, exit
codes threaded, and `sh()` grew Lua multi-return — `local out, rc, err =
sh(...)` — backward-compatibly. S2: `$(...)` substitution with real subshell
semantics (file writes persist, var changes do not — tested) and `$((...))`
arithmetic with bare-name resolution; the idiom sentence runs: `if [ $(wc -l
n.txt) -gt 3 ]`. S3: the coreutils sweep — tr, cut, nl, tac, paste, tee,
diff (LCS), find, xargs, basename, dirname, sha256, grep `-n`/`-E`, sort
`-n`/`-r`, uniq `-c`, wc `-w`/`-c`, head/tail `-n` — every tool with a
`help` usage line, and `date`/`whoami` deterministic from `at`/`by`. S4:
`cd`/`pwd` as a PREFIX over the flat map (`..`/`/` fold; redirects, globs
and every tool resolve under it; `**` crosses slashes) plus cp/stat/du. S5:
stderr as a real second stream (`2>`, `2>>`, `2>&1` applied per-segment,
where it stands in the pipe), `run_full/3` with separated streams, and the
output cap: a flooding guest gets rc 141 and a refusal naming the repair,
never a heap kill — while legacy `run/2` still merges streams, keeping the
old contract exactly. Suite 957 green. (A full disk mid-verification
produced 32 phantom failures — all storage tests writing tmp files; all
vanished with the space. Noted because a lesser suite would have eaten a
false regression.)
