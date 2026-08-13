"use client"

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
  type Cluster,
  type RunResult,
  type SnapshotName,
  type Who,
  clusters as askClusters,
  run as runOn,
  who as askWho,
  worldsOn,
} from "@/lib/blazie"

/**
 * Which cluster the console is pointed at, which world within it, and how to run.
 *
 * Two choices, not one, and they nest: a cluster holds worlds, so choosing a
 * cluster can invalidate the chosen world and does. That was one choice until
 * there could be more than one cluster, and collapsing them again would mean a
 * console that shows you one cluster's world list while running against
 * another's.
 *
 * `run` is bound to the chosen cluster on purpose. A page that imported the bare
 * client could address a cluster that is not the one on screen, which is the one
 * mistake a console with a switcher in it must not make possible.
 */

type Held = {
  who: Who
  /** Every cluster you hold. Empty is a real and expected state. */
  clusters: Cluster[]
  /** The one on screen, or null when you hold none. */
  cluster: Cluster | null
  chooseCluster: (id: string) => void
  /** Which worlds this caller may name on the chosen cluster. */
  worlds: string[]
  /** Which world every page is looking at, within that cluster. */
  world: string | null
  choose: (world: string) => void
  /** Where the last run read. Shown in the header so a page can be cited. */
  at: SnapshotName | null
  /** Run Lua against the chosen world of the chosen cluster. */
  ask: (source: string) => Promise<RunResult>
  /** Run against a named world of the chosen cluster. */
  run: (world: string, source: string) => Promise<RunResult>
  /** Re-read what is held, for when a cluster or world has just been made. */
  refresh: () => Promise<void>
}

const Context = createContext<Held | null>(null)

export function useCluster(): Held {
  const held = useContext(Context)
  if (!held) throw new Error("useCluster is only usable under the dashboard layout")
  return held
}

const CHOSEN_CLUSTER = "blazie.cluster"
const CHOSEN_WORLD = "blazie.world"

export function useClusterState() {
  const [who, setWho] = useState<Who | null>(null)
  const [clusters, setClusters] = useState<Cluster[]>([])
  const [clusterId, setClusterId] = useState<string | null>(null)
  const [found, setFound] = useState<{ on: string; worlds: string[] } | null>(null)
  const [world, setWorld] = useState<string | null>(null)
  const [at, setAt] = useState<SnapshotName | null>(null)
  const [error, setError] = useState<unknown>(null)

  // Strict mode runs effects twice and both runs would ask.
  const started = useRef(false)

  const load = useCallback(async () => {
    setError(null)

    try {
      const found = await askWho()
      setWho(found)

      if (!found.login) {
        setClusters([])
        return
      }

      const { clusters: held } = await askClusters()
      setClusters(held)

      setClusterId((chosen) => {
        if (chosen && held.some((c) => c.id === chosen)) return chosen
        const remembered = window.localStorage.getItem(CHOSEN_CLUSTER)
        if (remembered && held.some((c) => c.id === remembered)) return remembered
        return held[0]?.id ?? null
      })
    } catch (thrown) {
      setError(thrown)
    }
  }, [])

  useEffect(() => {
    if (started.current) return
    started.current = true
    void load()
  }, [load])

  const cluster = useMemo(
    () => clusters.find((c) => c.id === clusterId) ?? null,
    [clusters, clusterId],
  )

  const chooseCluster = useCallback((id: string) => {
    window.localStorage.setItem(CHOSEN_CLUSTER, id)
    setClusterId(id)
    // The chosen world belonged to the cluster you left. Keeping it would point
    // every page at a name the new cluster may not hold, and the first thing you
    // would see is a refusal about a world you never chose.
    setWorld(null)
    setAt(null)
  }, [])

  const choose = useCallback((next: string) => {
    window.localStorage.setItem(CHOSEN_WORLD, next)
    setWorld(next)
  }, [])

  const run = useCallback(
    async (against: string, source: string) => {
      if (!cluster) throw new Error("no cluster chosen")
      const result = await runOn(cluster.id, against, source)
      setAt(result.name)
      return result
    },
    [cluster],
  )

  const ask = useCallback(
    (source: string) => {
      if (!world) throw new Error("no world chosen")
      return run(world, source)
    },
    [run, world],
  )

  // Which worlds a cluster holds is a question for the cluster rather than
  // something the session could know: grants live in that cluster's own
  // `$authority`, and a control plane that cached them would be answering from
  // a copy of a thing whose whole point is that it is the record.
  useEffect(() => {
    if (!cluster) return
    let live = true
    const on = cluster.id

    worldsOn(on)
      .then((answered) => {
        if (!live) return
        setFound({ on, worlds: answered.worlds })
        setWorld((held) => {
          if (held && answered.worlds.includes(held)) return held
          const remembered = window.localStorage.getItem(CHOSEN_WORLD)
          if (remembered && answered.worlds.includes(remembered)) return remembered
          return answered.worlds[0] ?? null
        })
      })
      .catch(() => live && setFound({ on, worlds: [] }))

    return () => {
      live = false
    }
  }, [cluster])

  // Only the list that came from the cluster on screen. Clearing it by hand when
  // the cluster changed was a synchronous setState inside an effect; this says
  // the same thing by construction and cannot show one cluster's worlds against
  // another's data.
  const worlds = useMemo(
    () => (found && cluster && found.on === cluster.id ? found.worlds : []),
    [found, cluster],
  )

  const held = useMemo<Held | null>(
    () =>
      who
        ? { who, clusters, cluster, chooseCluster, worlds, world, choose, at, ask, run, refresh: load }
        : null,
    [who, clusters, cluster, chooseCluster, worlds, world, choose, at, ask, run, load],
  )

  return { held, error, retry: load }
}

export function ClusterHeld({
  value,
  children,
}: {
  value: Held
  children: React.ReactNode
}) {
  return <Context.Provider value={value}>{children}</Context.Provider>
}
