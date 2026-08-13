"use client"

import { useRouter } from "next/navigation"
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react"

import {
  type Me,
  type RunResult,
  type SnapshotName,
  me,
  readToken,
  run,
} from "@/lib/blazie"

/**
 * Which ledger the console is pointed at, and how to run against it.
 *
 * An earlier version held one snapshot name for the whole console and froze
 * every page at it. That was true to how blazie works and wrong for a console:
 * it meant nothing ever changed on screen without pressing a button nobody
 * understood the need for. The immutability is still there and still reachable
 * — a run returns the name it read at, and pinning it re-answers forever — but
 * the default is what a person expects, which is that the data page shows the
 * data.
 */

type Cluster = {
  who: Me
  /** Which ledger every page on the console is looking at. */
  ledger: string | null
  choose: (ledger: string) => void
  /** Where the last run read. Shown in the header so a page can be cited. */
  at: SnapshotName | null
  /** Run Lua against the chosen ledger. */
  ask: (source: string) => Promise<RunResult>
  /** Re-read `/me`, for when a ledger has just been claimed. */
  refresh: () => void
}

const Held = createContext<Cluster | null>(null)

export function useCluster(): Cluster {
  const cluster = useContext(Held)
  if (!cluster) {
    throw new Error("useCluster is only usable under the dashboard layout")
  }
  return cluster
}

const CHOSEN = "blazie.ledger"

export function useClusterState() {
  const router = useRouter()
  const [who, setWho] = useState<Me | null>(null)
  const [ledger, setLedger] = useState<string | null>(null)
  const [at, setAt] = useState<SnapshotName | null>(null)
  const [error, setError] = useState<unknown>(null)

  // Strict mode runs effects twice and both runs would ask `/me`.
  const started = useRef(false)

  const load = useCallback(async () => {
    setError(null)
    try {
      const found = await me()
      setWho(found)

      // Whatever was chosen last, if it is still granted. Otherwise the first
      // one, so a console with exactly one ledger needs no choosing at all.
      setLedger((held) => {
        if (held && found.ledgers.includes(held)) return held
        const remembered = window.localStorage.getItem(CHOSEN)
        if (remembered && found.ledgers.includes(remembered)) return remembered
        return found.ledgers[0] ?? null
      })
    } catch (thrown) {
      setError(thrown)
    }
  }, [])

  useEffect(() => {
    if (!readToken()) {
      router.replace("/login")
      return
    }
    if (started.current) return
    started.current = true
    void load()
  }, [router, load])

  const choose = useCallback((next: string) => {
    window.localStorage.setItem(CHOSEN, next)
    setLedger(next)
  }, [])

  const ask = useCallback(
    async (source: string) => {
      if (!ledger) {
        throw new Error("no ledger chosen")
      }
      const result = await run(ledger, source)
      setAt(result.name)
      return result
    },
    [ledger],
  )

  const cluster = useMemo<Cluster | null>(
    () => (who ? { who, ledger, choose, at, ask, refresh: load } : null),
    [who, ledger, choose, at, ask, load],
  )

  return { cluster, error, retry: load }
}

export function ClusterHeld({
  value,
  children,
}: {
  value: Cluster
  children: React.ReactNode
}) {
  return <Held.Provider value={value}>{children}</Held.Provider>
}
