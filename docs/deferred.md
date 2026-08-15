# Deferred work, with the reasoning kept

Not tickets — things measured or built far enough to know they can wait, each
with why and what would un-defer it. Recorded here so the reasoning does not
live only in a moduledoc somebody has to stumble on.

## The paged store's postings spill to disk (the LSM half)

`Store.Paged` holds its offset-and-postings index in memory, so the index
still grows with the log even though the facts no longer do. **Why it waits:**
the urgent problem — residency tracking file size — is solved; a world holds
its working set and seeks for the rest. The index is a fraction of the data
(offsets and transaction-number lists, not facts), so it buys headroom that a
readings-scale world can also get by sharding on a time window (topology rule
2). **What un-defers it:** a single world whose index alone exceeds a node's
RAM — measured, not guessed. The seam is ready: it is another `Store`
behaviour implementation, and `Store.Paged`'s moduledoc names it.

## A real UpCloud dispatch vendor module

`Blazie.Dispatch` proves the fire-and-ack protocol and the one-world
write-back credential against `Dispatch.Local` (this node as the vendor).
**Why it waits:** a remote vendor is a file the seam already describes, and
`Local` is the honest single-node answer until the compute genuinely needs to
leave the node. **What un-defers it:** a workload where the agent's work must
run somewhere the facts do not — then `Dispatch.UpCloud` is `launch/2` over
the provisioning path the control plane already has, and the credential shape
is unchanged.

## The Limit door in front of job HTTP

`Blazie.Limit` gates every `Model` call — the account-wide door the customer-
zero doc said must be owned. **Why it waits:** a Lua job's `http.get` is the
other traffic that could hit a vendor account, and today jobs are declared by
operators rather than by tenants, so the contention `Limit` exists to arbitrate
is not there yet. **What un-defers it:** tenant-authored jobs that reach
vendors (the S2 adoption epic brings sweeps, which fetch) — then the job-HTTP
door reads the same `Limit` server `Model` does, one bucket per vendor, and
the seam is the existing `ask/4`.

## Python client parity for share/drop

The Elixir client grew `share/3` and `drop/2` for rotation; the Python client
did not. **Why it waits:** rotation is operator and control-plane work, not
agent work, and the Python client is the Harness's durable checkpoint path —
an agent inside a sandbox has no business rotating credentials. **What
un-defers it:** a tenant surface that lets a tenant rotate its own Studio
token from Python — at which point the two verbs are a ten-line addition
mirroring the Elixir ones.
