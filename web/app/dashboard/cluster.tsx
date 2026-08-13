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
  type Fact,
  type Me,
  type Pattern,
  type SnapshotName,
  ask,
  me,
  open,
  readToken,
} from "@/lib/blazie"

/**
 * What the whole console is looking at.
 *
 * The console holds **one snapshot name**, opened once, and every page asks at
 * it. That is not a caching trick — it is the reason a page here can be trusted
 * in a way a normal admin panel cannot. Two tabs of a normal console show two
 * different moments and there is no way to tell; two pages here are the same
 * moment by construction, because they are the same name.
 *
 * So moving forward in time is a deliberate act with a button on it. `reopen()`
 * gets a fresh name; until somebody presses it, nothing under the console
 * changes underneath a reader, however much lands in the cluster meanwhile.
 */

type Cluster = {
  who: Me
  /** Which ledgers at which transaction — the instant every page is reading. */
  name: SnapshotName
  /** True while a fresh name is being fetched. */
  moving: boolean
  /** Advance to now. The only way anything on the console changes. */
  reopen: () => void
  /** Ask the held name a question. */
  askHere: (pattern?: Pattern) => Promise<Fact[]>
}

const Held = createContext<Cluster | null>(null)

export function useCluster(): Cluster {
  const cluster = useContext(Held)
  if (!cluster) {
    throw new Error("useCluster is only usable under the dashboard layout")
  }
  return cluster
}

/**
 * The one place the console asks who it is and what instant it is reading.
 *
 * Both failures land as `error` and are shown by the layout rather than thrown
 * into a boundary, because every one of them is a refusal carrying a repair and
 * the repair is the useful half.
 */
export function useHoldSnapshot() {
  const router = useRouter()
  const [who, setWho] = useState<Me | null>(null)
  const [name, setName] = useState<SnapshotName | null>(null)
  const [moving, setMoving] = useState(false)
  const [error, setError] = useState<unknown>(null)

  // Strict mode runs effects twice, and each run would open a second snapshot —
  // harmless, but it makes the console flicker between two instants on load.
  const started = useRef(false)

  const load = useCallback(async () => {
    setError(null)
    try {
      const found = await me()
      setWho(found)
      // A caller with no grants has nothing to open, and opening nothing is
      // refused on purpose ("opening none is not opening everything"). An empty
      // name is the honest reading of that, not an error.
      setName(found.ledgers.length === 0 ? {} : await open(found.ledgers))
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

  const reopen = useCallback(() => {
    if (!who || who.ledgers.length === 0) return
    setMoving(true)
    open(who.ledgers)
      .then(setName)
      .catch(setError)
      .finally(() => setMoving(false))
  }, [who])

  const askHere = useCallback(
    (pattern: Pattern = {}) => (name ? ask(name, pattern) : Promise.resolve([])),
    [name],
  )

  const cluster = useMemo<Cluster | null>(
    () => (who && name ? { who, name, moving, reopen, askHere } : null),
    [who, name, moving, reopen, askHere],
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
