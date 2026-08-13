"use client"

import { Check, ChevronDown } from "lucide-react"
import { usePathname } from "next/navigation"
import { useEffect } from "react"

import { AppSidebar } from "@/components/dashboard/app-sidebar"
import {
  SidebarResizer,
  useSidebarWidth,
} from "@/components/dashboard/sidebar-resizer"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Separator } from "@/components/ui/separator"
import { WorldAvatar } from "@/components/ui/world-avatar"
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar"
import { Wordmark } from "@/components/ui/wordmark"
import { SIGN_IN } from "@/lib/blazie"

import { ClusterHeld, useClusterState } from "./cluster"

/**
 * The console shell: sidebar, and a bar saying which world you are looking at.
 *
 * Signing in is checked once, here, rather than on each page.
 */
export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const pathname = usePathname()
  const { held, error, retry } = useClusterState()
  const { width, setWidth, remember } = useSidebarWidth()

  if (error) {
    return (
      <main className="mx-auto max-w-3xl px-6 py-20">
        <Wordmark size="sm" className="mb-10 opacity-70" />
        <h1 className="mb-6 text-2xl font-medium tracking-tight text-white">
          the console could not read what you hold
        </h1>
        <RefusalNote error={error} retry={retry} />
      </main>
    )
  }

  if (!held) {
    return (
      <main className="px-6 py-20">
        <p className="font-mono mx-auto max-w-3xl text-sm text-muted-foreground">
          reading what you hold…
        </p>
      </main>
    )
  }

  if (!held.who.login) return <SignIn can={held.who.can.sign_in} />

  // Signed in and holding nothing: there is exactly one useful thing to do and
  // this is it. Every other page asks a cluster a question, so leaving somebody
  // on the orbit with no cluster shows an empty sky and no way to read it as
  // "open one" rather than "something is broken".
  if (held.clusters.length === 0 && pathname !== "/dashboard/clusters") {
    return <Onboarding />
  }

  return (
    <ClusterHeld value={held}>
      {/* `--sidebar-width` is the variable the sidebar and its spacer already
          read, so driving it from the drag handle is the whole of the resize. */}
      <SidebarProvider style={{ "--sidebar-width": `${width}px` } as React.CSSProperties}>
        <AppSidebar login={held.who.login} />
        <SidebarResizer width={width} onWidth={setWidth} onSettled={remember} />

        <SidebarInset className="min-w-0">
          <header className="sticky top-0 z-10 flex h-14 shrink-0 items-center gap-3 border-b border-border bg-background/80 px-4 backdrop-blur">
            <SidebarTrigger />
            <Separator orientation="vertical" className="h-4" />

            {held.worlds.length === 0 ? (
              <span className="font-mono text-xs text-muted-foreground">
                no worlds yet
              </span>
            ) : (
              <DropdownMenu>
                <DropdownMenuTrigger className="font-mono inline-flex items-center gap-2 rounded-md border border-border py-1 pl-1 pr-3 text-xs text-white transition-colors hover:border-white/40 hover:bg-white/5">
                  {/* The one avatar worth a shader: it is the answer to "which
                      world am I writing into", and it is on screen on every
                      page whether or not the menu is ever opened. */}
                  {held.world ? (
                    <WorldAvatar live world={held.world} />
                  ) : null}
                  {held.world ?? "choose a world"}
                  <ChevronDown className="size-3.5 text-muted-foreground" />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start" className="font-mono text-xs">
                  {held.worlds.map((one: string) => (
                    <DropdownMenuItem key={one} onSelect={() => held.choose(one)}>
                      <WorldAvatar size="sm" world={one} />
                      {one}
                      <Check
                        className={
                          one === held.world
                            ? "ml-auto size-3.5 text-flame"
                            : "ml-auto size-3.5 opacity-0"
                        }
                      />
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
            )}

            {/* Where the last run read. A caller holds the name, never the
                bytes, so this is the one value on screen worth quoting. */}
            {held.at ? (
              <span className="font-mono ml-auto shrink-0 truncate text-xs text-muted-foreground">
                {Object.entries(held.at)
                  .map(([world, tx]) => `${world}@${tx}`)
                  .join(" ")}
              </span>
            ) : null}
          </header>

          <div className="min-w-0 flex-1 px-6 py-8">{children}</div>
        </SidebarInset>
      </SidebarProvider>
    </ClusterHeld>
  )
}

/**
 * Nobody is signed in.
 *
 * Github, and through the control plane rather than through a cluster — which is
 * the change that makes "no clusters yet" a state you can be in. Signing in used
 * to mean asking a blazie node to trade a code, so having no cluster meant
 * having no way to reach the page that would have let you open one.
 */
function SignIn({ can }: { can: boolean }) {
  return (
    <main className="mx-auto max-w-3xl px-6 py-24">
      <Wordmark size="sm" className="mb-10 opacity-70" />
      <h1 className="mb-4 text-3xl font-medium tracking-tight text-white">
        sign in
      </h1>
      <p className="mb-8 max-w-lg text-sm leading-relaxed text-muted-foreground">
        github says who you are. what you hold — your clusters, and the
        credentials that reach them — is kept here rather than on any of them, so
        this works before you have opened one.
      </p>

      {can ? (
        <a
          href={SIGN_IN}
          className="inline-flex items-center gap-2 rounded-md bg-white px-5 py-2.5 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02]"
        >
          continue with github
        </a>
      ) : (
        <p className="font-mono max-w-lg rounded-lg border border-flame/30 bg-flame/5 p-4 text-xs leading-relaxed text-flame">
          this deployment has no github credentials set, so there is nothing to
          sign in with. set GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET with
          `wrangler pages secret put`.
        </p>
      )}
    </main>
  )
}

/**
 * The first screen anybody sees, and the only one that works with nothing.
 *
 * A redirect rather than a page of its own, because the clusters page already
 * IS this when it is empty — two screens saying "open one" would drift apart,
 * and the one you would keep is the one that can also show you the cluster
 * afterwards.
 */
function Onboarding() {
  useEffect(() => {
    window.location.replace("/dashboard/clusters/")
  }, [])

  return (
    <main className="px-6 py-20">
      <p className="font-mono mx-auto max-w-3xl text-sm text-muted-foreground">
        you hold no clusters yet — opening one…
      </p>
    </main>
  )
}
