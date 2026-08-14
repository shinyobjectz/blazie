"use client"

import { useEffect, useState } from "react"

import { Opening } from "@/components/dashboard/opening"
import { OpeningLog } from "@/components/dashboard/opening-log"
import { OpenCluster } from "@/components/dashboard/open-cluster"
import { Wordmark } from "@/components/ui/wordmark"
import { type Cluster, forgetCluster, look } from "@/lib/blazie"

import { useCluster } from "./cluster"
import { WayOut } from "./way-out"

/**
 * The first screen, for somebody who does not have a cluster yet.
 *
 * It is a screen rather than a route, and that is the whole correction. It used
 * to be a redirect to `/dashboard/clusters`, which made three mistakes at once:
 * it put a navigation in the path of the one state that has nowhere to navigate
 * from, it made the first thing anybody saw a page inside a console they have
 * no cluster to fill, and it depended on a pathname comparison that was wrong —
 * so onboarding redirected to the page it was already on, forever.
 *
 * A cluster is not a page in this console. It is what the console is pointed
 * at, chosen at the top of the sidebar, and every page is a question asked of
 * whichever one that is. So having none is not a page you visit either.
 *
 * It stays up through the opening, rather than handing over to an empty console
 * the moment a machine exists. Two or three minutes of watching a console that
 * cannot answer anything yet is worse than two or three minutes of watching the
 * thing you are actually waiting for.
 */
export function Onboarding() {
  const { clusters, refresh } = useCluster()

  /**
   * What was asked for, before there is anything to show for it.
   *
   * Opening makes a tunnel, a dns record and a machine before it answers, so
   * the record this screen reads does not exist for several seconds after the
   * button is pressed. Standing on the form through those seconds is how you
   * get somebody pressing it twice.
   */
  const [asked, setAsked] = useState<{ name: string; opened: string } | null>(null)

  // Drives the spinners in the log. One clock for the whole pane rather than a
  // timer per line, and it is what makes a screen with nothing new to say still
  // look like it is running — which, during the clone, it is.
  const [tick, setTick] = useState(0)

  useEffect(() => {
    const spin = setInterval(() => setTick((t) => t + 1), 90)
    return () => clearInterval(spin)
  }, [])

  // The one being made, if there is one. Opening is one at a time here by
  // construction: this screen is only shown when nothing is open.
  const held = clusters[0] ?? null

  // The real record as soon as there is one, and the placeholder until then.
  // Same shape either way, so the timeline does not know the difference — it
  // just has nothing reported yet, which is exactly true.
  const opening =
    held ??
    (asked
      ? ({
          id: "",
          name: asked.name,
          address: "",
          state: "opening",
          opened: asked.opened,
        } as Cluster)
      : null)

  /**
   * Two clocks, because the two questions cost wildly different amounts.
   *
   * What the machine has said is a read of what the control plane already
   * holds: cheap, and the only thing this screen draws. Whether the cluster
   * answers is a request to the cluster itself, which during an opening is a
   * request to an address that is not up yet — eight seconds of timeout, every
   * time, by design.
   *
   * They were one timer, chained: `look().then(refresh)`. So every tick spent
   * eight seconds failing to reach a machine that was still installing before
   * it went and read the steps, and the timeline moved in eight-second lurches
   * or, when a tick overlapped the next, not at all. The animation was waiting
   * on the one call that cannot answer while there is anything to animate.
   */
  // Keyed on the id, NOT on the cluster.
  //
  // `refresh` replaces the array every two seconds, so the cluster object is a
  // new identity every time — and depending on it tore both timers down and
  // rebuilt them on every read. The two-second one survived long enough to
  // fire; the ten-second one was destroyed and recreated before it ever could,
  // so `look` never ran once. A machine that had been answering for twenty-four
  // minutes sat at "opening" because the only call that can say otherwise was
  // being cancelled five times for every chance it had to happen.
  const watching = held?.id

  useEffect(() => {
    if (!watching) return

    const reading = setInterval(() => {
      void refresh().catch(() => undefined)
    }, 2_000)

    // `look()` is what turns a machine that has started answering into an open
    // cluster, so it still has to run — just not in the way of the drawing.
    const reaching = setInterval(() => {
      void look().catch(() => undefined)
    }, 10_000)

    // And once immediately, so a page opened onto an already-answering cluster
    // does not wait ten seconds to find out.
    void look().catch(() => undefined)

    return () => {
      clearInterval(reading)
      clearInterval(reaching)
    }
  }, [watching, refresh])

  // Only what the console has actually failed to reach, never merely what the
  // machine claimed. A provision reported `failed` having connected its tunnel
  // and answered on its own name; this screen believed it, offered the one
  // button it had, and a working cluster was destroyed by the person who had
  // just made it. A destructive offer has to be the slowest conclusion on the
  // screen, not the fastest.
  const stopped = opening?.state === "unreachable"

  return (
    <main className="mx-auto min-h-svh max-w-5xl px-6 py-20">
      <Wordmark size="sm" className="mb-12 opacity-70" />

      {!opening ? (
        <>
          <h1 className="mb-5 text-3xl font-medium tracking-tight text-white">
            open your first cluster
          </h1>

          <p className="mb-10 max-w-xl text-sm leading-relaxed text-muted-foreground">
            a cluster is a running blazie that holds your worlds. opening one
            makes a machine, installs blazie on it, and dials out to a tunnel —
            it listens on nothing, has no password and no key, and the only
            thing that can reach it is this console.
          </p>

          <OpenCluster
            onOpening={(name) =>
              setAsked(name ? { name, opened: new Date().toISOString() } : null)
            }
          />
        </>
      ) : (
        <>
          {/* Steps on the left say how far along. The log on the right says
              that something is still going on, which is a different question
              and the one somebody asks during the disk-clone minute. */}
          <div className="grid gap-10 lg:grid-cols-[minmax(0,20rem)_minmax(0,1fr)]">
            <Opening cluster={opening} />
            <OpeningLog cluster={opening} tick={tick} />
          </div>

          {/* Never a screen you cannot leave. A machine that stopped is one
              somebody has to be able to clear away and try again from, and
              until this existed the only way out of a failed first provision
              was to already have a console to go and look at it in. */}
          {stopped && held ? (
            <button
              type="button"
              onClick={async () => {
                await forgetCluster(held.id, true)
                await refresh()
                setAsked(null)
              }}
              className="mt-8 rounded-md border border-flame/40 px-4 py-2 text-sm text-flame transition-colors hover:bg-flame/10"
            >
              remove it and try again
            </button>
          ) : null}
        </>
      )}

      <div className="mt-14 border-t border-border pt-8">
        <WayOut />
      </div>
    </main>
  )
}
