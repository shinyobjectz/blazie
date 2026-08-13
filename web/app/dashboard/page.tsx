"use client"

import Link from "next/link"
import { useRouter } from "next/navigation"
import { useCallback, useEffect, useState } from "react"

import { Copyable } from "@/components/ui/copyable"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Wordmark } from "@/components/ui/wordmark"
import { type Me, clusterUrl, forgetToken, me, readToken } from "@/lib/blazie"

import { Facts } from "./facts"
import { Health } from "./health"

/**
 * The console. One person's window onto one cluster — not an admin panel, and
 * deliberately not a dashboard of charts. Everything on it is a fact somebody
 * could have asked for themselves, read the same way an agent reads it.
 */
export default function Dashboard() {
  const router = useRouter()
  const [who, setWho] = useState<Me | null>(null)
  const [error, setError] = useState<unknown>(null)

  useEffect(() => {
    if (!readToken()) {
      router.replace("/login")
      return
    }

    let live = true
    me()
      .then((found) => {
        if (live) setWho(found)
      })
      .catch((thrown) => {
        if (live) setError(thrown)
      })

    return () => {
      live = false
    }
  }, [router])

  const retry = useCallback(() => {
    setError(null)
    setWho(null)
    me().then(setWho).catch(setError)
  }, [])

  const signOut = useCallback(() => {
    forgetToken()
    router.replace("/login")
  }, [router])

  return (
    <>
      <header className="flex items-center justify-between border-b border-border px-6 py-5 sm:px-10">
        <Link href="/">
          <Wordmark size="sm" />
        </Link>
        <div className="flex items-center gap-6 text-sm">
          {who?.login && (
            <span className="font-mono text-muted-foreground">{who.login}</span>
          )}
          <button
            type="button"
            onClick={signOut}
            className="rounded-md border border-border px-4 py-1.5 text-sm text-white transition-colors hover:border-white/40 hover:bg-white/5"
          >
            sign out
          </button>
        </div>
      </header>

      {error ? (
        <main className="px-6 py-16 sm:px-10">
          <div className="mx-auto max-w-5xl">
            <h1 className="mb-6 text-2xl font-medium tracking-tight text-white">
              the cluster would not answer for this token
            </h1>
            <RefusalNote error={error} retry={retry} />
            <button
              type="button"
              onClick={signOut}
              className="mt-6 text-sm text-white underline decoration-white/30 underline-offset-4 transition-colors hover:decoration-white"
            >
              forget this token and sign in again
            </button>
          </div>
        </main>
      ) : !who ? (
        <main className="px-6 py-16 sm:px-10">
          <p className="font-mono mx-auto max-w-5xl text-sm text-muted-foreground">
            asking the cluster who you are…
          </p>
        </main>
      ) : (
        <main className="flex-1">
          <section className="px-6 py-14 sm:px-10">
            <div className="mx-auto max-w-5xl">
              <h1 className="text-3xl font-medium tracking-tight text-white">
                {who.login ? `hello, ${who.login}` : "this caller"}
              </h1>
              <p className="mt-3 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                a caller is a fingerprint and a list of ledgers it may name.
                that list is the whole of its reach — there are no row rules
                underneath it to go and check.
              </p>

              <div className="mt-7 flex flex-wrap items-start gap-x-10 gap-y-6">
                <Detail label="caller">
                  <Copyable text={who.caller} label={short(who.caller)} />
                </Detail>
                <Detail label="cluster">
                  <Copyable text={clusterUrl} />
                </Detail>
                <Detail label="may name">
                  <p className="font-mono py-2 text-sm text-white/85">
                    {who.ledgers.length === 0
                      ? "nothing yet"
                      : `${who.ledgers.length} ${
                          who.ledgers.length === 1 ? "ledger" : "ledgers"
                        }`}
                  </p>
                </Detail>
              </div>
            </div>
          </section>

          <section className="border-t border-border px-6 py-14 sm:px-10">
            <div className="mx-auto max-w-5xl">
              <h2 className="mb-3 text-2xl font-medium tracking-tight text-white">
                the facts
              </h2>
              <p className="mb-8 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                nothing here is ever rewritten. a correction is a later fact and
                the earlier one still answers where it was written, so scrolling
                back is scrolling through time rather than through a log.
              </p>

              <Facts ledgers={who.ledgers} />
            </div>
          </section>

          <section className="border-t border-border px-6 py-14 sm:px-10">
            <div className="mx-auto max-w-5xl">
              <h2 className="mb-3 text-2xl font-medium tracking-tight text-white">
                how the cluster is doing
              </h2>
              <p className="mb-9 max-w-2xl text-sm leading-relaxed text-muted-foreground">
                there is no health endpoint. the jobs that watch the node write
                what they saw into ledgers, and this reads them with open and
                ask — the same two verbs as everything else on this page.
              </p>

              <Health granted={who.ledgers} />
            </div>
          </section>
        </main>
      )}

      <footer className="flex flex-col items-center gap-3 border-t border-border px-6 py-8 text-sm text-muted-foreground sm:flex-row sm:justify-between sm:px-10">
        <Wordmark size="sm" className="opacity-70" />
        <p className="font-mono">{clusterUrl}</p>
      </footer>
    </>
  )
}

function Detail({
  label,
  children,
}: {
  label: string
  children: React.ReactNode
}) {
  return (
    <div>
      <p className="mb-1.5 text-xs text-muted-foreground">{label}</p>
      {children}
    </div>
  )
}

/** A sha256 fingerprint is 64 characters. Show the ends, copy the whole. */
function short(fingerprint: string) {
  return fingerprint.length > 20
    ? `${fingerprint.slice(0, 10)}…${fingerprint.slice(-6)}`
    : fingerprint
}
