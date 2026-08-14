# Credential rotation runbook

*Why this exists: bla-gsv0. Several credentials passed through a chat window
in plaintext — the UpCloud API token, both Cloudflare API tokens, the R2
access keys, and the GitHub client secret. None is known to have leaked; that
is not the same as none having leaked, so all are rotated.*

## Two halves, and which is proven

**The cluster-token half is proven, live.** On 2026-08-14 a throwaway cluster's
founding token was rotated end to end against the real control plane: the elder
shared its world with a successor's fingerprint (the successor's secret never
crossed the wire), the successor answered under its own token, the elder
dropped its grant and was refused — the full grace-window rotation, cluster
side. The console sequencer (`web/lib/control/rotate.ts`, `POST
/api/clusters/[id]/rotate`) swaps the record only after the successor answers,
so a failed rotation leaves both tokens live and the record unchanged.

**The vendor-secret half is a dashboard afternoon**, below. It is deliberately
not automated: each new token must be generated in its vendor's console (there
is no headless path that also proves the new token's *scope* is right), and a
wrong scope silently strands the live cluster's provisioning. Do it with eyes
on it, verifying between each.

## The six secrets, in safe order

The deployment holds them as Pages secrets (`wrangler pages secret list
--project-name blazie`). Rotate least-blast-radius first, verify, then the next.
The install command never puts the value in shell scrollback:

    # paste the new value at the prompt; it is not echoed and not in history
    npx wrangler pages secret put <NAME> --project-name blazie

### 1. GITHUB_CLIENT_SECRET — no cluster depends on it

Only the console's sign-in uses it. Rotating it cannot touch a running cluster.

- GitHub → the OAuth app's settings → **Generate a new client secret**.
- `wrangler pages secret put GITHUB_CLIENT_SECRET`.
- Verify: sign out and back in through the console. Then delete the old secret
  in GitHub.

### 2. BACKUP_ACCESS_KEY_ID + BACKUP_SECRET_ACCESS_KEY — R2, backup path only

A running cluster holds its OWN R2 credentials in its env (set at provision),
so rotating the control plane's pair affects only backups a NEW cluster would
be given. Existing clusters keep backing up under the keys they were born with
until they are themselves reprovisioned or rotated.

- Cloudflare dashboard → R2 → **Manage API Tokens** → create a new token scoped
  to the backup bucket → note both the access key id and secret.
- `wrangler pages secret put BACKUP_ACCESS_KEY_ID` then
  `... BACKUP_SECRET_ACCESS_KEY`.
- Verify: open a throwaway cluster, confirm its first backup lands (the drill
  will prove a restore), then destroy it. Then revoke the old R2 token.

### 3. CLOUDFLARE_DNS_TOKEN — the zone's DNS record only

Used when a cluster claims its `<name>.blazie.dev` record. A wrong scope here
fails the DNS step of the NEXT provision, not a running cluster.

- Cloudflare → My Profile → API Tokens → the DNS token → **Roll**, or create a
  new one with `Zone:DNS:Edit` on the cluster zone.
- `wrangler pages secret put CLOUDFLARE_DNS_TOKEN`.
- Verify: open a throwaway cluster (its DNS record must appear), destroy it.

### 4. CLOUDFLARE_API_TOKEN — tunnels; provisioning depends on it

This is the one a running cluster's FUTURE operations lean on (tunnel create
and delete). Needs `Account:Cloudflare Tunnel:Edit`, and `Zone:DNS:Edit` too
unless the DNS token above carries it.

- Cloudflare → API Tokens → **Roll** the existing token (keeps its scope), which
  is safer than a fresh one because a fresh one is where scope drift creeps in.
- `wrangler pages secret put CLOUDFLARE_API_TOKEN`.
- Verify: open a throwaway cluster (tunnel must establish — watch `opening`
  reach `tunnelled`), then destroy it (tunnel must delete). Only after a clean
  open+destroy is this token confirmed.

### 5. UPCLOUD_TOKEN — every machine operation

Rotate last, because a wrong value makes `open_cluster` fail immediately and
`remove_cluster` unable to destroy — the most visible break. UpCloud tokens are
account-scoped, so there is no scope to get wrong, only the value.

- UpCloud → People → your account → **API access** → rotate/regenerate the
  token (or create a new sub-account token with server + network permissions).
- `wrangler pages secret put UPCLOUD_TOKEN`.
- Verify: `open_cluster` a throwaway, watch it reach `serving`, `remove_cluster`
  it. Then invalidate the old token in UpCloud.

## After all five

- `wrangler pages secret list --project-name blazie` — confirm all present.
- Open one throwaway cluster end to end and destroy it: that single lifecycle
  exercises every rotated secret at once (UpCloud makes the machine, both
  Cloudflare tokens make the DNS record and tunnel, R2 takes its first backup).
- The measured cost of that verification: ~12 minutes to reachable (see
  customer-zero.md — the wall is UpCloud boot, not anything rotated here), plus
  a couple of minutes to drain and destroy.

## What was left live for this session

An operator grant (`operator-adoption`, open+remove) was minted to drive the
provisioning proof above. Revoke it when the adoption work that needs it is
done — it is a live credential that can spend money.
