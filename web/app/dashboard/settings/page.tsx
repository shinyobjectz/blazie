"use client"

import { KeyRound } from "lucide-react"
import { useRouter } from "next/navigation"

import { Detail, Nothing, PageHead } from "@/components/dashboard/page-shell"
import { Copyable } from "@/components/ui/copyable"
import { signOut } from "@/lib/blazie"

import { useCluster } from "../cluster"

/**
 * What this caller is and how far it reaches.
 *
 * There is nothing to edit here, and that is the design rather than a missing
 * feature: authorization is a list of worlds a caller may name, written on the
 * cluster. No page that a token can reach may widen the reach of that token.
 */
export default function Settings() {
  const router = useRouter()
  const { who, worlds, cluster } = useCluster()

  return (
    <>
      <PageHead title="settings">
        a caller is a fingerprint and a list of worlds. that list is the whole of
        its reach — not row rules, not predicates, and readable in one glance,
        which is the point of it being a list.
      </PageHead>

      <div className="flex flex-wrap items-start gap-x-14 gap-y-7">
        <Detail label="github">
          <p className="font-mono py-2 text-sm text-white/85">
            {who.login ?? "not recorded"}
          </p>
        </Detail>

        <Detail label="cluster">
          <p className="font-mono py-2 text-sm text-white/85">
            {cluster?.name ?? "none chosen"}
          </p>
        </Detail>

        <Detail label="address">
          <Copyable text={cluster?.address ?? "—"} />
        </Detail>
      </div>

      <p className="mt-5 max-w-2xl text-sm leading-relaxed text-muted-foreground">
        the token this cluster answers to is not shown here and is not held by
        this browser. it lives in the control plane, which is why a cluster needs
        no port open to the internet — the only thing that can present it is the
        thing that made it.
      </p>

      <section className="mt-14">
        <h2 className="mb-2 text-lg font-medium tracking-tight text-white">
          worlds this caller may name
        </h2>
        <p className="mb-6 max-w-2xl text-sm leading-relaxed text-muted-foreground">
          naming one it was not granted is refused at the door, before anything
          is read. there is no partial answer and nothing underneath to filter.
        </p>

        {worlds.length === 0 ? (
          <Nothing icon={KeyRound} title="granted nothing">
            a caller is granted, never registered — signing in proves who you
            are and grants nothing on its own. quote the caller fingerprint
            above to whoever runs this cluster.
          </Nothing>
        ) : (
          <div className="overflow-hidden rounded-lg border border-border">
            {worlds.map((world) => (
              <p
                key={world}
                className="font-mono border-b border-border px-4 py-3 text-sm text-white/85 last:border-b-0"
              >
                {world}
              </p>
            ))}
          </div>
        )}
      </section>

      <section className="mt-14 border-t border-border pt-8">
        <button
          type="button"
          onClick={async () => {
            await signOut()
            router.refresh()
          }}
          className="rounded-md border border-border px-4 py-2 text-sm text-white transition-colors hover:border-flame/50 hover:bg-flame/5"
        >
          sign out
        </button>
        <p className="mt-3 max-w-xl text-sm leading-relaxed text-muted-foreground">
          the session is given back and this browser holds nothing. your clusters
          keep running — signing out of a console is not a thing that should be
          able to stop a database.
        </p>
      </section>
    </>
  )
}
