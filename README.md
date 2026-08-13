# Lazy River

An immutable fact-log database. Seven words:

**fact** · **attribute** · **ledger** · **snapshot** · **formula** · **symbol** · **job**

Facts accumulate in ledgers. A snapshot is one or more ledgers read at a
transaction, and it is a value — the answer at a named snapshot is the same
answer forever. Formulas declare facts that follow from facts and say what,
never when. Jobs are the only thing that reaches the outside world, and the
only thing a schedule can attach to.

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
    ask       name, question -> an answer
    watch     name, question -> answers as the name advances   (websocket)
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
| `BACKUP_BUCKET` | With `BACKUP_ENDPOINT`, `BACKUP_ACCESS_KEY_ID`, `BACKUP_SECRET_ACCESS_KEY`, and optionally `BACKUP_REGION` and `BACKUP_PREFIX`. |
| `BACKUP_DIR` | A directory to copy into instead — a second disk, or a test. |
| `BACKUP_EVERY` | Seconds between runs. Defaults to 900. |

Without `LEDGER_DIR` a ledger is in memory, which is right for a test and
wrong for everything else. Without `KMS_KEY` the keyring keeps its keys in a
file under a master from the environment — right for development, wrong in
front of real users, because a file can come back from a restore and erasure
has to be irreversible.

## Erasure

A fact's answer is sealed under a key belonging to whoever its entity belongs
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

## Deployment

A two-stage image: build with the toolchain, ship without it. Facts and keys
live on a mounted volume, never in the image — a container is replaced on
every deploy and a ledger is not.

CI runs the gate a machine that has never seen the repo can run: formatting,
warnings-as-errors, the suite, the SIGKILL crash tests, and the vocabulary
lint. The deploy workflow builds a release, boots it, and refuses to ship one
that answers anything but `401` to an unauthenticated request.
