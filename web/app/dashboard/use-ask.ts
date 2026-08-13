"use client"

import { useCallback, useEffect, useState } from "react"

import type { Fact, Pattern } from "@/lib/blazie"

import { useCluster } from "./cluster"

/**
 * Ask the held name a question, and re-ask when the console moves.
 *
 * Every page in this console is one of these — a saved question. That is not a
 * simplification of a richer admin API; there is no richer API. Attributes,
 * jobs and vitals are all *facts*, so "the jobs page" really is `ask` with a
 * pattern, and a page that pretended otherwise would be inventing a primitive.
 */
export function useAsk(pattern: Pattern = {}) {
  const { name, askHere } = useCluster()
  const [facts, setFacts] = useState<Fact[] | null>(null)
  const [error, setError] = useState<unknown>(null)

  // The pattern is an object literal at every call site, so it is a new
  // reference on every render and cannot be a dependency. Its *content* is what
  // identifies the question.
  const question = JSON.stringify(pattern)

  const run = useCallback(() => {
    let live = true
    setError(null)
    askHere(JSON.parse(question) as Pattern)
      .then((found) => live && setFacts(found))
      .catch((thrown) => live && setError(thrown))
    return () => {
      live = false
    }
  }, [askHere, question])

  // `askHere` closes over the name, so re-opening re-asks — which is what makes
  // the whole console move together on one button.
  useEffect(run, [run])

  return { facts, error, retry: run, loading: facts === null && !error }
}

/** The latest fact per id for an attribute — a correction is a later fact. */
export function latest(facts: Fact[]): Map<string, Fact> {
  const newest = new Map<string, Fact>()
  for (const fact of facts) {
    const key = String(fact.id)
    const held = newest.get(key)
    if (!held || fact.tx >= held.tx) newest.set(key, fact)
  }
  return newest
}

/** Ids whose `is` says they are one kind of thing. */
export function idsThatAre(facts: Fact[], kind: string): string[] {
  return [
    ...new Set(
      facts.filter((f) => f.value === kind).map((f) => String(f.id)),
    ),
  ].sort()
}
