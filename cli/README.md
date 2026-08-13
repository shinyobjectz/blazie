# blazie, from the terminal

The four operations — **open**, **ask**, **write**, **watch** — and the two
commands that get you a token to do them with.

    blazie login
    blazie write tenant-7 1 height 180
    blazie ask tenant-7 --attribute height
    blazie watch tenant-7

## Why Go

One binary, no runtime, nothing to fetch — which is what `brew install blazie`
has to mean. Go cross-compiles to every platform from any of them, and the
whole CLI is standard library: no framework, no HTTP client, no websocket
package, no dependency file to audit. `go build` works offline on a machine
that has never seen this repo.

The websocket `watch` needs is written by hand in `ws.go` — about two hundred
lines of RFC 6455, being the handshake, text frames, masking and ping. That is
a real cost and it is stated rather than buried: it is there because a
dependency for that much protocol is a supply chain and a version to track, in
a binary whose selling point is having neither.

## Installing

    go build -o blazie .          # anywhere with Go 1.24 or later
    go install github.com/shinyobjectz/blazie/cli@latest

Cross-compiling needs nothing beyond the environment:

    GOOS=linux  GOARCH=amd64 go build -o blazie-linux-amd64 .
    GOOS=darwin GOARCH=arm64 go build -o blazie-darwin-arm64 .

There is no Homebrew formula yet. When there is, it pours one of those files.

## Signing in

`blazie login` runs the device flow. It prints a code big enough to read off a
laptop while typing it into a phone, offers to open the verification page, and
then waits — honouring the cadence the node asks for, including a `slow_down`
mid-flow.

    blazie login
    blazie login --url https://blazie.example      # and remember that node
    blazie login --no-browser                      # never offer to open one

The token lands in `~/.config/blazie/config.json` at mode **0600**, written to
a temp file and renamed so an interrupted write leaves the old token rather
than half of a new one. `blazie config` will tell you it is there and will
never print it.

`blazie logout` forgets the token here. It does not revoke it: a bearer
credential is the caller until the node is told otherwise, and this CLI has no
way to tell it.

## The operations

    blazie ledger ls                          the ledgers this token may name
    blazie ask <ledger>... [pattern]          open, then put a question to the snapshot
    blazie write <ledger> <id> <attr> <value> one fact
    blazie watch <ledger>... [pattern]        the same question as facts land

`ask` and `watch` take more than one ledger, because a snapshot is one or more
ledgers read at a transaction.

A pattern is any of `--id`, `--attribute`, `--value` and `--by`; what you do
not name may be anything. `--by` matches what a formula or job produced, and
there is deliberately no `--by` on `write`: a fact written from a client came
from outside and names no formula. The node refuses a claimed `by` rather than
dropping it, so pretending otherwise would only get you a refusal one layer
later.

Both print the snapshot name alongside the answer, because that is the point of
the name — ask at it again and you get the same facts forever.

    $ blazie ask tenant-7 --attribute height
    tenant-7@6

    id  attribute  value  tx  by
    1   height     180    2   —
    7   height     195    4   —

    2 facts

A `—` in the `by` column means the fact came from outside. Nothing is
truncated: a value cut off at the terminal width is a value you cannot act on.
Use `--json` when you want to shape it.

### Values off a command line

A command line has only strings on it and a fact's value is any JSON, so
something has to guess. The guess is **if it parses as JSON, it is JSON**:

    blazie write tenant-7 1 height 180        # the number 180
    blazie write tenant-7 1 height '"180"'    # the string "180"
    blazie write tenant-7 1 version 1.20 --string   # the string "1.20"

`--string` forces both the id and the value to be taken as text. Ids follow the
same rule, narrowed: a whole number is a number, anything else is a string,
because an id travels as a number or a string and nothing else.

An id that begins with a dash goes after `--`:

    blazie ask tenant-7 -- -7

### watch

`watch` is a Phoenix channel over a websocket. Two things are worth knowing:

- **It answers on change, not at join.** A fresh `blazie watch` is silent until
  a fact lands inside what the question read. Silence means nothing has
  changed, not that the socket is broken — the output says so at join.
- **Each answer is the whole answer**, not a delta, carrying the snapshot name
  it was answered at. That is what "the same question asked again" means here.

With `--json` it prints one object per line, so a shell can read answers as
they arrive rather than waiting for a document that never ends.

    blazie watch tenant-7 --attribute height --json | while read -r line; do ... done

It does **not** reconnect. If the socket drops the command exits with a repair
saying so, and nothing is lost that an `ask` cannot recover.

The token travels in the query string, because a websocket handshake cannot
carry a header the way a request can and that is where Phoenix reads connect
params from. It can therefore reach a proxy's access log, which is a real cost
of using `watch` over a proxy you do not control.

## Refusals

Every refusal from the node is a problem and a **repair**, and the repair says
how to comply. This CLI prints it on its own line and never swallows it:

    $ blazie ask nope
    blazie: refused — not_granted (403)

        This caller may not name "nope". Grant it, or name only what it holds.

With `--json` you get the node's own envelope on stderr:

    {"error": {"problem": "not_granted", "repair": "This caller may not name ..."}}

Exit codes: **0** fine, **1** refused, **2** the command line was wrong. Ctrl-C
is 0 — stopping a watch is not a failure.

## Configuration

| | |
|---|---|
| `--url` | the node, beating everything else |
| `BLAZIE_URL` | the node, beating the config file |
| `BLAZIE_TOKEN` | a token, used in preference to the stored one |
| `BLAZIE_CONFIG` | the config file, instead of `~/.config/blazie/config.json` |
| `XDG_CONFIG_HOME` | where `blazie/config.json` lives |
| `NO_COLOR` | no emphasis, ever |

`blazie config` says which of those is in force, because the commonest
confusion with a CLI that has both a flag and an environment variable is not
knowing which one won.

`--url` and `--json` may come before the command or after it. Everything else
is a flag on a command and belongs after it.

There is no flag for the token. A token on a command line ends up in shell
history and in `ps`.

## Tests

    go test ./...
    go test -race ./...

Nothing in the suite opens a socket. The HTTP layer is an interface a fake
answers, and the clock the device flow sleeps against is injected, so a
fifteen-minute polling loop runs in no time at all. What is pinned:

- the device-flow cadence, including a `slow_down` mid-flow, a `null` interval
  meaning "keep going as you are", and expiry
- the config file's mode, under a permissive umask, and that a malformed one
  refuses by name rather than starting over
- that a repair survives to the terminal and to `--json`, wrapped but whole
- the channel's five-slot message shape, and that a refused join keeps its
  repair
- websocket framing: masking, the three length widths, continuation
  reassembly, pings, and the RFC's worked accept-key example

The suite proves the client against its own understanding of the protocol, so
it was also driven against a running node: sign-in, all four operations,
refusals, and a live channel push. That is not automated here — it needs a node
with a ledger and a grant — and is the gap to close first.

## What is not done

- **No reconnect on `watch`.** A dropped socket exits with a repair. A retry
  loop that hides a node going away is worse than a command that says so.
- **No Homebrew formula, and no signed or notarised binaries.** `go build`
  produces the artefact; nothing packages it yet.
- **No `--url` used to talk to two nodes at once.** One config, one token.
- **No pagination on `ask`.** Everything the question answers is printed.
- **The token is a file, not a keychain.** Anything running as this user can
  read it. Mode 0600 keeps out other users and nothing more. A keychain differs
  on every platform and this has to work the same over SSH and in a container.
- **The device flow is the only way in.** The browser flow at `/auth/github`
  exists on the node; nothing here uses it.
