"use client"

import { Globe, LogOut, Server, UserRound } from "lucide-react"
import { useRouter } from "next/navigation"

import { Grants } from "@/components/dashboard/grants"
import { PageHead } from "@/components/dashboard/page-shell"
import { Fact, Section } from "@/components/dashboard/section"
import { Copyable } from "@/components/ui/copyable"
import { WorldAvatar } from "@/components/ui/world-avatar"
import { signOut } from "@/lib/blazie"

import { useCluster } from "../cluster"

/**
 * Who you are, what the console is pointed at, and what may act for you.
 *
 * Four questions, and until this had sections they were one column of prose in
 * which the only thing telling them apart was how far down you had scrolled.
 * They are also asked in an order: you, then the cluster you are looking at,
 * then what your token may name on it, then what an agent may do with all of
 * that. Signing out is last because it is the one that ends the page.
 *
 * Most of this is not editable, and that is the design rather than a gap.
 * Authorization is a list of worlds a caller may name, written on the cluster —
 * no page a token can reach may widen the reach of that token.
 */
export default function Settings() {
  const router = useRouter()
  const { who, worlds, cluster } = useCluster()

  return (
    <>
      <PageHead title="settings">
        who you are, what this console is pointed at, and what may act on your
        behalf.
      </PageHead>

      <div className="mt-10 space-y-12">
        <Section
          icon={UserRound}
          title="you"
          says="github says who you are. what you hold is kept here rather than on any cluster, which is why this works before you have opened one."
        >
          <div className="max-w-xl">
            <Fact label="github">
              <span className="font-mono">{who.login ?? "not recorded"}</span>
            </Fact>
            <Fact label="may open">
              {who.can.open_clusters
                ? "clusters, on this deployment"
                : "nothing — this deployment has no credentials to make a machine with"}
            </Fact>
          </div>
        </Section>

        <Section
          icon={Server}
          title="this cluster"
          says="the token it answers to is not shown here and is not held by this browser. it lives in the control plane, which is why a cluster needs no port open to the internet — the only thing that can present it is the thing that made it."
        >
          <div className="max-w-xl">
            <Fact label="name">
              <span className="font-mono">{cluster?.name ?? "none chosen"}</span>
            </Fact>
            <Fact label="address">
              <Copyable text={cluster?.address ?? "—"} />
            </Fact>
            {cluster?.host ? (
              <Fact label="machine">
                <span className="font-mono">
                  {cluster.host.plan} · {cluster.host.zone}
                </span>
              </Fact>
            ) : null}
          </div>
        </Section>

        <Section
          icon={Globe}
          title="worlds this caller may name"
          says="naming one it was not granted is refused at the door, before anything is read. there is no partial answer and nothing underneath to filter, which is the whole of authorization here."
        >
          {worlds.length === 0 ? (
            <p className="font-mono max-w-2xl rounded-lg border border-border p-4 text-xs leading-relaxed text-muted-foreground">
              granted nothing yet. a caller is granted, never registered —
              signing in proves who you are and grants nothing on its own.
            </p>
          ) : (
            <div className="flex max-w-xl flex-wrap gap-2">
              {worlds.map((world) => (
                <span
                  key={world}
                  className="flex items-center gap-2 rounded-md border border-border bg-muted/40 py-1.5 pl-1.5 pr-3"
                >
                  <WorldAvatar size="sm" world={world} />
                  <span className="font-mono text-xs text-white/85">{world}</span>
                </span>
              ))}
            </div>
          )}
        </Section>

        <Grants />

        <Section
          icon={LogOut}
          title="sign out"
          tone="grave"
          says="the session is given back and this browser holds nothing. your clusters keep running — signing out of a console is not a thing that should be able to stop a database."
        >
          <button
            type="button"
            onClick={async () => {
              await signOut()
              router.refresh()
            }}
            className="rounded-md border border-flame/40 px-4 py-2 text-sm text-flame transition-colors hover:bg-flame/10"
          >
            sign out
          </button>
        </Section>
      </div>
    </>
  )
}
