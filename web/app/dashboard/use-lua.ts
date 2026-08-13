"use client"

import { useCallback, useEffect, useState } from "react"

import type { Value } from "@/lib/blazie"

import { useCluster } from "./cluster"

/**
 * Run a chunk when the page loads, and again on demand.
 *
 * Every page in this console is a saved chunk of Lua. That is not a
 * simplification of a richer API — there is no richer API, and the chunk a page
 * runs is one you could paste into the editor and get the same answer from.
 */
export function useLua<T = Value>(source: string) {
  const { ask, ledger } = useCluster()
  const [value, setValue] = useState<T | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [running, setRunning] = useState(true)

  const go = useCallback(() => {
    if (!ledger) {
      setRunning(false)
      return
    }

    let live = true
    setRunning(true)
    setError(null)

    ask(source)
      .then((result) => live && setValue(result.value as T))
      .catch((thrown) => live && setError(thrown))
      .finally(() => live && setRunning(false))

    return () => {
      live = false
    }
    // `ask` closes over the chosen ledger, so choosing another re-runs the page.
  }, [ask, source, ledger])

  useEffect(go, [go])

  return { value, error, running, retry: go }
}

/**
 * Every entity in the ledger, with every field it holds, as rows.
 *
 * This is the chunk the data browser runs, kept here because it is also the
 * best short answer to "what does using blazie look like" — six lines of
 * ordinary Lua, no query language, and nothing named a fact.
 */
export const EVERY_ROW = `local rows = {}
for e in each {} do
  local row = { id = e.id }
  for field, value in pairs(e) do row[field] = value end
  rows[#rows + 1] = row
end
return rows`

export type Row = Record<string, Value> & { id: string }

/** The union of every field present, so a table can have stable columns. */
export function columnsOf(rows: Row[]): string[] {
  const seen = new Set<string>()
  for (const row of rows) {
    for (const key of Object.keys(row)) if (key !== "id") seen.add(key)
  }
  return [...seen].sort()
}
