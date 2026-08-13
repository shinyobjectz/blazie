# blazie

**The backend agents run on.**

Durable memory that records where every fact came from, a graph nobody had to
model, sandboxes to run agent code in, and one line that touches the outside
world.

- **Memory that keeps being wrong.** Nothing is rewritten. A correction is a
  later fact and the earlier one still answers where it was written, so "what
  did it believe on Tuesday" is a question rather than a log search.
- **Every fact knows what made it.** Provenance is a slot in the row, not a
  convention: an answer either came from outside or names the code that
  produced it, and there is no third option to forget.
- **A graph you did not have to model.** An edge is a fact whose value is
  another id. No node type, no edge type, no second store to keep in step.
- **Code runs where it cannot reach.** Agent code runs in Lua (Luerl, inside
  the BEAM) or WebAssembly with no clock, no network and no filesystem.
  Isolation is the absence of anything to reach, so there is no rule to
  misconfigure.
- **One line touches the outside world.** A job is the only thing handed the
  network and the only thing a schedule attaches to, so what an agent did is a
  list you can read, with its failures on it.
- **It tells you when something changed.** `watch` is the same question asked
  again as facts land, not a second mechanism.

Fourteen words, and nothing else:

**fact** · **attribute** · **ledger** · **snapshot** · **formula** · **symbol**
· **job** — seven things it is made of.

**open** · **ask** · **write** · **watch** — four things you do to them.

A fact's **value**, a snapshot's **name**, and the **question** an ask puts to
one. The authoring language is Lua, so the grammar is Lua's twenty-two keywords
and none of it is ours to teach.

## Signing in

GitHub OAuth, both ways round. A browser gets a redirect and a code; a terminal
gets a device flow. Both end at the same door, so the rule about who may hold a
token is written once.

    POST /auth/github        code            -> token
    POST /auth/device                        -> a code a human types
    POST /auth/device/token  device_code     -> token, once they have
    GET  /me                                 -> who you are, and what you may name

`GITHUB_LOGINS` is the whole access policy. An empty one admits nobody, which
is the right failure for a setting somebody forgot.

The vocabulary lives in `.monty/ontology.db` and is enforced by `just check`.
There are no design documents: claims are doctrine in that database, choices
are in the commit that made them, and mechanism is in the moduledoc beside the
code. A document describing the system is a second source that drifts.

## Running it

    just check          # what must pass before a commit
    just test
    mix test --include crash    # a real process, SIGKILL'd mid-write
    mix test --include load     # what it costs at size
    mix test --include gcp      # talks to Cloud KMS

## The four operations

    open      which ledgers  -> a snapshot name
    ask       name, question -> facts
    watch     name, question -> facts again as the name advances   (websocket)
    write     name, facts    -> a new name

A caller holds the snapshot's *name*, never its bytes. Because an answer at a
name never changes, a client caches on `{name, question}` and never
invalidates — there is no cache-coherence protocol because there is nothing to
cohere.

Authorization is which ledgers a caller may name. Not row rules, not
predicates. Every operation that names a ledger is checked, because a snapshot
name is a plain map and a caller can write one by hand.

## Configuration

Everything that can differ between deployments is read at boot, so one
artefact runs anywhere and carries no secret.

| Variable | Meaning |
|---|---|
| `SECRET_KEY_BASE` | Required in production. The release refuses to boot without it. |
| `PORT` | Defaults to 4000. |
| `LEDGER_DIR` | Where facts live. **Must be persistent storage.** |
| `LEDGER_SYNC` | `true` fsyncs every transaction: durable and slow. |
| `KEY_DIR` | Where key-encryption keys live. **Must be persistent storage.** |
| `KMS_KEY` | A Cloud KMS key. Setting it selects the KMS-backed keyring. |
| `GOOGLE_APPLICATION_CREDENTIALS` | A service account key, for the KMS. |
| `GITHUB_CLIENT_ID` | With `GITHUB_CLIENT_SECRET`. Absent means nobody can sign in. |
| `GITHUB_LOGINS` | Comma-separated logins allowed a token. **Empty admits nobody.** |
| `BACKUP_BUCKET` | With `BACKUP_ENDPOINT`, `BACKUP_ACCESS_KEY_ID`, `BACKUP_SECRET_ACCESS_KEY`, and optionally `BACKUP_REGION` and `BACKUP_PREFIX`. |
| `BACKUP_DIR` | A directory to copy into instead — a second disk, or a test. |
| `BACKUP_EVERY` | Seconds between runs. Defaults to 900. |
| `DRILL_EVERY` | Seconds between restore drills. Defaults to 21600 — six hours. `0` turns the drill off. |
| `DRILL_DIR` | Where a drill stages what it restores. Defaults to the container's temp space, and must never be `LEDGER_DIR`. |
| `DRILL_MAX_BYTES` | The largest ledger a drill will pull down. Defaults to 512 MB. |

Without `LEDGER_DIR` a ledger is in memory, which is right for a test and
wrong for everything else. Without `KMS_KEY` the keyring keeps its keys in a
file under a master from the environment — right for development, wrong in
front of real users, because a file can come back from a restore and erasure
has to be irreversible.

## Erasure

A fact's value is sealed under a key belonging to whoever its entity belongs
to. Erasing destroys that key: the bytes stay and become noise, no segment is
rewritten, and an old name still answers — it answers `:erased`.

Three tiers, because a KMS key version costs about six cents a month and one
per subject prices itself out at exactly the scale erasure starts to matter. A
single KMS key wraps a master, the master protects per-subject keys, and a
per-fact data key wrapped by the subject key travels in the fact.

Erasure also writes a tombstone — an ordinary fact — and the keyring
reconciles against those whenever it opens, so a key store restored from
before an erasure is corrected rather than trusted.

The one thing it cannot do is stated plainly: a fact written before its
subject was declared is not covered. Subject is decided at write time or not
at all.

## Backup

Copying the facts somewhere else is a **job**, because it reaches outside. That
is not a technicality: it means a backup has a cadence, writes what it copied
as ordinary facts, writes a failure as an ordinary fact, and answers "when did
this last succeed" with `Job.last_run/2` like anything else. None of that had
to be built.

A ledger is append-only, so a run copies the byte range it has not copied yet
and names the segment for the range it holds. The cost of a backup is what
changed rather than what exists, which is what lets the cadence be minutes.
A copy stops at the last complete record, because the tail of a live log may be
half-written and half a record is not a fact.

Checkpoints are not copied — they are derived, and opening without one is
correct and merely slower. Keys are, whole, every run: facts without them are
noise. What lands in the bucket is already encrypted under a master the KMS
holds, so whoever owns the bucket cannot open it, and an old key store cannot
resurrect an erased subject because the keyring reconciles against erasure
tombstones every time it opens.

    Backup.run(...)       copy what has not been copied
    Backup.verify(...)    what the target holds against what is here
    Backup.restore(...)   pull it back — refuses to land on top of live facts

`verify` compares *readable* local bytes, and what a target holds is the
contiguous run from zero rather than the highest segment boundary. Those are
the same number until a put fails after a later one succeeds, and then the
difference is a backup claiming bytes it cannot give back. Stopping at the hole
costs a re-copy and heals it.

Restoring refuses rather than overwrites, and names what is in the way. Pass
`only: :keys` or `only: :ledgers` to restore one half — losing a key store
while the facts are fine is a real thing, and not the same operation as
restoring a machine.

Two limits, stated rather than hidden. `verify` always names `$backup` itself,
because a run copies and *then* records what it copied; the next run catches it
up. And no target can delete, but the credentials a deployment holds usually
can — so versioning and a retention window belong on the bucket, out of reach
of a node that has been taken over.

## The restore drill

A backup is only ever proven by the last restore, and a restore a human did once
by hand is a rumour with a timestamp. So the restore is a job too: every six
hours it pulls one ledger back out of the backup, opens it, asks it for every
fact it holds, and asks the live ledger the same question. Equal answers, or the
run fails and the failure is a fact.

The comparison is made at the *restored* ledger's transaction, never the live
one's. A backup is always a prefix — a run copies and the live ledger goes on
being written to — so the honest question is whether the copy answers at
transaction *n* exactly what the original answers there. That is a snapshot, and
an answer at a snapshot is the same answer forever, which is why this can be an
equality rather than a tolerance. Byte counts are what `verify` compares, and a
broken restore has plenty of those.

One ledger per run, and the one picked is the one drilled longest ago, read out
of the drill's own past facts — so a redeploy resumes the rotation and there is
no state to reconcile. With *n* ledgers each is proven inside *n* cadences.
Restoring everything every cadence would cost more than the backup it checks,
every time, and a check nobody can afford is a check somebody turns off. Only the
sampled ledger's segments cross the wire: the drill hands `Backup.restore/1` a
narrowed view of the target rather than a second restore path of its own.

It stages into a scratch directory, restores `only: :ledgers`, opens the copy
under a name of its own, and removes both the directory and the name on the way
out whether it proved anything or raised. Opening the copy under the live name
would hand back the live ledger — `Ledger.open/2` does that by design — and the
drill would compare it against itself and pass forever.

    proven_at          when we last proved we could restore
    drilled            which ledger this run gave back
    proven_tx          the transaction it was proven to
    compared_facts     how many facts had to agree
    too_big            a ledger over the ceiling, skipped and named

Four limits, stated rather than hidden. Only ledgers that are **open** are
drilled, because comparing means asking the live one and a drill must never
start a live ledger. A ledger over `DRILL_MAX_BYTES` is skipped and named rather
than passed over. **Keys are not restored** — pointing the keyring at a restored
key store would mean swapping a live global for the length of a drill, and both
sides of the comparison reveal through the same keyring anyway. And a run with
nothing to drill records zero rather than failing: `proven_at` simply stops
advancing, which is the thing to watch.

## Deployment

A two-stage image: build with the toolchain, ship without it. Facts and keys
live on a mounted volume, never in the image — a container is replaced on
every deploy and a ledger is not.

CI runs the gate a machine that has never seen the repo can run: formatting,
warnings-as-errors, the suite, the SIGKILL crash tests, and the vocabulary
lint. The deploy workflow builds a release, boots it, and refuses to ship one
that answers anything but `401` to an unauthenticated request.
