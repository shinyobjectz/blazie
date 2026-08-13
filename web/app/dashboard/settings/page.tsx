"use client"

import { KeyRound } from "lucide-react"
import { useRouter } from "next/navigation"

import { Detail, Nothing, PageHead } from "@/components/dashboard/page-shell"
import { Copyable } from "@/components/ui/copyable"
import { clusterUrl, forgetToken } from "@/lib/blazie"

import { useCluster } from "../cluster"

/**
 * What this caller is and how far it reaches.
 *
 * There is nothing to edit here, and that is the design rather than a missing
 * feature: authorization is a list of ledgers a caller may name, written on the
 * cluster. No page that a token can reach may widen the reach of that token.
 */
export default function Settings() {
  const router = useRouter()
  const { who } = useCluster()

  return (
    <>
      <PageHead title="settings">
        a caller is a fingerprint and a list of ledgers. that list is the whole of
        its reach — not row rules, not predicates, and readable in one glance,
        which is the point of it being a list.
      </PageHead>

      <div className="flex flex-wrap items-start gap-x-14 gap-y-7">
        <Detail label="github">
          <p className="font-mono py-2 text-sm text-white/85">
            {who.login ?? "not recorded"}
          </p>
        </Detail>

        <Detail label="caller">
          <Copyable text={who.caller} label={short(who.caller)} />
        </Detail>

        <Detail label="cluster">
          <Copyable text={clusterUrl} />
        </Detail>
      </div>

      <p className="mt-5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        the caller is a sha256 of the token, not the token — the cluster stores
        the fingerprint so that a leak of what it holds is not a leak of what you
        hold. it is also what a grant is written against, so it is the value to
        quote when asking for one.
      </p>

      <section className="mt-14">
        <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
          ledgers this caller may name
        </h2>
        <p className="mb-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
          naming one it was not granted is refused at the door, before anything
          is read. there is no partial answer and nothing underneath to filter.
        </p>

        {who.ledgers.length === 0 ? (
          <Nothing icon={KeyRound} title="granted nothing">
            a caller is granted, never registered — signing in proves who you
            are and grants nothing on its own. quote the caller fingerprint
            above to whoever runs this cluster.
          </Nothing>
        ) : (
          <div className="overflow-hidden rounded-lg border border-border">
            {who.ledgers.map((ledger) => (
              <p
                key={ledger}
                className="font-mono border-b border-border px-4 py-3 text-sm text-white/85 last:border-b-0"
              >
                {ledger}
              </p>
            ))}
          </div>
        )}
      </section>

      <section className="mt-14 border-t border-border pt-8">
        <button
          type="button"
          onClick={() => {
            forgetToken()
            router.replace("/login")
          }}
          className="rounded-md border border-border px-4 py-2 text-sm text-white transition-colors hover:border-flame/50 hover:bg-flame/5"
        >
          forget this token
        </button>
        <p className="mt-3 max-w-xl text-sm leading-relaxed text-muted-foreground">
          this browser stops holding it. the cluster is not told — a token is
          revoked where grants are written, not from the thing holding it.
        </p>
      </section>
    </>
  )
}

/** A sha256 fingerprint is 64 characters. Show the ends, copy the whole. */
function short(fingerprint: string) {
  return fingerprint.length > 20
    ? `${fingerprint.slice(0, 10)}…${fingerprint.slice(-6)}`
    : fingerprint
}
