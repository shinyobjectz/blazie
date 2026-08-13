"use client"

import { RotateCw } from "lucide-react"

import { AppSidebar } from "@/components/dashboard/app-sidebar"
import {
  SidebarResizer,
  useSidebarWidth,
} from "@/components/dashboard/sidebar-resizer"
import { SnapshotName } from "@/components/dashboard/snapshot-name"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Separator } from "@/components/ui/separator"
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar"
import { Wordmark } from "@/components/ui/wordmark"

import { ClusterHeld, useHoldSnapshot } from "./cluster"

/**
 * The console shell: sidebar, and a bar that says which instant is on screen.
 *
 * Signing in is checked once, here, rather than on each page. The snapshot is
 * opened once here too, so every page below is reading the same name — see
 * `cluster.tsx` for why that matters more than it looks like it should.
 */
export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const { cluster, error, retry } = useHoldSnapshot()
  const { width, setWidth, remember } = useSidebarWidth()

  if (error) {
    return (
      <main className="mx-auto max-w-3xl px-6 py-20">
        <Wordmark size="sm" className="mb-10 opacity-70" />
        <h1 className="mb-6 text-2xl font-medium tracking-tight text-white">
          the cluster would not answer for this token
        </h1>
        <RefusalNote error={error} retry={retry} />
      </main>
    )
  }

  if (!cluster) {
    return (
      <main className="px-6 py-20">
        <p className="font-mono mx-auto max-w-3xl text-sm text-muted-foreground">
          asking the cluster who you are…
        </p>
      </main>
    )
  }

  return (
    <ClusterHeld value={cluster}>
      {/* `--sidebar-width` is the variable the sidebar and its spacer already
          read, so driving it from the drag handle is the whole of the resize —
          nothing else has to be told the width moved. */}
      <SidebarProvider style={{ "--sidebar-width": `${width}px` } as React.CSSProperties}>
        <AppSidebar login={cluster.who.login} />
        <SidebarResizer width={width} onWidth={setWidth} onSettled={remember} />

        <SidebarInset className="min-w-0">
          <header className="sticky top-0 z-10 flex h-14 shrink-0 items-center gap-3 border-b border-border bg-background/80 px-4 backdrop-blur">
            <SidebarTrigger />
            <Separator orientation="vertical" className="h-4" />

            <SnapshotName name={cluster.name} />

            <button
              type="button"
              onClick={cluster.reopen}
              disabled={cluster.moving || cluster.who.ledgers.length === 0}
              className="ml-auto inline-flex shrink-0 items-center gap-2 rounded-md border border-border px-3 py-1.5 text-xs text-white transition-colors hover:border-white/40 hover:bg-white/5 disabled:opacity-40"
              // Everything on the console is frozen at one name. This is the
              // only control that moves it, which is why it is the only one in
              // the bar.
              title="open a fresh snapshot — nothing on the console moves until you do"
            >
              <RotateCw
                className={cluster.moving ? "size-3.5 animate-spin" : "size-3.5"}
              />
              {cluster.moving ? "opening…" : "re-open"}
            </button>
          </header>

          <div className="min-w-0 flex-1 px-6 py-8">{children}</div>
        </SidebarInset>
      </SidebarProvider>
    </ClusterHeld>
  )
}
